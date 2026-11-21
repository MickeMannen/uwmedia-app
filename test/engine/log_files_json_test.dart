// A folder of dive logs with JSON files in it (Python 0.8.0): only the
// Suunto app's export is a dive log, any other JSON file (settings, plans,
// overlay documents) is left out of the scan and refused when named.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/engine/log_files.dart';

import '../helpers/python_reference.dart';

void main() {
  test('only the Suunto app export of the JSON files is a dive log', () {
    final cases = jsonObjects(pythonReference('dives/suunto.json')['parse']);
    List<int> bytes(String start) => base64.decode(
      cases.firstWhere(
            (c) => (c['name'] as String).startsWith(start),
          )['bytes_base64']
          as String,
    );
    final tmp = Directory.systemTemp.createTempSync('uwmedia_json_logs');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File(p.join(tmp.path, 'eon.json')).writeAsBytesSync(bytes('EON Core'));
    File(p.join(tmp.path, 'Settings.JSON')).writeAsStringSync('{"units": 1}');
    File(p.join(tmp.path, 'plan.json')).writeAsStringSync('[1, 2]');

    expect(logExtensions, contains('.json'));
    expect([for (final f in logFilesIn(tmp.path)) p.basename(f)], ['eon.json']);
    final read = readLogs([
      p.join(tmp.path, 'eon.json'),
      p.join(tmp.path, 'Settings.JSON'),
    ], TankConfig());
    expect(read.dives.single.logFormat, suuntoJsonFormat);
    expect(read.warnings, ['Settings.JSON: not a dive log UWMedia reads']);
  });
}
