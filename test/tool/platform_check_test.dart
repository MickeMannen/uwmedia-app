// The platform check's pieces that run without a device: the case pack
// and its embedded copy, the plain-Dart checks on this machine, and the
// compare tool's tolerances and PNG reading (tool/platform_check/).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/platform_check/checks.dart' as checks;
import '../../integration_test/platform_check/checks.dart' hide reportFormat;
import '../../integration_test/platform_check/engine_check.dart' show median;
import '../../integration_test/platform_check/pack.g.dart';
import '../../integration_test/platform_check/screens.dart';
import '../../integration_test/platform_check/summary.dart';
import '../../tool/platform_check/compare.dart';
import '../../tool/platform_check/embed_pack.dart';
import '../../tool/platform_check/perf_gate.dart' as perf;

final Map<String, dynamic> _pack =
    jsonDecode(File(casesPath).readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _report(
  String implementation,
  List<Map<String, dynamic>> checks,
) => {
  'format': reportFormat,
  'implementation': implementation,
  'checks': checks,
};

Map<String, dynamic> _check(
  String area,
  String id,
  Object? result, {
  String status = 'pass',
}) => {
  'area': area,
  'id': id,
  'status': status,
  'reason': status == 'pass' ? null : 'because',
  'time_ms': 1,
  'result': result,
};

List<Outcome> _outcomes(
  String area,
  Object? a,
  Object? b, {
  bool pythonIsB = false,
  List<KnownDifference> known = const [],
  String? format,
}) {
  final notes = <LeafNote>[];
  compareValues(
    area,
    a,
    b,
    notes,
    pythonIsB: pythonIsB,
    known: known,
    format: format,
  );
  return [for (final n in notes) n.outcome];
}

/// A PNG of [rgb] (filter 0 on every line, colour type 2).
Uint8List _png(int width, int height, Uint8List rgb) {
  List<int> chunk(String type, List<int> body) {
    final typed = [...ascii.encode(type), ...body];
    final length = ByteData(4)..setUint32(0, body.length);
    final crc = ByteData(4)..setUint32(0, _crc32(typed));
    return [
      ...length.buffer.asUint8List(),
      ...typed,
      ...crc.buffer.asUint8List(),
    ];
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  final raw = <int>[];
  for (var y = 0; y < height; y++) {
    raw
      ..add(0)
      ..addAll(rgb.sublist(y * width * 3, (y + 1) * width * 3));
  }
  return Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, //
    ...chunk('IHDR', header.buffer.asUint8List()),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', const []),
  ]);
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

void main() {
  group('the case pack', () {
    test('pack.g.dart holds cases.json and the clip it describes', () {
      final cases = File(casesPath).readAsBytesSync();
      expect(
        base64Decode(packJsonBase64),
        cases,
        reason: 'run: dart run tool/platform_check/embed_pack.dart',
      );
      final file = File('$packDir/${clipFileName(cases)}').readAsBytesSync();
      expect(
        File(generatedPath).readAsStringSync(),
        packSource(cases, file),
        reason: 'run: dart run tool/platform_check/embed_pack.dart',
      );
      expect(base64Decode(clipBase64), file);
    });

    for (final key in ['clip', 'perf']) {
      test('the $key clip is the file cases.json describes', () {
        final engine = _pack['engine'] as Map<String, dynamic>;
        final spec = key == 'clip'
            ? engine['clip'] as Map<String, dynamic>
            : (engine['perf'] as Map<String, dynamic>)['clip']
                  as Map<String, dynamic>;
        final bytes = File('$packDir/${spec['file']}').readAsBytesSync();
        expect(bytes.length, spec['bytes']);
        expect(sha256.convert(bytes).toString(), spec['sha256']);
        // Small: the 2 s clip is built into the test, the perf clip copied
        // to phones.
        expect(bytes.length, lessThan(key == 'clip' ? 400e3 : 8e6));
      });
    }

    test('the test and the compare tool name the same format', () {
      expect(checks.reportFormat, reportFormat);
    });

    test('every render is a bundled template with a Python golden', () {
      final cases =
          (_pack['renders'] as Map<String, dynamic>)['cases'] as List<dynamic>;
      expect(cases, hasLength(greaterThanOrEqualTo(12)));
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final template = (c['template'] as List<dynamic>).join('/');
        expect(
          File('assets/overlays/templates/$template/normal.json').existsSync(),
          isTrue,
          reason: template,
        );
        expect(
          File('test/fixtures/python_reference/overlay_golden/${c['id']}.png')
              .existsSync(),
          isTrue,
          reason: '${c['id']}',
        );
      }
    });
  });

  test('the plain-Dart checks pass on this machine', () async {
    final recorder = CheckRecorder();
    await runDiveChecks(recorder, _pack);
    await runRuleChecks(
      recorder,
      _pack,
      jsonDecode(File('assets/hud_rules.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    await runColorChecks(
      recorder,
      _pack,
      File('assets/color.yaml').readAsStringSync(),
    );
    final failed = [
      for (final c in recorder.checks)
        if (c['status'] != 'pass') '${c['id']}: ${c['reason']}',
    ];
    expect(failed, isEmpty);
    expect(recorder.checks, hasLength(7 + 3 + 6));
    // A report holds plain JSON.
    expect(() => jsonEncode(recorder.checks), returnsNormally);
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('the summary', () {
    Map<String, dynamic> report(String implementation) => {
      'implementation': implementation,
      'started': '2026-11-15T01:12:57.718964Z',
      'app': {'version': '1.0.0', 'build': '1'},
      'platform': {
        'os': 'macos',
        'os_version': 'Version 27.2.1 (Build 26B131)',
        'device': 'Mac14,7',
        'processors': 8,
      },
      'engine': {
        'engine': 'ffmpeg',
        'ffmpeg_version': 'ffmpeg version 9.0.2 Copyright (c) 2000-2026',
        'encoder': 'hevc_videotoolbox',
      },
      'checks': [
        _check('dives', 'dives/a', {}),
        _check('rules', 'rules/b', null, status: 'fail'),
        _check('engine', 'engine/perf/clip', {
          'sha256': '371bf1bb8129f6761ff3b20fdc578e1d769700989c72543d5d9c6f4b1c9a693f',
          'duration_s': 20.0,
          'width': 1920,
          'height': 1080,
          'fps': 30.0,
        }),
        _check('engine', 'engine/perf/color', {
          'repeats': 3,
          'run_ms_median': 7360.0,
          'output': {
            'width': 1920,
            'height': 1080,
            'codec': 'hevc',
            'bytes': 4912345,
          },
        }),
        {
          ..._check('engine', 'engine/perf/overlay/png', null, status: 'skip'),
          'reason': 'a desktop page',
        },
      ],
    };

    test('has the layout REPORT_FORMAT.md gives', () {
      expect(summaryText(report('dart'), clipSeconds: 20), '''
UWMedia platform check
implementation: flutter 1.0.0+1
os: macos Version 27.2.1 (Build 26B131)
device: Mac14,7, 8 CPUs
engine: ffmpeg 9.0.2, hevc_videotoolbox, hw accel on
clip: perf_clip.mp4 371bf1bb8129, 20.0 s 1920x1080 30 fps
checks: 1 pass, 1 fail, 0 skip
perf: median of 3, seconds of the run itself, x realtime
  color               7.36 s    2.72x  1920x1080 hevc 4.9 MB
  overlay/png     skipped: a desktop page
started: 2026-11-15T01:12:57.718964Z
''');
    });

    test('without a perf clip or an engine', () {
      final r = report('python')
        ..['engine'] = <String, dynamic>{}
        ..['checks'] = [
          {
            ..._check('engine', 'engine/perf/clip', null, status: 'skip'),
            'reason': 'PERF=0',
          },
        ];
      final text = summaryText(r, clipSeconds: 20);
      expect(text, contains('implementation: python 1.0.0+1\n'));
      expect(text, contains('engine: none\n'));
      expect(text, contains('clip: none (PERF=0)\n'));
      expect(text, contains('checks: 0 pass, 0 fail, 0 skip\n'));
    });

    testWidgets('the screen copies the text and ends on Done', (tester) async {
      final copied = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text']);
          }
          return null;
        },
      );
      final done = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(home: SummaryScreen('line one\n', done)),
      );
      expect(find.text('line one\n'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, ['line one\n']);
      expect(done.isCompleted, isFalse);
      await tester.tap(find.text('Done'));
      expect(done.isCompleted, isTrue);
    });
  });

  group('the compare tool', () {
    test('parsed values: decimals within 1e-6, text exactly', () {
      expect(_outcomes('dives', 1.0, 1.0 + 1e-9), [Outcome.tolerated]);
      expect(_outcomes('dives', 1.0, 1.001), [Outcome.different]);
      expect(_outcomes('dives', 3, 3.0), isEmpty);
      expect(_outcomes('dives', 'AIR', 'Nx32'), [Outcome.different]);
      expect(_outcomes('dives', [1, 2], [1, 2, 3]), [
        Outcome.different,
      ], reason: 'lengths');
      expect(_outcomes('rules', {'state': 'deco'}, {'state': 'normal'}), [
        Outcome.different,
      ]);
    });

    test('known deviations count only against Python', () {
      final known = [
        for (final k in _pack['known_differences'] as List<dynamic>)
          KnownDifference(k as Map<String, dynamic>),
      ];
      // Dart null where Python stores 0 (spec §10.8).
      expect(
        _outcomes(
          'dives',
          {'temp': null},
          {'temp': 0.0},
          pythonIsB: true,
          known: known,
        ),
        [Outcome.known],
      );
      expect(_outcomes('dives', {'temp': null}, {'temp': 0.0}, known: known), [
        Outcome.different,
      ]);
      // A tank's pressure lies under `tanks`; a count is never excused.
      expect(
        _outcomes(
          'dives',
          {
            'tanks': {'1': null},
            'dive_count': null,
          },
          {
            'tanks': {'1': 0.0},
            'dive_count': 0,
          },
          pythonIsB: true,
          known: known,
        ),
        [Outcome.different, Outcome.known],
      );
      // surf_gf set by the port alone (spec §10.16).
      expect(
        _outcomes(
          'dives',
          {'surf_gf': 80.0},
          {'surf_gf': null},
          pythonIsB: true,
          known: known,
        ),
        [Outcome.known],
      );
      // The Shearwater gradient factors only for the Shearwater formats.
      for (final (format, outcome) in [
        ('shearwater_xml', Outcome.known),
        ('uddf', Outcome.different),
      ]) {
        expect(
          _outcomes(
            'dives',
            {'gf_low': 30},
            {'gf_low': null},
            pythonIsB: true,
            known: known,
            format: format,
          ),
          [outcome],
          reason: format,
        );
      }
    });

    test('colour: the filter within 1e-6, the corrected hash per pair', () {
      expect(
        _outcomes(
          'color',
          {
            'filter': [0.5],
          },
          {
            'filter': [0.5 + 5e-7],
          },
        ),
        [Outcome.tolerated],
      );
      expect(
        _outcomes(
          'color',
          {
            'filter': [0.5],
          },
          {
            'filter': [0.5001],
          },
        ),
        [Outcome.different],
      );
      expect(
        _outcomes(
          'color',
          {'corrected_mean': 100.0},
          {'corrected_mean': 100.04},
        ),
        [Outcome.tolerated],
      );
      expect(
        _outcomes(
          'color',
          {'corrected_sha256': 'a'},
          {'corrected_sha256': 'b'},
        ),
        [Outcome.different],
      );
      expect(
        _outcomes(
          'color',
          {'corrected_sha256': 'a'},
          {'corrected_sha256': 'b'},
          pythonIsB: true,
        ),
        [Outcome.info],
      );
    });

    test('engine: frame means within 4, grid cells within 12', () {
      Map<String, Object?> frame(double mean, double cell) => {
        'codec': 'hevc',
        'frames_at': [
          {
            'mean': [mean, mean, mean],
            'grid': [
              [cell, cell, cell],
            ],
          },
        ],
        'bytes': 1000 + mean.toInt(),
        'frames': 61,
      };
      expect(_outcomes('engine', frame(100, 100), frame(103, 111)).toSet(), {
        Outcome.tolerated,
        Outcome.info,
      });
      expect(
        _outcomes('engine', frame(100, 100), frame(100, 140)),
        contains(Outcome.different),
      );
      expect(_outcomes('engine', {'codec': 'hevc'}, {'codec': 'h264'}), [
        Outcome.different,
      ]);
      expect(_outcomes('engine', {'frames': 61}, {'frames': null}), [
        Outcome.info,
      ]);
    });

    test('engine runs: the change from each platform\'s own clip', () {
      Map<String, dynamic> frames(String id, double cell) =>
          _check('engine', id, {
            'width': 4,
            'frames_at': [
              {
                't': 0.5,
                'mean': [cell, cell, cell],
                'grid': [
                  [cell, cell, cell],
                ],
              },
            ],
          });
      List<CheckComparison> run(double outB) => compareReports(
        _report('dart', [
          frames('engine/source_clip', 0),
          frames('engine/color_overlay', 50),
        ]),
        _report('dart', [
          frames('engine/source_clip', 23),
          frames('engine/color_overlay', outB),
        ]),
      );
      // B reads the clip 23 levels brighter, and its output alike: the
      // same change, so only the reading differs.
      final same = run(73);
      expect(same.first.status, CheckStatus.different);
      expect(same.last.status, CheckStatus.identical);
      expect(same.last.notes.map((n) => n.outcome).toSet(), {
        Outcome.info,
      }, reason: 'the absolute means are only shown');
      // B's run changed the picture 25 levels less.
      expect(run(48).last.status, CheckStatus.different);
    });

    test('times are only shown, in the performance table', () {
      Map<String, dynamic> timed(String id, Object ms) => _check('engine', id, {
        'encoder': 'hevc_videotoolbox',
        'run_ms': ms,
        if (ms is List) 'run_ms_median': median(ms.cast<int>()),
      });
      final a = _report('dart', [
        timed('engine/overlay/png', 100),
        timed('engine/perf/color', [900, 1000, 5000]),
      ]);
      final b = _report('python', [
        timed('engine/overlay/png', 250),
        timed('engine/perf/color', [2000, 2000]),
      ]);
      expect(compareReports(a, b).map((r) => r.status).toSet(), {
        CheckStatus.identical,
      });
      final table = performanceTable(a, b);
      expect(table, contains('engine/overlay/png'));
      expect(
        RegExp(r'engine/perf/color +1000 ms +2000 ms +2\.00').hasMatch(table),
        isTrue,
        reason: table,
      );
    });

    test('overlay-only runs are not taken relative to the clip', () {
      Map<String, dynamic> frames(String id, double cell) =>
          _check('engine', id, {
            'frames_at': [
              {
                't': 0.5,
                'mean': [cell, cell, cell],
                'grid': [
                  [cell, cell, cell],
                ],
              },
            ],
          });
      final results = compareReports(
        _report('dart', [
          frames('engine/source_clip', 0),
          frames('engine/overlay/hevc', 50),
        ]),
        _report('dart', [
          frames('engine/source_clip', 23),
          frames('engine/overlay/hevc', 73),
        ]),
      );
      expect(results.last.status, CheckStatus.different);
    });

    test('renders: the PNGs within the pair\'s limits', () {
      final a = Uint8List(10 * 10 * 3);
      final b = Uint8List.fromList(a);
      // Five pixels of a hundred off by 60: mean 3.0, 5 %.
      for (var i = 0; i < 5 * 3; i++) {
        b[i] = 60;
      }
      final files = {'a': _png(10, 10, a), 'b': _png(10, 10, b)};
      Map<String, dynamic> render(String png) => _check('renders', 'r', {
        'png': png,
        'size': [10, 10],
      });
      CheckStatus status(bool python) => compareReports(
        _report('dart', [render('a')]),
        _report(python ? 'python' : 'dart', [render('b')]),
        filesA: (n) => files[n],
        filesB: (n) => files[n],
      ).single.status;
      expect(status(false), CheckStatus.tolerated, reason: '5 % <= 6 %');
      expect(status(true), CheckStatus.different, reason: '5 % > 4 %');
      expect(
        compareReports(
          _report('dart', [render('a')]),
          _report('dart', [render('a')]),
          filesA: (n) => files[n],
          filesB: (n) => files[n],
        ).single.status,
        CheckStatus.identical,
      );
    });

    test('missing, failed and skipped checks', () {
      final results = compareReports(
        _report('dart', [
          _check('rules', 'one', {'x': 1}),
          _check('rules', 'two', null, status: 'fail'),
          _check('rules', 'three', null, status: 'skip'),
          _check('rules', 'four', {'x': 1}),
          _check('setup', 'setup/kit', {'x': 1}),
        ]),
        _report('dart', [
          _check('setup', 'setup/other', null, status: 'fail'),
          _check('rules', 'two', {'x': 1}),
          _check('rules', 'three', {'x': 1}),
          _check('rules', 'four', {'x': 1}),
          _check('rules', 'five', {'x': 1}),
        ]),
      );
      expect(
        {for (final r in results) r.id: r.status},
        {
          'one': CheckStatus.missing,
          'two': CheckStatus.failed,
          'three': CheckStatus.skipped,
          'four': CheckStatus.identical,
          'five': CheckStatus.missing,
          'setup/other': CheckStatus.failed,
        },
      );
      expect(results.where((r) => r.status.bad), hasLength(4));
    });

    testWidgets('PNGs read as Flutter reads them', (tester) async {
      await tester.runAsync(() async {
        Future<Uint8List> flutterRgb(Uint8List png) async {
          final codec = await ui.instantiateImageCodec(png);
          final image = (await codec.getNextFrame()).image;
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          image.dispose();
          final rgba = data!.buffer.asUint8List();
          return Uint8List.fromList([
            for (var i = 0; i < rgba.length; i += 4) ...rgba.sublist(i, i + 3),
          ]);
        }

        // OpenCV's PNGs (RGB, adaptive filters) of the Python goldens.
        for (final name in [
          'shearwater__perdix_3__main_ai__normal.png',
          'suunto__nautic__main__single_tank__normal.png',
        ]) {
          final png = File(
            'test/fixtures/python_reference/overlay_golden/$name',
          ).readAsBytesSync();
          expect(decodePng(png).rgb, await flutterRgb(png), reason: name);
        }
        // Flutter's own (RGBA).
        final rgba = Uint8List(37 * 23 * 4);
        for (var i = 0; i < rgba.length; i++) {
          rgba[i] = i % 4 == 3 ? 255 : (i * 7919) % 251;
        }
        final descriptor = ui.ImageDescriptor.raw(
          await ui.ImmutableBuffer.fromUint8List(rgba),
          width: 37,
          height: 23,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final image =
            (await (await descriptor.instantiateCodec()).getNextFrame()).image;
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        expect(decodePng(png).rgb, await flutterRgb(png));
      });
    });
  });

  group('the speed gate', () {
    Map<String, dynamic> timed(
      Map<String, num> runs, {
      String encoder = 'hevc_videotoolbox',
      String mode = 'debug',
    }) => {
      ..._report('flutter', [
        _check('engine', 'engine/color', {'run_ms': 1600}),
        for (final MapEntry(:key, :value) in runs.entries)
          _check('engine', 'engine/perf/$key', {
            'encoder': encoder,
            'repeats': 3,
            'run_ms': [value],
            'run_ms_median': value,
          }),
      ]),
      'platform': {
        'os': 'macos',
        'device': 'Mac14,7',
        'processors': 8,
        'build_mode': mode,
      },
      'started': '2026-11-15T03:35:36Z',
    };

    final baseline = perf.baselineOf(
      timed({'color': 7600, 'overlay/png': 260}),
      commit: 'abc1234',
    );

    test('a baseline keeps the timed runs of the machine', () {
      expect(perf.baselineName(timed({})), 'macos-Mac14-7.json');
      expect(baseline['runs'], {
        'engine/perf/color': {'ms': 7600, 'encoder': 'hevc_videotoolbox'},
        'engine/perf/overlay/png': {'ms': 260, 'encoder': 'hevc_videotoolbox'},
      });
      expect(baseline['repeats'], 3);
      expect(baseline['commit'], 'abc1234');
    });

    Map<String, perf.PerfStatus> statuses(Map<String, dynamic> report) => {
      for (final l in perf.gate(report, baseline)) l.id: l.status,
    };

    test('slower needs both 15 % and 150 ms', () {
      // 7600 * 1.15 = 8740; 260 + 150 = 410.
      expect(statuses(timed({'color': 8741, 'overlay/png': 400})), {
        'engine/perf/color': perf.PerfStatus.slower,
        'engine/perf/overlay/png': perf.PerfStatus.same,
      });
      expect(statuses(timed({'color': 8740, 'overlay/png': 411})), {
        'engine/perf/color': perf.PerfStatus.same,
        'engine/perf/overlay/png': perf.PerfStatus.slower,
      });
      expect(
        perf.passes(
          perf.gate(timed({'color': 8740, 'overlay/png': 400}), baseline),
        ),
        isTrue,
      );
    });

    test('faster passes; missing and other encoders or modes do not', () {
      final faster = perf.gate(
        timed({'color': 6000, 'overlay/png': 250}),
        baseline,
      );
      expect(faster.first.status, perf.PerfStatus.faster);
      expect(perf.passes(faster), isTrue);
      expect(statuses(timed({'color': 7600})), {
        'engine/perf/color': perf.PerfStatus.same,
        'engine/perf/overlay/png': perf.PerfStatus.missing,
      });
      for (final report in [
        timed({'color': 7600, 'overlay/png': 260}, encoder: 'libx265'),
        timed({'color': 7600, 'overlay/png': 260}, mode: 'profile'),
      ]) {
        final lines = perf.gate(report, baseline);
        expect(lines.map((l) => l.status).toSet(), {
          perf.PerfStatus.notComparable,
        });
        expect(perf.passes(lines), isFalse);
      }
    });
  });
}
