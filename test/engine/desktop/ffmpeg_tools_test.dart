// ffmpeg and ffprobe as processes (lib/engine/desktop/): the probes, a
// copy and an encode with their progress, an error and Stop, on a test
// pattern made at run time in a temporary folder. Needs ffmpeg and
// ffprobe on the PATH; without them the tests skip themselves.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';

import '../../helpers/tools.dart';

void main() {
  final skip = hasTool('ffmpeg') && hasTool('ffprobe')
      ? null
      : 'needs ffmpeg and ffprobe on the PATH';

  test('the command that ends a process tree on Windows', () {
    expect(windowsTreeKill(4242), ['taskkill', '/T', '/F', '/PID', '4242']);
  });

  test('a tool that is not there, or takes too long', () async {
    expect(await runCapture('/nowhere/at/all', const ['-version']), isNull);
    if (!Platform.isWindows) {
      final watch = Stopwatch()..start();
      expect(
        await runCapture('sleep', const [
          '30',
        ], timeout: const Duration(milliseconds: 200)),
        isNull,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    }
    final tools = FfmpegTools(
      ffmpeg: '/nowhere/ffmpeg',
      ffprobe: null,
      os: EngineOs.linux,
    );
    await expectLater(
      tools.duration('a.mp4'),
      throwsA(
        isA<EngineException>().having(
          (e) => e.message,
          'message',
          ffprobeMissingMessage,
        ),
      ),
    );
    await expectLater(tools.version(), throwsA(isA<EngineException>()));
    await expectLater(
      tools.run(const ['-version']),
      throwsA(isA<EngineException>()),
    );
    expect(await tools.encoder(hwAccel: false), encoderSoftware);
    expect(await tools.hardwareEncoders(), isEmpty);
  });

  group('with ffmpeg', () {
    late Directory tmp;
    late FfmpegTools tools;
    late String clip;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('uwmedia_engine_');
      final found = await ToolFinder.forThisMachine().findAll(const {});
      tools = FfmpegTools(
        ffmpeg: found[toolFfmpeg]!,
        ffprobe: found[toolFfprobe],
        os: currentEngineOs(),
      );
      clip = p.join(tmp.path, 'pattern.mp4');
      // Two seconds of a test pattern with a tone: no person's footage.
      final made = await runCapture(tools.ffmpeg, [
        '-y', '-loglevel', 'error', //
        '-f', 'lavfi', '-i', 'testsrc2=s=320x180:r=25:d=2',
        '-f', 'lavfi', '-i', 'sine=f=440:d=2',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest',
        clip,
      ]);
      expect(made?.exitCode, 0, reason: made?.stderr);
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    test('a command too long for Windows: its filter from a file', () async {
      final folders = <Directory>[];
      final long = FfmpegTools(
        ffmpeg: tools.ffmpeg,
        ffprobe: tools.ffprobe,
        os: tools.os,
        workDir: () => (folders..add(tmp.createTempSync('filters_'))).last,
      );
      // Some 15,000 characters of filter that does nothing, then a
      // scale that shows the graph was read.
      final graph = '${List.filled(3000, 'null').join(',')},scale=64:36';
      final out = p.join(tmp.path, 'scaled.mp4');
      await long.run([
        '-y', '-loglevel', 'error', '-i', clip, //
        '-vf', graph, '-an', '-c:v', 'libx264', out,
      ]);
      expect(await tools.dimensions(out), (64, 36));
      // The filter's file is gone with its folder.
      expect(folders, hasLength(1));
      expect(folders.single.existsSync(), isFalse);
    });

    test('what a file is', () async {
      expect(await tools.version(), startsWith('ffmpeg version'));
      expect(await tools.duration(clip), closeTo(2.0, 0.1));
      expect(await tools.dimensions(clip), (320, 180));
      expect(await tools.frameCount(clip), 50);
      expect(await tools.pixFmt(clip), 'yuv420p');
      expect(await tools.bitrate(clip), greaterThan(1000));
      // An H.264 clip of ffmpeg's making: for a hardware decoder. A file
      // that cannot be probed is not risked on a Mac (spec §10.73).
      final mac = currentEngineOs() == EngineOs.macos;
      expect(await tools.isHwDecodable(clip), isTrue);
      await expectLater(
        tools.duration(p.join(tmp.path, 'missing.mp4')),
        throwsA(isA<EngineException>()),
      );
      expect(await tools.frameCount(p.join(tmp.path, 'missing.mp4')), 0);
      expect(await tools.isHwDecodable(p.join(tmp.path, 'missing.mp4')), !mac);
    });

    test('a copy keeps the streams and reports its progress', () async {
      final out = p.join(tmp.path, 'copy.mp4');
      final seen = <double>[];
      await tools.processVideo(
        input: clip,
        output: out,
        creationDate: naive(2026, 5, 20, 22, 58, 22),
        tzOffsetMins: 480,
        hwAccel: false,
        onProgress: seen.add,
      );
      expect(await tools.dimensions(out), (320, 180));
      expect(await tools.frameCount(out), 50);
      expect(seen, isNotEmpty);
      expect(seen.last, 100.0);
      expect(seen, orderedEquals([...seen]..sort()));
    });

    test('an encode into a smaller frame', () async {
      final out = p.join(tmp.path, 'small.mp4');
      final seen = <double>[];
      await tools.processVideo(
        input: clip,
        output: out,
        creationDate: naive(2026, 5, 20, 22, 58, 22),
        hwAccel: false,
        targetResolution: (160, 120),
        onProgress: seen.add,
      );
      // The shape is kept and padded into the frame asked for.
      expect(await tools.dimensions(out), (160, 120));
      expect(seen.last, 100.0);
    });

    test('an error says what ffmpeg wrote', () async {
      await expectLater(
        tools.run(['-i', p.join(tmp.path, 'missing.mp4'), '-f', 'null', '-']),
        throwsA(
          isA<EngineException>()
              .having((e) => e.exitCode, 'exitCode', isNot(0))
              .having((e) => e.output, 'output', contains('missing.mp4')),
        ),
      );
    });

    test('Stop ends a run', () async {
      ToolRun? running;
      final seen = <double>[];
      // A pattern without an end, encoded slowly: it runs until stopped.
      final run = tools.run(
        [
          '-y', '-re', '-f', 'lavfi', '-i', 'testsrc2=s=320x180:r=25', //
          '-c:v', 'libx264', p.join(tmp.path, 'endless.mp4'),
        ],
        onStarted: (tool) => running = tool,
        onProgress: seen.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(running, isNotNull);
      final watch = Stopwatch()..start();
      // Listened for before Stop: on Windows the run can end while
      // taskkill is still being waited for.
      final ended = expectLater(run, throwsA(isA<RunStopped>()));
      await running!.stop();
      await ended;
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(running!.stopped, isTrue);
    });
  }, skip: skip);
}
