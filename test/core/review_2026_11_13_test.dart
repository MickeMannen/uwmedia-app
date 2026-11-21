// Cases the parity review of 2026-11-13 found outside the fixtures (three
// port-reviewer passes over the naming, date, MP4, YAML, template,
// designer, plan and engine modules). Each expectation is what the review
// ran on the Python side, or what the fix is meant to do where Python has
// no counterpart (the MP4 reader).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/config/yaml_text.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/overlay_document.dart';
import 'package:uwmedia_app/core/hud/template_store.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/mp4_dates.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/log_writers.dart';
import 'package:uwmedia_app/core/plan/plan_embed.dart';
import 'package:uwmedia_app/core/util/json_tree.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

import '../helpers/python_reference.dart';

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

Uint8List _box(String type, List<int> payload) => Uint8List.fromList([
  ..._u32(8 + payload.length),
  ...ascii.encode(type),
  ...payload,
]);

void main() {
  group('names', () {
    final taken = naive(2026, 9, 5, 14, 30);
    String renderLog(String pattern) => outputFilename(
      source: '/m/DSC01.MP4',
      outputDir: '/out',
      sourceIsFolder: false,
      args: NamingArgs(
        renderVideoLog: true,
        originalLayoutStem: 'hud1',
        renderLogFilenameFormat: pattern,
      ),
      creationDate: taken,
    );

    test('a render-log pattern with a slash keeps its last part', () {
      expect(renderLog('{datetaken:%D}_{hud}'), '26_hud1.mp4');
      expect(renderLog('sub/{filename}'), 'DSC01.mp4');
      expect(renderLog('{datetaken:%x}'), '26.mp4');
    });

    test('a field inside a field is the fallback name', () {
      expect(renderLog('{datetaken:%Y{hud}'), 'DSC01_hud1.mp4');
    });

    test('an empty output folder is the folder of a bare source name', () {
      expect(
        outputFilename(
          source: 'DSC01.JPG',
          outputDir: '',
          sourceIsFolder: false,
          args: const NamingArgs(),
          creationDate: taken,
        ),
        'DSC01.jpg',
      );
    });

    test('date codes with a flag that Python does not take', () {
      expect(() => pyStrftime(taken, '%-f'), throwsFormatException);
      expect(() => pyStrftime(taken, '%Ef'), throwsFormatException);
      expect(pyStrftime(taken, '%f'), '000000');
      expect(pyStrftime(taken, '%Y%m%d%:z'), '20260905');
    });

    test('%g rounds an exact half to the even digit', () {
      expect(pyFormatG(16.03125), '16.0312');
      expect(pyFormatG(1024.125), '1024.12');
      expect(pyFormatG(100000.5), '100000');
      expect(pyFormatG(999999.5), '1e+06');
      expect(pyFormatG(0.5), '0.5');
      expect(pyFormatG(1.4), '1.4');
      expect(pyFormatG(45), '45');
    });
  });

  group('dates', () {
    test('true and false as a timezone are 1 and 0 minutes', () {
      expect(timezoneOffsetMinutes({'Timezone': true}), 1);
      expect(timezoneOffsetMinutes({'TimeZone': false}), 0);
    });

    test('a local time past the year 9999 is not written', () {
      final updates = batchTimezoneUpdates(
        meta: {'QuickTime:CreateDate': '9999:12:31 23:59:59'},
        path: 'clip.mp4',
        mode: tzModeFromUtc,
        tzMinutes: 345,
      );
      // The UTC time itself, read as the file's own local time.
      expect(updates!['QuickTime:CreationDate'], '9999:12:31 23:59:59+05:45');
    });

    test('a row without a value is "None" to the filter', () {
      final rows = [(tag: 'a', value: null), (tag: 'b', value: 'x')];
      expect(filterMetadataRows(rows, 'non').single.tag, 'a');
      expect(filterMetadataRows(rows, 'nul'), isEmpty);
    });
  });

  group('MP4 files that are damaged', () {
    final sources =
        pythonReference('mp4/mp4_cases.json')['sources']
            as Map<String, dynamic>;
    Uint8List file(String name) => base64.decode(
      (sources[name] as Map<String, dynamic>)['base64'] as String,
    );

    test('data after the last box does not hide the dates', () {
      for (final tail in ['SEFT12345678', 'x' * 40]) {
        final bytes = Uint8List.fromList([
          ...file('ffmpeg_creation_time'),
          ...ascii.encode(tail),
        ]);
        final movie = Mp4Movie.read(MemoryBytes(bytes));
        expect(movie.tags['QuickTime:CreateDate'], '2025:10:19 02:21:31');
        // The tail is carried over as it is.
        final written = movie
            .write({'QuickTime:CreateDate': '2026:05:20 22:58:22'})
            .apply(MemoryBytes(bytes));
        expect(
          written.sublist(written.length - tail.length),
          ascii.encode(tail),
        );
      }
    });

    test('a cut-off mdat after the moov box still gives the dates', () {
      final whole = file('faststart');
      final cut = Uint8List.sublistView(whole, 0, whole.length - 500);
      expect(
        readMp4Tags(MemoryBytes(cut))['QuickTime:CreateDate'],
        '2025:10:19 02:21:31',
      );
    });

    test('a box of an impossible size is refused, not a crash', () {
      final huge = Uint8List.fromList([
        ...file('bare'),
        ..._u32(1), ...ascii.encode('free'), //
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF8,
      ]);
      // After the moov box: passed over.
      expect(Mp4Movie.read(MemoryBytes(huge)).boxes.last.type, 'moov');
      // Before it: not an MP4.
      expect(
        () => Mp4Movie.read(
          MemoryBytes(
            Uint8List.fromList([
              ..._u32(1), ...ascii.encode('free'), //
              0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF8,
              ...file('bare'),
            ]),
          ),
        ),
        throwsA(isA<Mp4Exception>()),
      );
    });

    test('a header box cut short', () {
      final moov = _box('moov', [
        ..._box('mvhd', []),
        ..._box('trak', _box('tkhd', [0, 0])),
      ]);
      final movie = Mp4Movie.read(MemoryBytes(moov));
      expect(() => movie.tags, throwsA(isA<Mp4Exception>()));
    });

    test('a 64-bit date that is no date reads as never set', () {
      List<int> u64(int v) =>
          (ByteData(8)..setUint64(0, v)).buffer.asUint8List();
      for (final value in [400000000000000, 0x4000000000000000]) {
        final mvhd = _box('mvhd', [
          1,
          0,
          0,
          0,
          ...u64(value),
          ...u64(0),
          ...List.filled(12, 0),
        ]);
        final movie = Mp4Movie.read(MemoryBytes(_box('moov', mvhd)));
        expect(movie.tags['QuickTime:CreateDate'], zeroDate);
      }
    });

    test('a chunk table that says more than it holds is not patched', () {
      List<int> table(int count) => _box('stco', [
        0,
        0,
        0,
        0,
        ..._u32(count),
        ..._u32(320),
        ..._u32(330),
      ]);
      Uint8List movie(int count) => Uint8List.fromList([
        ..._box('moov', [
          ..._box('mvhd', List.filled(100, 0)),
          ..._box(
            'trak',
            _box(
              'mdia',
              _box(
                'minf',
                _box('stbl', [
                  ...table(count),
                  ..._box('stsz', List.filled(12, 0)),
                ]),
              ),
            ),
          ),
        ]),
        ..._box('mdat', List.filled(64, 7)),
      ]);
      final good = Mp4Movie.read(MemoryBytes(movie(2)));
      expect(good.chunkOffsets, [
        [320, 330],
      ]);
      for (final count in [9, 0x7fffffff]) {
        final bad = Mp4Movie.read(MemoryBytes(movie(count)));
        expect(() => bad.chunkOffsets, throwsA(isA<Mp4Exception>()));
        expect(() => bad.write({'Make': 'X'}), throwsA(isA<Mp4Exception>()));
        // A date in the header can still be changed where it is.
        expect(
          bad.write({'CreateDate': '2026:05:20 22:58:22'}).keepsOffsets,
          isTrue,
        );
      }
    });

    test('a creation date that is no date is refused', () {
      final movie = Mp4Movie.read(MemoryBytes(file('bare')));
      expect(
        () => movie.write({'CreationDate': '2026:13:41 26:58:22+08:00'}),
        throwsFormatException,
      );
    });

    test('a key of another namespace and a second value survive a write', () {
      // A key list as ffmpeg writes it, changed by hand: the model's key
      // in another namespace.
      final source = file('mov_keys');
      final text = latin1.decode(source);
      final at = text.indexOf('mdtacom.apple.quicktime.model');
      final changed = Uint8List.fromList(source)
        ..setRange(at, at + 4, ascii.encode('udta'));
      final movie = Mp4Movie.read(MemoryBytes(changed));
      final written = movie
          .write({'QuickTime:Make': 'Other maker'})
          .apply(MemoryBytes(changed));
      expect(latin1.decode(written), contains('udtacom.apple.quicktime.model'));
      final after = Mp4Movie.read(MemoryBytes(written));
      expect(after.tags['QuickTime:Make'], 'Other maker');
      expect(after.tags['QuickTime:Model'], 'ILCE-6700');
      expect(after.tags['QuickTime:CreationDate'], '2025:10:19 10:21:31+08:00');
    });
  });

  group('YAML', () {
    test('a key twice makes the file unreadable, and says so', () {
      const text = 'other: 010\ntanks:\n  A: x\n  A: y\n';
      final config = ConfigFile.parse(text);
      expect(config.unreadable, isTrue);
      expect(config.tanks.tanks, isEmpty);
      expect(ConfigFile.parse('tanks:\n  A: x\n').unreadable, isFalse);
      expect(ConfigFile.parse(null).unreadable, isFalse);
      expect(yamlUnreadable('a: [unclosed'), isTrue);
    });

    test('anchors, aliases and tags give the value, not their own text', () {
      final tanks = ConfigFile.parse(
        'tanks:\n  A: &n Left\n  B: *n\n  C: !!str 12\n',
      ).tanks.tanks;
      expect(tanks, {'A': 'Left', 'B': 'Left', 'C': '12'});
    });

    test('a profile name with nothing under it is a profile', () {
      expect(mergedColorProfiles(null, 'empty:\nfull:\n  cifval: 1\n'), {
        'empty': <String, Object?>{},
        'full': {'cifval': 1},
      });
    });
  });

  group('designer', () {
    test('true is 1 to the document, as in Python', () {
      expect(jsonDeepEquals(true, 1), isTrue);
      expect(jsonDeepEquals(0.0, false), isTrue);
      expect(jsonDeepEquals(true, 2), isFalse);
      final doc = OverlayDocument({
        'hud_skin': {
          'type': 'shape',
          'linked_elements': [
            {'field': 'depth', 'rel_x': 0, 'rel_y': 0, 'outline': 1},
          ],
        },
      });
      doc.setElementAttr(0, 'outline', true);
      expect(doc.elements[0]['outline'], 1);
      expect(doc.dirty, isFalse);
      expect(doc.canUndo, isFalse);
    });

    test('a text element keeps an empty field of its own', () {
      final parsed = parseLayoutElements({
        'linked_elements': [
          {'field': null, 'rel_x': 0, 'rel_y': 0},
          {'field': null, 'type': 'badge', 'rel_x': 0, 'rel_y': 0},
        ],
      });
      expect(parsed[0].containsKey('field'), isTrue);
      expect(parsed[0]['field'], isNull);
      expect(parsed[1]['field'], 'state_badge');
    });

    test('paths with a drive letter are absolute in any context', () {
      expect(isAbsolutePath('C:/Users/x/skin.png', p.posix), isTrue);
      expect(isAbsolutePath(r'C:\Users\x\skin.png', p.posix), isTrue);
      expect(isAbsolutePath(r'\\server\share\skin.png', p.posix), isTrue);
      expect(isAbsolutePath('normal.png', p.posix), isFalse);
      expect(isAbsolutePath('/abs/skin.png', p.posix), isTrue);
      final doc = OverlayDocument({
        'hud_skin': {'type': 'image', 'path': 'C:/Users/x/skin.png'},
      }, sourcePath: 'templates/a/b/main/normal.json');
      expect(doc.skinAbsPath, 'C:/Users/x/skin.png');
    });

    test('a variant saved on Windows names its base with forward slashes', () {
      const base =
          '{"hud_skin": {"type": "shape", "linked_elements": '
          '[{"id": "depth", "field": "depth", "rel_x": 0.1, "rel_y": 0.1}]}}';
      const overlay = '{"base": "../normal.json", "linked_elements": []}';
      final files = {
        'b/c/manifest.json': '{"pages": [{"id": "main"}]}',
        'b/c/main/normal.json': base,
        'b/c/main/side/normal.json': overlay,
      };
      final store = TemplateStore(
        user: ListedTemplateFolder(r'C:\u\t', files.keys, (f) => files[f]),
        context: p.windows,
      );
      final layout = {
        ...jsonDecode(base) as Map<String, dynamic>,
        '_variant_of': r'C:\u\t/b/c/main/normal.json',
      };
      final save = store.saveTemplate(
        const TemplateRef('b', 'c', 'main', 'side'),
        layout,
      );
      final written = save.ops.whereType<WriteTextOp>().last.text;
      expect((jsonDecode(written) as Map)['base'], '../normal.json');
    });

    test('the home folder itself', () {
      expect(displayRoot('/Users/x', '/Users/x'), '~/.');
    });
  });

  group('plans', () {
    test('a key with nothing, or the wrong kind of value, is refused', () {
      for (final plan in <Map<String, dynamic>>[
        {'gases': null},
        {'waypoints': null},
        {'gases': 'x'},
        {'name': null},
        {'name': 5},
        {'computer': null},
        {'computer': 5},
        {'computer_serial': 123},
        {'dive_type': null},
        {'start_time': 'garbage'},
        {'start_time': ''},
        {'start_time': 1700000000},
        {
          'waypoints': [5],
        },
        {
          'gases': [
            {'id': 'x', 'color': 5},
          ],
        },
        {
          'gases': [
            {'id': 'x', 'gas_type': null},
          ],
        },
        {
          'gases': [
            {'id': 'x', 'diluent': null},
          ],
        },
        {
          'gases': [
            {'id': 'x', 'tank_ref': null},
          ],
        },
        {
          'gases': [
            {'sidemount_pair': true},
          ],
        },
        {
          'waypoints': [
            {'runtime_sec': 1, 'depth_m': 1, 'gas_id': 'a', 'gas_auto': null},
          ],
        },
      ]) {
        expect(
          () => DiveProfilePlan.fromJson(plan),
          throwsFormatException,
          reason: '$plan',
        );
      }
      // Nothing is a value for the fields that may be without one.
      final plan = DiveProfilePlan.fromJson({
        'start_time': null,
        'max_depth_m': null,
        'gases': [
          {'id': 'x', 'side': null, 'color': null, 'sac_lpm': null},
        ],
      });
      expect(plan.gases.single.side, isNull);
    });

    test('older forms Python reads', () {
      final plan = DiveProfilePlan.fromJson({
        'ccr_setpoint_switch_depth_m': '10',
        'gases': [
          {'id': 'x', 'sidemount_pair': 1},
        ],
      });
      expect(plan.ccrHighSetpointDepthM, 10.0);
      expect(plan.ccrLowSetpointDepthM, 4.0);
      expect(
        [for (final g in plan.gases) (g.id, g.side, g.tankRef)],
        [('x', 'left', 'T1'), ('x R', 'right', 'T2')],
      );
    });

    test('an envelope whose plan is not a plan', () {
      expect(planFromJson('{"format":"uwmedia_dive_plan","plan":[1]}'), isNull);
      expect(planFromJson('{"format":"uwmedia_dive_plan","plan":"x"}'), isNull);
      expect(
        planFromJson('{"format":"uwmedia_dive_plan","plan":null}'),
        isNotNull,
      );
      expect(
        planFromJson('{"format":"uwmedia_dive_plan","plan":[]}'),
        isNotNull,
      );
    });

    test('the mark in a CDATA note, and a plan after an empty entry', () {
      Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));
      expect(
        readLogOrigin(
          'a.ssrf',
          bytes(
            '<divelog><dives><dive><notes><![CDATA[from the UWMedia Dive '
            'Profile Builder]]></notes></dive></dives></divelog>',
          ),
        ).createdByUwmedia,
        isTrue,
      );
      final origin = readLogOrigin(
        'a.ssrf',
        bytes(
          '<divelog><dives><dive><divecomputer>'
          '<extradata key="UWMedia plan"/>'
          '<extradata key="UWMedia plan" value="{&quot;format&quot;:'
          '&quot;uwmedia_dive_plan&quot;,&quot;plan&quot;:{}}"/>'
          '</divecomputer></dive></dives></divelog>',
        ),
      );
      expect(origin.plan, isNotNull);
    });

    test('a name XML cannot hold is refused by the writers', () {
      final plan = DiveProfilePlan.fromJson({
        'name': 'Reef',
        'gases': [
          {'id': 'A\u0001'},
        ],
        'waypoints': [
          {'runtime_sec': 60, 'depth_m': 10, 'gas_id': 'A\u0001'},
          {'runtime_sec': 300, 'depth_m': 10, 'gas_id': 'A\u0001'},
        ],
      });
      final (samples, _) = simulate(plan, resolutionSec: 60);
      final now = naive(2026, 11, 13, 12);
      expect(
        () => uddfText(plan, samples, now: now, utcOffsetMinutes: 0),
        throwsFormatException,
      );
      // Subsurface holds the gas name only inside the plan's JSON, where
      // the character is escaped: that log is written.
      expect(subsurfaceText(plan, samples, now: now), contains(r'A\u0001'));
      final named = DiveProfilePlan.fromJson({
        ...plan.toJson(),
        'name': 'Reef\u0001',
      });
      expect(
        () => subsurfaceText(named, samples, now: now),
        throwsFormatException,
      );
    });
  });

  group('engine', () {
    test('a concat list keeps a backslash in a folder name off Windows', () {
      expect(
        ffconcatText([(r'/tmp/a\b/hud0_00000.png', 30)], 30),
        "ffconcat version 1.0\nfile '/tmp/a\\b/hud0_00000.png'\nduration 1.000000\n",
      );
      expect(
        ffconcatText([(r'C:\w\hud0_00000.png', 30)], 30, windowsPaths: true),
        contains("file 'C:/w/hud0_00000.png'"),
      );
    });

    test('no analysed frame, no LUT filter', () {
      expect(
        () => lut3dFilter(frameIndices: [], filters: [], fps: 30, lutDir: '/w'),
        throwsArgumentError,
      );
    });
  });
}
