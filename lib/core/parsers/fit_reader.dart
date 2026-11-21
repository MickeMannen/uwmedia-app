/// Decoding a FIT file into the messages the Garmin parser reads, in the
/// shape the Python FIT SDK gives them (spec §4.1, §8): lists of messages by
/// name, each a map from the FIT profile's field name to its value.
///
/// The FIT decoding itself is `package:fit_sdk`. It names fields in
/// CamelCase and leaves enum values as numbers; this gives the fields their
/// profile names and the enums the parser looks at their names
/// (`fit_profile_names.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fit_sdk/fit_sdk.dart' show Decode, DecodeMode, FieldBase, Mesg;
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/fit_profile_names.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';

/// The messages the parser and the Dive Profile Builder's log import read,
/// by FIT global message number, under the list name the Python SDK uses.
const Map<int, String> _messageLists = {
  0: 'file_id_mesgs',
  18: 'session_mesgs',
  20: 'record_mesgs',
  21: 'event_mesgs',
  23: 'device_info_mesgs',
  34: 'activity_mesgs',
  258: 'dive_settings_mesgs',
  259: 'dive_gas_mesgs',
  319: 'tank_update_mesgs',
  323: 'tank_summary_mesgs',
};

// Manufacturers whose file_id product is a Garmin product number.
const Set<int> _garminProductMakers = {1, 13, 15, 89};
const int _diveAlertEvent = 56;

final _wordStart = RegExp(r'(?<=[a-z0-9])(?=[A-Z])');

/// The FIT profile's name of a field from the library's CamelCase one:
/// "NextStopDepth" is `next_stop_depth`, "N2Load" is `n2_load`.
String fitFieldName(String camelCase) =>
    camelCase.replaceAll(_wordStart, '_').toLowerCase();

Object _named(Map<int, String> names, Object value) =>
    value is int ? (names[value] ?? value) : value;

/// A field's value; a text that is not UTF-8 without the bytes that are
/// not, as the Python SDK reads it (the library refuses the whole text).
Object? _valueOf(FieldBase field) {
  try {
    return field.value;
  } on FormatException {
    final raw = field.values.isEmpty ? null : field.values.first;
    if (raw is! List<int>) {
      return null;
    }
    final end = raw.indexOf(0);
    return utf8
        .decode(end < 0 ? raw : raw.sublist(0, end), allowMalformed: true)
        .replaceAll('\u{FFFD}', '');
  }
}

/// The FIT files in [bytes]: usually one; a device can write several one
/// after the other. Each starts with a header that gives its length.
Iterable<Uint8List> _fitFiles(Uint8List bytes) sync* {
  var at = 0;
  while (at + 12 <= bytes.length) {
    final headerSize = bytes[at];
    if (headerSize < 12 ||
        String.fromCharCodes(bytes, at + 8, at + 12) != '.FIT') {
      return;
    }
    final dataSize = ByteData.sublistView(
      bytes,
      at + 4,
      at + 8,
    ).getUint32(0, Endian.little);
    // The header, the data and two bytes of checksum.
    final end = at + headerSize + dataSize + 2;
    yield Uint8List.sublistView(
      bytes,
      at,
      end < bytes.length ? end : bytes.length,
    );
    at = end;
  }
}

/// The messages of the FIT file in [bytes] that the Garmin parser reads. A
/// file that breaks off or is damaged gives the messages up to that point,
/// and a wrong checksum does not stop the reading: as in Python, which
/// reports the decoder's errors and goes on with what it has.
FitMessages readFitMessages(Uint8List bytes) {
  final messages = <String, List<FitMesg>>{};
  for (final file in _fitFiles(bytes)) {
    _readOne(file, messages);
  }
  return messages;
}

void _readOne(Uint8List bytes, Map<String, List<FitMesg>> messages) {
  final decoder = Decode();
  decoder.onMesg = (Mesg mesg) {
    final listName = _messageLists[mesg.num];
    if (listName == null) {
      return;
    }
    final out = <String, Object?>{};
    for (final field in mesg.fields) {
      final value = _valueOf(field);
      if (value == null ||
          field.isInvalid ||
          (value is double && value.isNaN) ||
          field.name == 'unknown') {
        continue;
      }
      out[fitFieldName(field.name)] = value;
    }

    switch (mesg.num) {
      case 0:
        final maker = out['manufacturer'];
        final product = out['product'];
        if (product != null && _garminProductMakers.contains(maker)) {
          out['garmin_product'] = _named(garminProductNames, product);
        }
        if (maker != null) {
          out['manufacturer'] = _named(manufacturerNames, maker);
        }
      case 21:
        final event = out['event'];
        final data = out['data'];
        if (event == _diveAlertEvent && data != null) {
          out['dive_alert'] = _named(diveAlertNames, data);
        }
        if (event != null) {
          out['event'] = _named(eventNames, event);
        }
      case 259:
        final status = out['status'];
        if (status != null) {
          out['status'] = _named(diveGasStatusNames, status);
        }
        final mode = out['mode'];
        if (mode != null) {
          out['mode'] = _named(diveGasModeNames, mode);
        }
    }
    messages.putIfAbsent(listName, () => []).add(out);
  };
  try {
    // Without the library's own checksum test, which refuses the file
    // before reading any of it.
    decoder.read(bytes, mode: DecodeMode.invalidHeader);
  } on Object {
    // What was read before the damage is still a dive.
  }
}

/// The dive of the FIT file in [bytes].
List<Dive> parseGarmin(Uint8List bytes, String path, {TankConfig? tanks}) =>
    parseGarminMessages(readFitMessages(bytes), path, tanks: tanks);

/// The developer data of a FIT file that tells whose it is: the
/// application ids of its `developer_data_id` messages, and the developer
/// fields of its `file_creator` messages by field name (the Dive Profile
/// Builder keeps its plan there, `plan_embed.dart`).
typedef FitDeveloperData = ({
  List<List<int>> applicationIds,
  Map<String, Object?> fileCreatorFields,
});

const int _fileCreatorMesg = 49;
const int _developerDataIdMesg = 207;
const int _applicationIdField = 1;

/// The developer data of the FIT file in [bytes]; what was read before
/// any damage, as [readFitMessages].
FitDeveloperData readFitDeveloperData(Uint8List bytes) {
  final ids = <List<int>>[];
  final fields = <String, Object?>{};
  for (final file in _fitFiles(bytes)) {
    final decoder = Decode();
    decoder.onMesg = (Mesg mesg) {
      if (mesg.num == _developerDataIdMesg) {
        final id = mesg.fields
            .where((f) => f.num == _applicationIdField)
            .firstOrNull;
        if (id != null) {
          ids.add([
            for (final v in id.values)
              if (v is int) v,
          ]);
        }
      } else if (mesg.num == _fileCreatorMesg) {
        for (final field in mesg.developerFields) {
          final value = _valueOf(field);
          if (value != null) {
            fields[field.name] = value;
          }
        }
      }
    };
    try {
      decoder.read(file, mode: DecodeMode.invalidHeader);
    } on Object {
      // What was read before the damage still counts.
    }
  }
  return (applicationIds: ids, fileCreatorFields: fields);
}
