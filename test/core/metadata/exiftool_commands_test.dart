// The exiftool command lines against the Python app's: the parity fixture
// made by tool/python_reference/exiftool_fixture.py records what
// metadata/exif.py sends through pyexiftool for copies, reads and writes.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/metadata/exiftool_commands.dart';

import '../../helpers/python_reference.dart';

void main() {
  final reference = pythonReference('engine/exiftool_cases.json');

  test('carrying the metadata over: the commands in order', () {
    final copies = jsonObjects(reference['copies']);
    expect(copies.length, 23);
    for (final c in copies) {
      final meta = c['meta'] as Map<String, dynamic>;
      final commands = copyAllCommands(
        source: c['src'] as String,
        dest: c['dest'] as String,
        // exiftool's answer always names the file.
        meta: {'SourceFile': c['src'], ...meta},
        forcedTzMinutes: c['force_tz_mins'] as int?,
        customTags: (c['custom_tags'] as List<dynamic>?)?.cast<String>(),
      );
      // Python reads the source's tags again between the steps; the port
      // reads them once, before the first.
      final want = [
        for (final call in (c['calls'] as List<dynamic>).cast<List<dynamic>>())
          if (!call.contains('-j')) call,
      ];
      expect(c['result'], 'ok');
      expect(commands, want, reason: c['name'] as String);
    }
  });

  test('reads: the arguments and what comes of the answer', () {
    for (final c in jsonObjects(reference['reads'])) {
      final tags = (c['tags'] as List<dynamic>?)?.cast<String>();
      final [status, want] = c['result'] as List<dynamic>;
      expect(status, 'ok');
      expect(exiftoolReadArgs('/m/a.mp4', tags), (c['calls'] as List).single);
      // What exiftool would answer: the file's name and the case's tags.
      final answer =
          '[{"SourceFile": "/m/a.mp4", '
          '${_jsonBody(c['meta'] as Map<String, dynamic>)}}]';
      final meta = parseExiftoolJson(answer);
      if (tags == null) {
        expect(meta, want);
      } else {
        expect(namedTags(meta, tags), want, reason: c['name'] as String);
      }
    }
    expect(parseExiftoolJson(''), isNull);
    expect(parseExiftoolJson('[]'), isNull);
    expect(parseExiftoolJson('{"a": 1}'), isNull);
    expect(namedTags(null, ['a', 'b']), {'a': '', 'b': ''});
  });

  test('writes', () {
    for (final c in jsonObjects(reference['writes'])) {
      final tags = c['tags'] as Map<String, dynamic>;
      final calls = (c['calls'] as List<dynamic>).cast<List<dynamic>>();
      if (calls.isEmpty) {
        // Nothing to write: nothing is run.
        expect(tags, isEmpty);
        continue;
      }
      final path = c['path'] as String;
      expect(
        c['kind'] == 'set_tags'
            ? exiftoolSetTagsArgs(path, tags)
            : exiftoolTimezoneArgs(path, {
                for (final MapEntry(:key, :value) in tags.entries)
                  key: '$value',
              }),
        calls.single,
      );
    }
  });

  test('a date of Sony\'s XML', () {
    expect(
      xmlDateForXmp('2025:09:13 09:37:36+07:00'),
      '2025:09:13 09:37:36+07:00',
    );
    expect(xmlDateForXmp('2025-09-13T02:37:30Z'), '2025:09:13 02:37:30');
    expect(
      xmlDateForXmp('2025-09-13 09:37:36-00:00'),
      '2025:09:13 09:37:36+00:00',
    );
    expect(xmlDateForXmp('2025:09:13 09:37:36+24:00'), isNull);
    expect(xmlDateForXmp('yesterday'), isNull);
    expect(exiftoolXmpArgs('/out/a.mp4', {'QuickTime:Make': 'Sony'}), isNull);
  });
}

String _jsonBody(Map<String, dynamic> meta) => [
  for (final MapEntry(:key, :value) in meta.entries)
    '"$key": ${value is String ? '"$value"' : value}',
].join(', ');
