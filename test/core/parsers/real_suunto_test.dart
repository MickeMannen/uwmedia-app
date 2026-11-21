// tests/test_suunto.py test_real_samples: the owner's real Suunto app
// exports under test_data/logs (never in git) read for their device and
// deepest point; the parity of every field is in real_logs_test.dart. The
// expected values are what Python's parser gives for the same files.
@Tags(['requires_media'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';

import '../../helpers/test_data.dart';

void main() {
  const samples = [
    ('suunto_eon_core_nitrox.json', 'EON Core', 22.65, 'UTC+02:00'),
    ('suunto_nautic_multigas.json', 'Nautic', 21.14, 'UTC+01:00'),
    ('suunto_nautic_sidemount.json', 'Nautic', 21.14, 'UTC+01:00'),
    ('suunto_ocean_air.json', 'Ocean', 23.12, 'UTC+05:00'),
    ('suunto_ocean_nitrox.json', 'Ocean', 10.59, 'UTC+03:00'),
  ];
  for (final (name, device, maxDepth, zone) in samples) {
    test('test_real_samples $name', () {
      final file = File('${testDataDir().path}/logs/$name');
      final dives = parseLogFile(file.path, file.readAsBytesSync())!;
      expect(dives, hasLength(1));
      final dive = dives.single;
      expect(dive.logFormat, suuntoJsonFormat);
      expect(dive.device, device);
      expect(dive.maxDepth, closeTo(maxDepth, 0.01));
      expect(dive.timezone, zone);
    }, skip: skipIfNoTestData('logs/$name'));
  }
}
