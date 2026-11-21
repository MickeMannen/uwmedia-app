/// The Dive Profile Builder's own mark on the logs it writes, and the plan
/// it puts into them so that a saved log can be opened again and edited
/// (Python `parsers/plan_embed.py`).
///
/// Each format keeps both where it expects application data, so other
/// software passes over them:
/// - UDDF: the generator's name, and under the dive
///   `applicationdata/uwmedia/plan`;
/// - Subsurface XML: the dive's notes naming the builder, and an
///   `extradata` entry with the key "UWMedia plan" on the dive computer;
/// - Garmin FIT: a `developer_data_id` message whose application id is
///   the builder's ([fitApplicationId]), with the plan spread over
///   developer text fields of the `file_creator` message. FIT limits a
///   field to 255 bytes, so the JSON is zlib-compressed, base64-encoded
///   and cut into chunks named `uwmedia_plan_0`, `uwmedia_plan_1` and so
///   on (written by `fit_writer.dart`).
///
/// A file with the mark but no plan (saved before the plan was embedded)
/// is still the builder's.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/xml_query.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:xml/xml.dart';

const planFormat = 'uwmedia_dive_plan';
const planFormatVersion = 1;
const generatorName = 'UWMedia Dive Profile Builder';
const subsurfaceNotesMark = 'UWMedia Dive Profile Builder';
const subsurfacePlanKey = 'UWMedia plan';

/// The builder's id as a FIT "developer" (the bytes of the UUID
/// 2b0c3d64-7a1e-4f2b-9c5d-8e6f1a2b3c4d): any file whose
/// `developer_data_id` carries it was written by the builder. Never to be
/// changed: older files are known by it.
const List<int> fitApplicationId = [
  0x2b, 0x0c, 0x3d, 0x64, 0x7a, 0x1e, 0x4f, 0x2b, //
  0x9c, 0x5d, 0x8e, 0x6f, 0x1a, 0x2b, 0x3c, 0x4d,
];
const fitPlanFieldPrefix = 'uwmedia_plan_';
const fitChunkBytes = 250;
const fitDeveloperDataIndex = 0;

/// What a log says about where it came from: whether the builder wrote
/// it, and the plan in it when there is one.
typedef LogOrigin = ({bool createdByUwmedia, DiveProfilePlan? plan});

String _compact(Object? value) => switch (value) {
  final Map<String, dynamic> map =>
    '{${[for (final MapEntry(:key, :value) in map.entries) '${jsonEncode(key)}:${_compact(value)}'].join(',')}}',
  final List<dynamic> list => '[${list.map(_compact).join(',')}]',
  final double number => pyFloatRepr(number),
  _ => jsonEncode(value),
};

/// The plan as compact JSON in an envelope that [planFromJson] reads back:
/// Python's `json.dumps` of the model, number for number.
String planToJson(DiveProfilePlan plan) => _compact({
  'format': planFormat,
  'version': planFormatVersion,
  'plan': plan.toJson(),
});

/// The plan in an envelope of [planToJson]; `null` when the text is not
/// one, or when the plan in it is no longer valid.
DiveProfilePlan? planFromJson(String? text) {
  if (text == null || text.isEmpty) {
    return null;
  }
  final Object? payload;
  try {
    payload = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (payload is! Map<String, dynamic> || payload['format'] != planFormat) {
    return null;
  }
  try {
    final plan = payload['plan'];
    if (plan is Map<String, dynamic>) {
      return DiveProfilePlan.fromJson(plan);
    }
    // Python's `plan or {}`: nothing at all is an empty plan, anything
    // else that is not a plan is none.
    final nothing =
        plan == null ||
        plan == false ||
        plan == 0 ||
        plan == '' ||
        (plan is List && plan.isEmpty);
    return nothing ? DiveProfilePlan.fromJson(const {}) : null;
  } on Object {
    return null;
  }
}

LogOrigin _uddfOrigin(XmlElement root) {
  final generator = root.descendantElements
      .where(
        (e) =>
            e.localName == 'name' && e.parentElement?.localName == 'generator',
      )
      .firstOrNull;
  final created = stringValue(generator)
      .toLowerCase()
      .contains(generatorName.toLowerCase());
  final planNode = root.descendantElements
      .where(
        (e) =>
            e.localName == 'plan' &&
            e.parentElement?.localName == 'uwmedia' &&
            e.parentElement?.parentElement?.localName == 'applicationdata',
      )
      .firstOrNull;
  final plan = planFromJson(stringValue(planNode));
  return (createdByUwmedia: created || plan != null, plan: plan);
}

LogOrigin _subsurfaceOrigin(XmlElement root) {
  final notes = [
    for (final e in root.descendantElements)
      if (e.name.qualified == 'notes' &&
          e.parentElement?.name.qualified == 'dive')
        for (final child in e.children)
          if (child is XmlText)
            child.value
          else if (child is XmlCDATA)
            child.value,
  ].join(' ');
  final created = notes.toLowerCase().contains(
    subsurfaceNotesMark.toLowerCase(),
  );
  final value = root.descendantElements
      .where(
        (e) =>
            e.name.qualified == 'extradata' &&
            e.parentElement?.name.qualified == 'divecomputer' &&
            e.getAttribute('key') == subsurfacePlanKey,
      )
      .map((e) => e.getAttribute('value'))
      .nonNulls
      .firstOrNull;
  final plan = planFromJson(value);
  return (createdByUwmedia: created || plan != null, plan: plan);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

LogOrigin _fitOrigin(Uint8List bytes, List<int> Function(List<int>)? inflate) {
  final data = readFitDeveloperData(bytes);
  if (!data.applicationIds.any((id) => _sameBytes(id, fitApplicationId))) {
    return (createdByUwmedia: false, plan: null);
  }
  final chunks = <int, String>{};
  data.fileCreatorFields.forEach((name, value) {
    if (name.startsWith(fitPlanFieldPrefix) && value is String) {
      final index = pyInt(name.substring(fitPlanFieldPrefix.length));
      if (index == null) {
        throw FormatException('Not a plan chunk', name);
      }
      chunks[index] = value;
    }
  });
  if (chunks.isEmpty) {
    return (createdByUwmedia: true, plan: null);
  }
  if (inflate == null) {
    throw ArgumentError.notNull('inflate');
  }
  DiveProfilePlan? plan;
  try {
    final packed = [for (final i in chunks.keys.toList()..sort()) chunks[i]!];
    plan = planFromJson(utf8.decode(inflate(base64.decode(packed.join()))));
  } on ArgumentError {
    rethrow;
  } on Object {
    // Not base64, not zlib data or not text: no plan.
    plan = null;
  }
  return (createdByUwmedia: true, plan: plan);
}

/// Whether the log in [bytes] (a file named [fileName]) is one the Dive
/// Profile Builder wrote, and the plan in it when it has one. A file that
/// cannot be read at all counts as not the builder's. [inflate] undoes
/// zlib compression (`dart:io`'s `zlib.decode` in the app); a FIT file's
/// plan needs it.
LogOrigin readLogOrigin(
  String fileName,
  Uint8List bytes, {
  List<int> Function(List<int>)? inflate,
}) {
  final suffix = pySuffix(fileName).toLowerCase();
  try {
    if (suffix == '.uddf') {
      return _uddfOrigin(parseXmlBytes(bytes).rootElement);
    }
    if (suffix == '.ssrf' || suffix == '.xml') {
      return _subsurfaceOrigin(parseXmlBytes(bytes).rootElement);
    }
    if (suffix == '.fit') {
      return _fitOrigin(bytes, inflate);
    }
  } on ArgumentError {
    rethrow;
  } on Object {
    // Not a log this can read.
  }
  return (createdByUwmedia: false, plan: null);
}
