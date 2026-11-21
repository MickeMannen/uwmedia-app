// The parsers on the owner's real dive logs, against what the Python app's
// parsers make of the same files. Neither the logs nor the references are
// in git: they are under test_data/ (see CONTRIBUTING.md), and the
// references are made by tool/python_reference/real_logs_fixture.py.
// Without them every test here skips itself.
@Tags(['requires_media'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';
import '../../helpers/test_data.dart';

/// What Python's FIT parser sets to 0 when a record has none, and the port
/// leaves null (spec §10.8).
const fitZeroDefaults = {
  'depth',
  'temp',
  'deco_stop_depth',
  'next_stop_depth',
  'next_stop_time',
  'tts',
  'air_remaining',
  'ascent_rate',
  'n2_tissue_load',
  'pressure_sac',
  'volume_sac',
  'rmv',
  'heart_rate',
  'cns',
};

void main() {
  final logs = Directory('${testDataDir().path}/logs');
  final references = Directory('${testDataDir().path}/python_reference/dives');
  final skip = skipIfNoTestData('python_reference/dives');

  final files = skip != null
      ? <File>[]
      : (references
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)));

  test('the references are there', () {
    expect(files, isNotEmpty);
  }, skip: skip);

  for (final file in files) {
    final relative = file.path.substring(
      references.path.length + 1,
      file.path.length - '.json'.length,
    );
    test(relative, () {
      final reference =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final path = '${logs.path}/$relative';
      final bytes = File(path).readAsBytesSync();
      final format = reference['format'] as String;
      expect(detectLogFormat(path, bytes), format);

      if (reference.containsKey('error')) {
        expect(() => parseLogFile(path, bytes), throwsA(anything));
        return;
      }
      final dives = parseLogFile(path, bytes)!;
      final expected = jsonObjects(reference['dives']);
      expect(dives, hasLength(expected.length));

      // What the port sets and Python does not, per format (spec §10.16).
      final shearwater = format.startsWith('shearwater');
      final portOnly =
          format == 'uddf' || format == 'subsurface_xml' || format == 'fit'
          ? <String>{}
          : {'surf_gf'};
      for (var i = 0; i < dives.length; i++) {
        final dive = dives[i];
        final want = Map<String, dynamic>.of(expected[i]);
        expect(dive.logFormat, format);
        expect(dive.maxDepth, nearly(want.remove('max_depth_property') as num));
        expect(dive.isCcr, want.remove('is_ccr'));
        expect(
          [for (final wp in dive.waypoints) wp.circuit],
          want.remove('circuits'),
          reason: 'dive $i circuits',
        );
        expect(
          [for (final wp in dive.waypoints) wp.gasmix],
          want.remove('gasmixes'),
          reason: 'dive $i gasmixes',
        );
        expectDiveMatchesPython(
          dive,
          want,
          reason: 'dive $i',
          ignoreDiveFields: shearwater ? {'gf_low', 'gf_high'} : {},
          portOnlyWaypointFields: portOnly,
          nullWherePythonHasZero: format == 'fit' ? fitZeroDefaults : {},
        );
      }
    });
  }

  // tests/test_alternative_formats.py: one dive exported in every format
  // (Shearwater XML and CSV, Subsurface CSV and SSRF) and as UDDF: the
  // manager keeps one copy of each dive, the richest.
  test('test_real_folder_of_one_dive_in_every_format', () {
    final manager = DiveManager();
    final folder = Directory('${logs.path}/alternative_formats');
    for (final file
        in folder.listSync().whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path))) {
      final dives = parseLogFile(file.path, file.readAsBytesSync());
      if (dives != null && dives.isNotEmpty) {
        manager.addDives(dives);
      }
    }
    final uddf = File(
      '${logs.path}/uddf/Perdix 2 451 2025-10-19 11-42-39.uddf',
    );
    manager.addDives(parseLogFile(uddf.path, uddf.readAsBytesSync())!);
    final kept = manager.dives.values.toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    expect(
      [for (final d in kept) d.logFormat],
      [shearwaterXmlFormat, subsurfaceXmlFormat],
    );
  }, skip: skipIfNoTestData('logs/alternative_formats'));
}
