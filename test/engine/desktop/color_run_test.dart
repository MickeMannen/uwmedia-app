// The colour run of the desktop engine (lib/engine/desktop/color_run.dart)
// end to end with a real ffmpeg, on clips made at run time in a temporary
// folder: colour bars with a blue-green cast, and bars whose cast changes
// halfway.
// Needs ffmpeg and ffprobe on the PATH; without them the tests skip
// themselves.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/color_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/pages/shared/watermarks_section.dart';

import '../../helpers/tools.dart';

void main() {
  final skip = hasTool('ffmpeg') && hasTool('ffprobe')
      ? null
      : 'needs ffmpeg and ffprobe on the PATH';

  test('frame rates and the size the analysis works at', () {
    expect(
      parseFps('avg_frame_rate=30000/1001\nr_frame_rate=30/1\n'),
      30000 / 1001,
    );
    expect(parseFps('r_frame_rate=25/1\navg_frame_rate=0/0\n'), 25.0);
    expect(parseFps('avg_frame_rate=50\n'), 50.0);
    expect(parseFps('avg_frame_rate=N/A'), 30.0);
    expect(parseFps(null), 30.0);
    expect(analysisSize(3840, 2160), (240, 135));
    expect(analysisSize(1920, 1080), (240, 135));
    expect(analysisSize(320, 180), (320, 180));
    expect(analysisSize(180, 4000), (180, 4000));
    expect(
      frameGrabArgs('/m/a.mp4', 2.5, width: 240, height: 135).join(' '),
      '-nostdin -loglevel error -ss 2.500000 -i /m/a.mp4 -frames:v 1 '
      '-vf scale=in_color_matrix=bt601,format=rgb24,scale=240:135:flags=area '
      '-f rawvideo -pix_fmt rgb24 -',
    );
    // By the hardware: the system's decoder named before the source.
    List<String> hw(EngineOs os) => frameGrabArgs(
      '/m/a.mp4',
      2.5,
      width: 240,
      height: 135,
      hwAccel: os,
    ).sublist(0, 6);
    expect(
      hw(EngineOs.macos).join(' '),
      contains('error -hwaccel videotoolbox -ss'),
    );
    expect(hw(EngineOs.windows).join(' '), contains('error -hwaccel auto -ss'));
  });

  group('with ffmpeg', () {
    late Directory tmp;
    late FfmpegTools tools;
    late ColorRun run;
    late String steady;
    late String changing;
    final made = <String>[];

    // The mean of each channel of a clip's frame at [seconds].
    Future<List<double>> means(String path, double seconds) async {
      final frame = (await tools.frameAt(
        path,
        seconds,
        width: 64,
        height: 36,
      ))!;
      final sums = [0, 0, 0];
      for (var i = 0; i < frame.rgb.length; i++) {
        sums[i % 3] += frame.rgb[i];
      }
      return [for (final s in sums) s / (frame.rgb.length / 3)];
    }

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('uwmedia_color_');
      final found = await ToolFinder.forThisMachine().findAll(const {});
      tools = FfmpegTools(
        ffmpeg: found[toolFfmpeg]!,
        ffprobe: found[toolFfprobe],
        os: currentEngineOs(),
      );
      final profiles = mergedColorProfiles(
        File('assets/color.yaml').readAsStringSync(),
        null,
      );
      run = ColorRun(
        tools: tools,
        engine: ColorEngine(
          ColorProfile.fromMap(profiles['default']!.cast<String, dynamic>()),
        ),
        tempDir: (prefix) {
          final dir = Directory(p.join(tmp.path, 'tmp'))
            ..createSync(recursive: true);
          final fresh = dir.createTempSync(prefix);
          made.add(fresh.path);
          return fresh;
        },
        hwAccel: false,
      );
      // Under water: red mostly gone, a blue-green cast.
      const cast = 'colorchannelmixer=rr=0.25:gg=0.8:bb=0.9';
      // ... and deeper: hardly any red, less green.
      const deeper = 'colorchannelmixer=rr=0.05:gg=0.45:bb=1.0';
      steady = p.join(tmp.path, 'steady.mp4');
      changing = p.join(tmp.path, 'changing.mp4');
      for (final args in [
        ['-f', 'lavfi', '-i', 'smptebars=s=320x180:r=25:d=3,$cast', steady],
        [
          '-f', 'lavfi', '-i', 'smptebars=s=320x180:r=25:d=3,$cast', //
          '-f', 'lavfi', '-i', 'smptebars=s=320x180:r=25:d=3,$deeper',
          '-filter_complex', '[0:v][1:v]concat=n=2:v=1[v]', '-map', '[v]',
          changing,
        ],
      ]) {
        final result = await runCapture(tools.ffmpeg, [
          '-y', '-loglevel', 'error', //
          ...args.sublist(0, args.length - 1),
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
          // A run keeps the source's bit rate: this flat clip left to
          // itself has some 6 kbit/s, at which the encoder cannot follow
          // a fade's frames (2 to 3 levels off a straight mix, where a
          // lossless output is within half a level).
          if (args.last == changing) ...[
            '-b:v', '400k', '-minrate', '400k', '-maxrate', '400k', //
            '-bufsize', '400k', '-x264-params', 'nal-hrd=cbr',
          ],
          args.last,
        ]);
        expect(result?.exitCode, 0, reason: result?.stderr);
      }
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    test('what a clip is', () async {
      expect(await run.probe(steady), (
        fps: 25.0,
        width: 320,
        height: 180,
        totalFrames: 75,
        tenBit: false,
      ));
      final frame = await tools.frameAt(steady, 1.0, width: 160, height: 90);
      expect(frame!.rgb.length, 160 * 90 * 3);
      expect(await tools.frameAt(steady, 99.0, width: 160, height: 90), isNull);
      // Decoded by the hardware (or, where there is none, by the software
      // after all) it is the same picture, as the colour analysis looks at
      // it: on average within a level. The Gitea runner's Mac is 0.45 apart
      // on average, up to 62 on a few pixels of the pattern's sharp colour
      // edges (its VideoToolbox fills in colour another way; 2026-11-19).
      final byHardware = await tools.frameAt(
        steady,
        1.0,
        width: 160,
        height: 90,
        hwAccel: true,
      );
      expect(byHardware!.rgb.length, frame.rgb.length);
      var apart = 0;
      var sum = 0;
      var first = -1;
      for (var i = 0; i < frame.rgb.length; i++) {
        final d = (byHardware.rgb[i] - frame.rgb[i]).abs();
        apart = math.max(apart, d);
        sum += d;
        if (d > 0 && first < 0) {
          first = i - i % 3;
        }
      }
      expect(
        sum / frame.rgb.length,
        lessThanOrEqualTo(1),
        reason: apart == 0
            ? null
            : 'hardware apart from software: at most $apart, on average '
                  '${(sum / frame.rgb.length).toStringAsFixed(2)}; '
                  'pixel ${first ~/ 3}: '
                  '${byHardware.rgb.sublist(first, first + 3)} against '
                  '${frame.rgb.sublist(first, first + 3)}; '
                  '${await tools.version()}',
      );
      expect(
        await tools.frameAt(
          steady,
          99.0,
          width: 160,
          height: 90,
          hwAccel: true,
        ),
        isNull,
      );
    });

    test('a part of a clip (spec §10.75): only its frames are looked at '
        'and written', () async {
      final partRun = ColorRun(
        tools: tools,
        engine: run.engine,
        tempDir: run.tempDir,
        hwAccel: false,
        part: (start: 3.5, end: 5.0),
      );
      // The clip is its part to the run.
      final clip = await partRun.probe(changing);
      expect(clip.totalFrames, 38);
      final shared = await partRun.sharedArgs(
        input: changing,
        output: '/out.mp4',
        creationDate: naive(2026, 11, 18, 10),
        tzOffsetMins: null,
        tenBit: false,
      );
      expect(shared.input.sublist(shared.input.length - 4), [
        '-ss',
        '3.500',
        '-t',
        '1.500',
      ]);
      final out = p.join(tmp.path, 'part.mp4');
      final stats = await partRun.processVideoLut(
        input: changing,
        output: out,
        creationDate: naive(2026, 11, 18, 10),
      );
      expect(stats.totalFrames, 38);
      expect(await tools.countedFrames(out), inInclusiveRange(37, 39));
      // The part lies in the deeper half: its one filter is that half's,
      // not the first half's.
      final whole = await run.analyze(changing, await run.probe(changing));
      final part = await partRun.analyze(changing, clip);
      expect(part.filters.first, isNot(whole.filters.first));
      expect(part.filters.first, whole.filters.last);
    }, skip: skip);

    test('a frame is read with BT.601 whatever the clip is tagged with, as '
        'OpenCV reads it in the Python app', () async {
      // The same picture, tagged BT.709 (as a camera's clip is).
      final tagged = p.join(tmp.path, 'steady_709.mp4');
      final result = await runCapture(tools.ffmpeg, [
        '-y', '-loglevel', 'error', '-i', steady, '-c', 'copy', //
        '-bsf:v',
        'h264_metadata=colour_primaries=1:transfer_characteristics=1:'
            'matrix_coefficients=1',
        tagged,
      ]);
      expect(result?.exitCode, 0, reason: result?.stderr);
      final plain = await tools.frameAt(steady, 1.0, width: 160, height: 90);
      final read = await tools.frameAt(tagged, 1.0, width: 160, height: 90);
      expect(read!.rgb, plain!.rgb);
    });

    test('a clip of one cast gets one LUT and its red back', () async {
      final out = p.join(tmp.path, 'steady_color.mp4');
      final seen = <double>[];
      final stats = await run.processVideoLut(
        input: steady,
        output: out,
        creationDate: naive(2026, 5, 20, 22, 58, 22),
        tzOffsetMins: 480,
        onProgress: seen.add,
      );
      expect(stats.totalFrames, 75);
      // Frames 0 and 50, and the last.
      expect(stats.samples, 3);
      expect(stats.luts, 1);
      expect(await tools.dimensions(out), (320, 180));
      expect(await tools.countedFrames(out), 75);
      expect(await tools.pixFmt(out), 'yuv420p');

      final before = await means(steady, 1.0);
      final after = await means(out, 1.0);
      // Red comes back against blue.
      expect(after[0] / after[2], greaterThan(before[0] / before[2] * 1.3));

      expect(seen, isNotEmpty);
      expect(seen, orderedEquals([...seen]..sort()));
      expect(seen.first, lessThanOrEqualTo(analysisProgressEnd));
      expect(seen.last, 100.0);
      // The working folder is gone.
      expect(made, isNotEmpty);
      expect(made.any((dir) => Directory(dir).existsSync()), isFalse);
    });

    testWidgets("the watermark editor's sample on a computer: a video's "
        'middle frame as a PNG, a picture as it is', (tester) async {
      await tester.runAsync(() async {
        Directory fresh(String prefix) => tmp.createTempSync(prefix);
        final sample = await desktopSample(steady, tools, fresh);
        expect(p.basename(sample!), 'steady.png');
        final png = File(sample).readAsBytesSync();
        // The PNG's own size: the clip's, which is under the longest side.
        final header = ByteData.sublistView(png, 16, 24);
        expect((header.getUint32(0), header.getUint32(4)), (320, 180));
        expect(sampleFrameSide, greaterThan(320));
        // The middle frame, not a blank one.
        final codec = await ui.instantiateImageCodec(png);
        final image = (await codec.getNextFrame()).image;
        final rgba = (await image.toByteData())!.buffer.asUint8List();
        image.dispose();
        final middle = (await tools.frameAt(
          steady,
          1.5,
          width: 320,
          height: 180,
        ))!;
        expect(
          [rgba[0], rgba[1], rgba[2]],
          [middle.rgb[0], middle.rgb[1], middle.rgb[2]],
        );
        expect(
          await desktopSample('/pictures/reef.jpg', tools, fresh),
          '/pictures/reef.jpg',
        );
        // A video that is none gives no sample.
        final none = File(p.join(tmp.path, 'none.mp4'))
          ..writeAsStringSync('no video');
        expect(await desktopSample(none.path, tools, fresh), isNull);
      });
    });

    test('a clip whose cast changes gets a LUT for each', () async {
      final out = p.join(tmp.path, 'changing_color.mp4');
      final clip = await run.probe(changing);
      final analysis = await run.analyze(changing, clip);
      expect(analysis.samples, 4);
      expect(analysis.frames, [0, 50, 100, 149]);
      final lutDir = Directory(p.join(tmp.path, 'luts'))..createSync();
      final (vf, luts) = await run.writeLuts(
        analysis.frames,
        analysis.filters,
        clip.fps,
        lutDir,
      );
      expect(luts, greaterThan(1));
      // No LUT is named in the filter: they are the pictures of one file
      // of colour tables, one for each step up to the last LUT's (and
      // that one twice).
      expect(vf, isNot(contains('lut3d')));
      expect(vf, contains(lutTablesFileName));
      final kept = distinctFilters(analysis.frames, analysis.filters);
      final step = sampleStep(clip.fps);
      final tables = File(p.join(lutDir.path, lutTablesFileName));
      const table = lutSize * lutSize * lutSize * 3;
      expect(tables.lengthSync(), ((kept.last.$1 / step).ceil() + 2) * table);
      final bytes = tables.readAsBytesSync();
      expect(bytes.sublist(0, table), run.engine.lut3d(kept.first.$2));
      expect(
        bytes.sublist(bytes.length - table),
        run.engine.lut3d(kept.last.$2),
      );
      // Each LUT as a file of its own, to compare with.
      for (final (i, (_, filter)) in kept.indexed) {
        File(p.join(lutDir.path, lutFileName(i)))
            .writeAsStringSync(cubeFileText(run.engine.lut3d(filter), lutSize));
      }
      final cube = File(p.join(lutDir.path, 'lut_0001.cube')).readAsLinesSync();
      expect(cube.where((line) => line.startsWith('LUT_3D_SIZE')), [
        'LUT_3D_SIZE 64',
      ]);

      final stats = await run.processVideoLut(
        input: changing,
        output: out,
        creationDate: naive(2026, 5, 20, 22, 58, 22),
      );
      expect(stats.luts, luts);
      expect(await tools.countedFrames(out), 150);
      // Both halves are corrected, each by its own LUT: the deeper half,
      // with next to no red in the source, ends with a red share of its
      // own.
      for (final at in [1.0, 5.0]) {
        final before = await means(changing, at);
        final after = await means(out, at);
        expect(
          after[0] / after[2],
          greaterThan(before[0] / before[2] * 1.3),
          reason: 'at $at s',
        );
      }

      // Each half is what its own LUT alone makes of it, and not what the
      // other's makes (Python keeps the first LUT for the whole clip,
      // spec §10.56).
      final alone = <String>[];
      for (var i = 0; i < 2; i++) {
        final lut = filterPath(p.join(lutDir.path, lutFileName(i)));
        alone.add(p.join(tmp.path, 'lut_$i.mp4'));
        final result = await runCapture(tools.ffmpeg, [
          '-y', '-loglevel', 'error', '-i', changing, //
          '-vf', "lut3d=file='$lut':interp=trilinear",
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', alone.last,
        ]);
        expect(result?.exitCode, 0, reason: result?.stderr);
      }
      Future<double> apart(String other, double at) async {
        final a = await means(out, at);
        final b = await means(other, at);
        return [for (var c = 0; c < 3; c++) (a[c] - b[c]).abs()]
            .reduce((m, v) => m > v ? m : v);
      }

      expect(luts, 2);
      expect(await apart(alone[0], 1.0), lessThan(6));
      expect(await apart(alone[1], 5.0), lessThan(6));
      expect(await apart(alone[0], 5.0), greaterThan(10));
      // The second LUT is alone on the frame it was made from, not one
      // later.
      final change =
          distinctFilters(analysis.frames, analysis.filters)[1].$1 / clip.fps;
      expect(await apart(alone[1], change), lessThan(6));
      expect(await apart(alone[0], change), greaterThan(10));
      // The first turns into it over the analysed step before (spec
      // §10.60): alone when the fade starts, then a share of each that
      // follows the time.
      final fade = sampleStep(clip.fps) / clip.fps;
      expect(change, 4.0);
      expect(fade, 2.0);
      expect(await apart(alone[0], change - fade), lessThan(6));
      // Measured on the first half's picture: on the deeper one the
      // first LUT's colours fall outside what the encoded file can hold,
      // so a mean of its frames is not what the mix was made from.
      for (final share in [0.1, 0.2, 0.3, 0.4, 0.48]) {
        final at = change - fade * (1 - share);
        final from = await means(alone[0], at);
        final to = await means(alone[1], at);
        final got = await means(out, at);
        for (var c = 0; c < 3; c++) {
          expect(
            got[c],
            closeTo(from[c] * (1 - share) + to[c] * share, 3),
            reason: 'channel $c at $at s: $from $to $got',
          );
        }
      }
      // ... which is neither LUT's own picture.
      final between = change - fade * 0.6;
      final gap =
          await apart(alone[0], between) + await apart(alone[1], between);
      expect(gap, greaterThan(10));
      expect(await apart(alone[0], between), greaterThan(gap * 0.3));
      expect(await apart(alone[1], between), greaterThan(gap * 0.3));
      // Five encodes: 23 s on the Gitea Linux runner, past 30 s while the
      // server ran the Windows VM too (run 145).
    }, tags: ['render']);

    group('the colour tables of many LUTs (spec §10.88)', () {
      // Twelve LUTs in turn, one a step (the step is 50 frames at 25 a
      // second): more than one batch of isolates on any machine.
      late List<int> frames;
      late List<Float32List> filters;
      late Uint8List first;
      late Uint8List second;
      setUpAll(() async {
        final clip = await run.probe(changing);
        final analysis = await run.analyze(changing, clip);
        frames = [for (var i = 0; i < 12; i++) i * 50];
        filters = [
          for (var i = 0; i < 12; i++)
            i.isEven ? analysis.filters.first : analysis.filters.last,
        ];
        first = run.engine.lut3d(filters[0]);
        second = run.engine.lut3d(filters[1]);
      });
      Directory fresh(String name) =>
          Directory(p.join(tmp.path, name))..createSync();
      ColorRun withFree(int? bytes) => ColorRun(
        tools: tools,
        engine: run.engine,
        tempDir: run.tempDir,
        hwAccel: false,
        freeSpace: (_) async => bytes,
      );

      test('worked out several at once, each table in its place', () async {
        final lutDir = fresh('many');
        final (_, luts) = await run.writeLuts(frames, filters, 25, lutDir);
        expect(luts, 12);
        expect(lutWorkers * lutsPerWorker, lessThan(12));
        final tables = lut3dFilter(
          frameIndices: frames,
          filters: filters,
          fps: 25,
          lutDir: lutDir.path,
        ).tables!;
        final bytes = File(p.join(lutDir.path, lutTablesFileName))
            .readAsBytesSync();
        expect(bytes.length, tables.length * lutTableBytes);
        for (final (i, lut) in tables.indexed) {
          final table = bytes.sublist(
            i * lutTableBytes,
            (i + 1) * lutTableBytes,
          );
          expect(
            listEquals(table, lut.isEven ? first : second),
            isTrue,
            reason: 'table $i, of LUT $lut',
          );
        }
      });

      test('refused before a byte is written when the disk has not room '
          'for them', () async {
        final lutDir = fresh('full');
        // Room for one table besides the margin, not for thirteen.
        await expectLater(
          withFree(freeSpaceMargin + lutTableBytes)
              .writeLuts(frames, filters, 25, lutDir),
          throwsA(
            isA<EngineException>().having(
              (e) => e.message,
              'message',
              allOf(contains('Not enough free space'), contains('GB free')),
            ),
          ),
        );
        expect(lutDir.listSync(), isEmpty);
        // Enough room, or none known: written.
        for (final free in [freeSpaceMargin + 13 * lutTableBytes, null]) {
          final ok = fresh('room_$free');
          await withFree(free).writeLuts(frames, filters, 25, ok);
          expect(
            File(p.join(ok.path, lutTablesFileName)).lengthSync(),
            13 * lutTableBytes,
          );
        }
      });

      test('Stop is taken between two batches of LUTs', () async {
        final lutDir = fresh('stopped');
        final control = RunControl();
        await control.stop();
        await expectLater(
          run.writeLuts(frames, filters, 25, lutDir, control: control),
          throwsA(isA<RunStopped>()),
        );
        expect(File(p.join(lutDir.path, lutTablesFileName)).lengthSync(), 0);
      });
    });

    test('Stop during the analysis and during the encode', () async {
      final control = RunControl();
      await control.stop();
      await expectLater(
        run.processVideoLut(
          input: steady,
          output: p.join(tmp.path, 'never.mp4'),
          creationDate: naive(2026, 5, 20),
          control: control,
        ),
        throwsA(isA<RunStopped>()),
      );
      expect(File(p.join(tmp.path, 'never.mp4')).existsSync(), isFalse);

      // Stopped at the first sign of the encode.
      final second = RunControl();
      final stopped = run.processVideoLut(
        input: changing,
        output: p.join(tmp.path, 'half.mp4'),
        creationDate: naive(2026, 5, 20),
        control: second,
        onProgress: (percent) {
          if (percent > analysisProgressEnd && !second.stopped) {
            second.stop();
          }
        },
      );
      // A clip this short may be done before the stop lands.
      try {
        await stopped;
      } on RunStopped {
        expect(second.stopped, isTrue);
      }
      expect(made.any((dir) => Directory(dir).existsSync()), isFalse);
    });

    test('a file that is no video', () async {
      final junk = p.join(tmp.path, 'junk.mp4');
      File(junk).writeAsStringSync('not a video');
      await expectLater(
        run.processVideoLut(
          input: junk,
          output: p.join(tmp.path, 'junk_out.mp4'),
          creationDate: naive(2026, 5, 20),
        ),
        throwsA(isA<EngineException>()),
      );
    });
  }, skip: skip);
}
