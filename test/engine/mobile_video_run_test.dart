// The phone's video and Color runs (lib/engine/mobile_video_run.dart,
// mobile_color_batch.dart, mobile_convert_run.dart) against a made-up
// engine: what the engine is asked to do (LUTs and their times, overlay
// pictures and where they go, bit rate, the HDR tone mapping), Stop, the
// dates carried over by the app's own writers, and the album save.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/compare_pictures.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/wipe_run.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/mobile_color_batch.dart';
import 'package:uwmedia_app/engine/mobile_convert_run.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/mp4_file.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';
import 'package:uwmedia_app/pages/color_tuning/color_tuning_page.dart';

import '../helpers/sony_mp4.dart';
import 'result_folder_test.dart' show FakeFolders;

const _video = 'test/fixtures/media/video/h264_10bit_422_720p_2s.mp4';
const _photo = 'test/fixtures/media/photo/jpeg_3x2_2mp.jpg';
const _template = 'assets/overlays/templates/garmin/mk3i/main';

/// An engine that answers from [clip], gives frames that turn from a blue
/// cast to a green one halfway, and "encodes" by copying the source.
class FakeEngine implements MobileMediaEngine {
  FakeEngine(this.clip);

  ClipInfo clip;
  final jobs = <EncodeJob>[];
  final asked = <double>[];

  /// What the pictures of each job were when it ran (they are removed
  /// after).
  final picturesSeen = <bool>[];
  Completer<void>? hold;
  bool cancelled = false;

  /// The encode is taken away at half way once and starts again.
  bool restartOnce = false;

  @override
  Future<ClipInfo> probe(String path) async => clip;

  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds, {
    required int maxWidth,
    required int maxHeight,
    bool exact = false,
  }) async {
    asked.add(seconds);
    final rgb = Uint8List(maxWidth * maxHeight * 3);
    final green = seconds >= clip.durationSeconds / 2;
    for (var i = 0; i < rgb.length; i += 3) {
      final shade = (i ~/ 3) % 200;
      rgb[i] = 20 + shade ~/ 8;
      rgb[i + 1] = green ? 150 + shade ~/ 4 : 60 + shade ~/ 4;
      rgb[i + 2] = green ? 70 + shade ~/ 4 : 160 + shade ~/ 4;
    }
    return RgbImage(maxWidth, maxHeight, rgb);
  }

  @override
  Future<EncodeResult> encode(
    EncodeJob job, {
    void Function(double percent)? onProgress,
    void Function()? onRestart,
  }) async {
    jobs.add(job);
    picturesSeen.add(
      job.layers.every(
        (l) => l.pictures.every((pic) => File(pic.path).existsSync()),
      ),
    );
    if (hold != null) {
      await hold!.future;
    }
    if (cancelled) {
      throw const RunStopped();
    }
    onProgress?.call(50);
    if (restartOnce) {
      restartOnce = false;
      onRestart?.call();
      onProgress?.call(5);
    }
    File(job.input).copySync(job.output);
    onProgress?.call(100);
    return (time: Duration.zero, bytes: 0, mime: 'video/hevc', encoder: 'x');
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    hold?.complete();
  }

  /// The videos of drawn frames: what was opened, and each picture's
  /// frames.
  final framesOpened =
      <({String output, int width, int height, bool prores})>[];
  final framesAdded = <int>[];
  int framesClosed = 0;
  int framesCancelled = 0;

  @override
  Future<void> framesOpen({
    required String output,
    required int width,
    required int height,
    required double fps,
    required bool prores,
  }) async => framesOpened.add((
    output: output,
    width: width,
    height: height,
    prores: prores,
  ));

  @override
  Future<void> framesAdd(Uint8List rgba, int count) async =>
      framesAdded.add(count);

  @override
  Future<void> framesClose() async {
    framesClosed++;
    File(framesOpened.last.output).writeAsStringSync('video');
  }

  @override
  Future<void> framesCancel() async => framesCancelled++;

  /// The copies asked for; [noCopy] refuses them, as an engine without.
  final copies = <(String, String)>[];
  bool noCopy = false;

  @override
  Future<void> copy(String input, String output) async {
    if (noCopy) {
      throw const EngineException('This engine copies no video');
    }
    copies.add((input, output));
    File(input).copySync(output);
  }
}

class FakeLibrary implements MediaLibrary {
  final saved = <(String name, String album, Uint8List bytes)>[];

  /// The library refuses every file (no room, no permission).
  bool refuse = false;

  @override
  Future<List<String>> pick({
    bool photos = true,
    bool videos = true,
    bool multiple = true,
  }) async => const [];

  @override
  Future<bool> saveToAlbum(String path, String album) async {
    if (refuse) {
      throw const FileSystemException('The gallery refused the file');
    }
    saved.add((p.basename(path), album, File(path).readAsBytesSync()));
    return true;
  }
}

class Listener implements ColorBatchListener {
  final lines = <String>[];
  final percents = <double>[];

  @override
  void started(int total) {}

  @override
  void active(String file) {}

  @override
  void finished(int done, int total, FileResult result) =>
      lines.add('${result.file} ${result.status.name} ${result.error ?? ''}');

  @override
  void progress(String file, double percent) => percents.add(percent);

  @override
  void message(String line) => lines.add(line);
}

ColorEngine _defaultColor() {
  final profiles = mergedColorProfiles(
    File('assets/color.yaml').readAsStringSync(),
    null,
  );
  return ColorEngine(
    ColorProfile.fromMap(profiles['default']!.cast<String, dynamic>()),
  );
}

Directory _tmp() {
  final dir = Directory.systemTemp.createTempSync('uwmedia_mobile_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

Directory Function(String) _tempDirIn(Directory root) =>
    (prefix) => Directory(root.path).createTempSync(prefix);

void main() {
  test('a preset bit rate in bits a second', () {
    expect(presetBitrate('24M'), 24000000);
    expect(presetBitrate('7M'), 7000000);
    expect(presetBitrate('500k'), 500000);
  });

  test('the LUTs of a clip from the start, then at their frames', () {
    final blue = Float32List.fromList(List.filled(11, 0.1));
    final green = Float32List.fromList(List.filled(11, 0.5));
    final timed = timedFilters(
      [0, 50, 100, 150],
      [blue, blue, green, green],
      25,
    );
    expect([for (final t in timed) t.seconds], [0.0, 4.0]);
    expect(timed.last.filter, green);
  });

  test('a layer picture shows from its first frame on', () {
    expect(timedPictures([('a.png', 25), ('b.png', 50), ('c.png', 5)], 25), [
      (path: 'a.png', seconds: 0.0),
      (path: 'b.png', seconds: 1.0),
      (path: 'c.png', seconds: 3.0),
    ]);
  });

  test('a clip without a frame count counts its length at its rate', () {
    const clip = ClipInfo(width: 10, height: 10, durationSeconds: 4, fps: 25);
    expect(clip.totalFrames, 100);
    const noRate = ClipInfo(width: 10, height: 10, durationSeconds: 2);
    expect(noRate.frameRate, 30);
    expect(noRate.totalFrames, 60);
  });

  test('colour: the frames looked at, the LUTs, the bit rate kept', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(
        width: 1280,
        height: 720,
        durationSeconds: 10,
        frames: 250,
        fps: 25,
        bitrate: 42000000,
      ),
    );
    final percents = <double>[];
    final out = p.join(tmp.path, 'out.mp4');
    await MobileVideoRun(engine: engine, tempDir: _tempDirIn(tmp)).process(
      input: _video,
      output: out,
      color: _defaultColor(),
      onProgress: percents.add,
    );
    // Every two seconds and the last frame, at the analysis size.
    expect(engine.asked, [0.0, 2.0, 4.0, 6.0, 8.0, 249 / 25]);
    final job = engine.jobs.single;
    expect(job.luts.length, 2, reason: 'a blue half and a green half');
    expect(job.luts.first.seconds, 0);
    expect(job.luts.last.seconds, 6.0);
    // Each LUT fades in over the two seconds before its time.
    expect(job.lutFade, 2.0);
    expect(job.toMap()['lutFade'], 2.0);
    expect(job.luts.first.lut.length, lutSize * lutSize * lutSize * 3);
    expect(job.bitrate, 42000000);
    expect(job.toneMap, isFalse);
    expect(job.layers, isEmpty);
    expect(job.fit, isNull);
    expect(percents.last, 100);
    expect(percents, orderedEquals([...percents]..sort()));
  });

  test(
    'a part of the clip: its frames looked at, times from its start',
    () async {
      final tmp = _tmp();
      final engine = FakeEngine(
        const ClipInfo(
          width: 1280,
          height: 720,
          durationSeconds: 10,
          frames: 250,
          fps: 25,
        ),
      );
      final run = MobileVideoRun(engine: engine, tempDir: _tempDirIn(tmp));
      await run.process(
        input: _video,
        output: p.join(tmp.path, 'part.mp4'),
        color: _defaultColor(),
        part: (start: 3, end: 8),
      );
      // Five seconds from the third: every two seconds and its last frame.
      expect(engine.asked, [3.0, 5.0, 7.0, 3 + 124 / 25]);
      final job = engine.jobs.single;
      expect(job.part, (start: 3.0, end: 8.0));
      expect(job.toMap()['start'], 3.0);
      expect(job.toMap()['end'], 8.0);
      // The cast turns green at the clip's fifth second: the part's second.
      expect(job.luts.map((l) => l.seconds), [0.0, 2.0]);

      // The whole clip, or more than it: no part.
      expect(clipPartWithin((start: 0, end: 10), 10), isNull);
      expect(clipPartWithin((start: -1, end: 99), 10), isNull);
      expect(clipPartWithin((start: 4, end: 99), 10), (start: 4.0, end: 10.0));
      expect(clipPartWithin((start: 4, end: 4), 10), isNull);
      engine.jobs.clear();
      await run.process(
        input: _video,
        output: p.join(tmp.path, 'whole.mp4'),
        color: _defaultColor(),
        part: (start: 0, end: 10),
      );
      expect(engine.jobs.single.part, isNull);
      expect(engine.jobs.single.toMap().containsKey('start'), isFalse);
    },
  );

  test(
    'an encode started again: the progress goes back, the run hears it',
    () async {
      final tmp = _tmp();
      final engine = FakeEngine(
        const ClipInfo(width: 1280, height: 720, durationSeconds: 10, fps: 25),
      )..restartOnce = true;
      final percents = <double>[];
      var restarts = 0;
      await MobileVideoRun(engine: engine, tempDir: _tempDirIn(tmp)).process(
        input: _video,
        output: p.join(tmp.path, 'out.mp4'),
        color: _defaultColor(),
        onProgress: percents.add,
        onRestart: () => restarts++,
      );
      expect(restarts, 1);
      expect(percents.reduce((a, b) => a > b ? a : b), greaterThan(50));
      expect(
        percents.skipWhile((v) => v < 50).skip(1).first,
        lessThan(50),
        reason: 'the bar goes back: $percents',
      );
      expect(percents.last, 100);
    },
  );

  test('an output size: the crop, the fit after it, H.264', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(
        width: 3840,
        height: 2160,
        durationSeconds: 2,
        frames: 50,
        fps: 25,
        bitrate: 42000000,
      ),
    );
    final run = MobileVideoRun(engine: engine, tempDir: _tempDirIn(tmp));
    await run.process(
      input: _video,
      output: p.join(tmp.path, 'story.mp4'),
      size: const OutputSize.share(
        ShareCopy(shareInstagram, ShareShape.portraitCropped, cropAt: 0),
      ),
    );
    final story = engine.jobs.single;
    expect(story.crop, (x: 0, y: 0, width: 1214, height: 2160));
    expect(
      (story.fit, story.h264, story.bitrate),
      ((1080, 1920), true, 8000000),
    );
    // The source's own size still, for the engine's crop.
    expect((story.frameWidth, story.frameHeight), (3840, 2160));

    await run.process(
      input: _video,
      output: p.join(tmp.path, 'hd.mp4'),
      size: const OutputSize.resolution('1080p'),
    );
    final hd = engine.jobs.last;
    expect((hd.crop, hd.fit, hd.h264), (null, (1920, 1080), false));
    expect(hd.bitrate, 24000000);

    // A resolution the clip does not reach: as the clip is.
    engine.clip = const ClipInfo(
      width: 1280,
      height: 720,
      durationSeconds: 2,
      frames: 50,
      fps: 25,
      bitrate: 9000000,
    );
    await run.process(
      input: _video,
      output: p.join(tmp.path, 'same.mp4'),
      size: const OutputSize.resolution('1080p'),
    );
    expect((engine.jobs.last.fit, engine.jobs.last.bitrate), (null, 9000000));
  });

  test('a comparison: the mask and the line of the frame', () async {
    // Spec §10.94.
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(
        width: 320,
        height: 240,
        durationSeconds: 2,
        frames: 50,
        fps: 25,
        bitrate: 4000000,
      ),
    );
    final run = MobileVideoRun(engine: engine, tempDir: _tempDirIn(tmp));
    final color = ColorEngine(ColorProfile.fromMap(const {}));
    await run.process(
      input: _video,
      output: p.join(tmp.path, 'both.mp4'),
      color: color,
      compare: const Compare(CompareKind.diagonal),
    );
    final job = engine.jobs.single;
    expect(p.basename(job.compare!.mask), compareMaskFileName);
    expect(p.basename(job.compare!.line), compareLineFileName);
    expect(job.toMap()['compareMask'], job.compare!.mask);
    expect(job.toMap()['compareLine'], job.compare!.line);
    expect(job.luts, isNotEmpty);
    // Without the colour correction there is nothing to compare.
    await run.process(
      input: _video,
      output: p.join(tmp.path, 'plain.mp4'),
      compare: const Compare(CompareKind.diagonal),
    );
    expect(engine.jobs.last.compare, isNull);
    expect(engine.jobs.last.toMap().containsKey('compareMask'), isFalse);
  });

  test(
    'a wipe video through the engine: its frames, still at both ends',
    () async {
      final tmp = _tmp();
      final engine = FakeEngine(
        const ClipInfo(
          width: 2,
          height: 2,
          durationSeconds: 1,
          frames: 1,
          fps: 1,
        ),
      );
      Uint8List plain(int value) =>
          Uint8List.fromList(List.filled(64 * 48 * 4, value));
      final output = p.join(tmp.path, 'wipe.mp4');
      final size =
          await WipeRun(
            tools: FfmpegTools(
              ffmpeg: 'none',
              ffprobe: null,
              os: EngineOs.macos,
            ),
            native: engine,
          ).write(
            before: plain(10),
            after: plain(200),
            width: 64,
            height: 48,
            kind: CompareKind.vertical,
            output: output,
          );
      expect(size, (64, 48));
      expect(engine.framesOpened.single.output, output);
      expect(
        (engine.framesOpened.single.width, engine.framesOpened.single.height),
        (64, 48),
      );
      expect(engine.framesOpened.single.prores, isFalse);
      expect(engine.framesAdded.first, 16);
      expect(engine.framesAdded.last, 30);
      expect(engine.framesAdded.fold(0, (sum, n) => sum + n), 120);
      expect(engine.framesClosed, 1);
      expect(File(output).existsSync(), isTrue);
    },
  );

  test('an HDR source is tone mapped when a LUT is applied', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(
        width: 640,
        height: 360,
        durationSeconds: 2,
        fps: 25,
        hdr: true,
      ),
    );
    await MobileVideoRun(engine: engine, tempDir: _tempDirIn(tmp)).process(
      input: _video,
      output: p.join(tmp.path, 'out.mp4'),
      color: _defaultColor(),
    );
    expect(engine.jobs.single.toneMap, isTrue);
  });

  test('a conversion: the size, the bit rate, the dates', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(width: 3840, height: 2160, durationSeconds: 2, fps: 50),
    );
    final library = FakeLibrary();
    final steps = <String?>[];
    final result =
        await MobileConvertRun(
          engine: engine,
          library: library,
          tempDir: _tempDirIn(tmp),
          now: () => naive(2026, 11, 14, 9, 30),
        ).convert(
          source: _video,
          outputDir: p.join(tmp.path, 'out'),
          resolutions: ['1080p', '480p'],
          onStep: (s) => steps.add(s.target),
        );
    expect(result.failed, isEmpty);
    expect([for (final j in engine.jobs) j.fit], [(1920, 1080), (854, 480)]);
    expect([for (final j in engine.jobs) j.bitrate], [24000000, 7000000]);
    expect(
      [for (final s in library.saved) s.$2],
      ['UWMedia 2026-11-14 09.30', 'UWMedia 2026-11-14 09.30'],
    );
    expect(
      result.messages.last,
      'Saved into the album "UWMedia 2026-11-14 09.30".',
    );
    // The working copies are gone once they are in the album.
    expect(Directory(p.join(tmp.path, 'out')).listSync(), isEmpty);
  });

  test('a conversion saved into a folder of the phone\'s files instead of '
      'an album', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(width: 3840, height: 2160, durationSeconds: 2, fps: 50),
    );
    final library = FakeLibrary();
    final folders = FakeFolders();
    Future<({List<String> failed, List<String> messages})> convert(
      String out,
    ) =>
        MobileConvertRun(
          engine: engine,
          library: library,
          tempDir: _tempDirIn(tmp),
          saveTo: FolderPlace(folders, (name: 'Dives', bookmark: 'Ym9v')),
        ).convert(
          source: _video,
          outputDir: p.join(tmp.path, out),
          resolutions: ['1080p', '480p'],
        );

    final result = await convert('out');
    expect(result.failed, isEmpty);
    expect(library.saved, isEmpty);
    expect(folders.saved, hasLength(2));
    expect(folders.saved.every((s) => s.$2 == 'Ym9v'), isTrue);
    expect(result.messages.last, 'Saved into the folder "Dives".');
    expect(Directory(p.join(tmp.path, 'out')).listSync(), isEmpty);

    // A folder that is gone: each size fails with the reason, nothing is
    // said to be saved, and nothing goes into an album instead.
    folders.refuse = true;
    final refused = await convert('out2');
    expect(refused.failed, ['1080p', '480p']);
    expect(
      refused.messages,
      contains('Error converting to 1080p: The folder is no longer there.'),
    );
    expect(refused.messages, isNot(contains('Saved into the folder "Dives".')));
    expect(library.saved, isEmpty);
    expect(Directory(p.join(tmp.path, 'out2')).listSync(), isEmpty);
  });

  test('copies for sharing: the crop, the size, H.264', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(width: 3840, height: 2160, durationSeconds: 2, fps: 50),
    );
    final library = FakeLibrary();
    final result =
        await MobileConvertRun(
          engine: engine,
          library: library,
          tempDir: _tempDirIn(tmp),
        ).convert(
          source: _video,
          outputDir: p.join(tmp.path, 'out'),
          resolutions: ['480p'],
          shares: const [
            ShareCopy(shareWhatsApp, ShareShape.asShot),
            ShareCopy(shareInstagram, ShareShape.portraitCropped, cropAt: 0),
          ],
        );
    expect(result.failed, isEmpty, reason: result.messages.join('\n'));
    final [plain, whatsApp, story] = engine.jobs;
    expect((plain.h264, plain.crop, plain.fit), (false, null, (854, 480)));
    expect((whatsApp.h264, whatsApp.crop), (true, null));
    expect((whatsApp.fit, whatsApp.bitrate), ((1280, 720), 3000000));
    expect(story.crop, (x: 0, y: 0, width: 1214, height: 2160));
    expect((story.fit, story.bitrate), ((1080, 1920), 8000000));
    // What the phone's engine is handed.
    final map = story.toMap();
    expect(map['codec'], 'h264');
    expect(map['crop'], {'x': 0, 'y': 0, 'width': 1214, 'height': 2160});
    expect((map['width'], map['height']), (1080, 1920));
    expect(plain.toMap().containsKey('codec'), isFalse);
    expect(library.saved, hasLength(3));
  });

  test('a file the album refuses is a failure, and no copy is left', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(width: 1920, height: 1080, durationSeconds: 2, fps: 25),
    );
    final out = p.join(tmp.path, 'out');
    final result = await MobileConvertRun(
      engine: engine,
      library: FakeLibrary()..refuse = true,
      tempDir: _tempDirIn(tmp),
    ).convert(source: _video, outputDir: out, resolutions: ['720p']);
    expect(result.failed, ['720p']);
    expect(Directory(out).listSync(), isEmpty);

    final source = Directory(p.join(tmp.path, 'picked'))..createSync();
    File(_video).copySync(p.join(source.path, 'C0001.mp4'));
    final listener = Listener();
    final results =
        await MobileColorBatch(
          engine: engine,
          library: FakeLibrary()..refuse = true,
          renderer: HudRenderer(await _fonts(), HudRules(const {})),
          painter: HudPainter(await _fonts()),
          tempDir: _tempDirIn(tmp),
        ).run(
          ColorBatchSettings(
            source: source.path,
            output: p.join(tmp.path, 'color_out'),
            colorProfile: _defaultColor().profile,
          ),
          listener,
        );
    expect([for (final r in results) r.status], [FileStatus.error]);
    expect(Directory(p.join(tmp.path, 'color_out')).listSync(), isEmpty);
  });

  test('Stop during the encode ends the run, and nothing is left', () async {
    final tmp = _tmp();
    final engine = FakeEngine(
      const ClipInfo(width: 640, height: 360, durationSeconds: 2, fps: 25),
    )..hold = Completer<void>();
    final control = RunControl();
    final out = p.join(tmp.path, 'out.mp4');
    final run = MobileVideoRun(engine: engine, tempDir: _tempDirIn(tmp))
        .process(
          input: _video,
          output: out,
          color: _defaultColor(),
          control: control,
        );
    while (engine.jobs.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final ended = expectLater(run, throwsA(isA<RunStopped>()));
    await control.stop();
    await ended;
    expect(engine.cancelled, isTrue);
    expect(File(out).existsSync(), isFalse);
  });

  test('the source video dates are written to the output', () {
    final tmp = _tmp();
    final target = p.join(tmp.path, 'out.mp4');
    writeMp4Dates(_video, {
      'QuickTime:CreateDate': '2000:01:01 00:00:00',
      'QuickTime:CreationDate': '2000:01:01 08:00:00+08:00',
    }, output: target);
    expect(
      readFileDates(target)['QuickTime:CreateDate'],
      '2000:01:01 00:00:00',
    );

    expect(copyVideoDates(_video, target), isEmpty);
    final source = readFileDates(_video);
    final written = readFileDates(target);
    expect(written['QuickTime:CreateDate'], '2025:10:19 02:21:31');
    expect(written['QuickTime:CreationDate'], source['QuickTime:CreationDate']);
  });

  test('a Sony clip\'s timezone becomes the output\'s local time', () {
    final tmp = _tmp();
    final source = p.join(tmp.path, 'sony.mp4');
    // 2025-10-19 02:21:31 UTC, in seconds from 1904.
    File(source).writeAsBytesSync(
      sonyMp4(created: 1760840491 + 2082844800, zoneMinutes: 480),
    );
    final target = p.join(tmp.path, 'out.mp4');
    File(_video).copySync(target);
    writeMp4Dates(target, {'QuickTime:CreationDate': '2000:01:01 00:00:00'});

    // Nothing is said about the timezone tag, which is not written.
    expect(copyVideoDates(source, target), isEmpty);
    final written = readFileDates(target);
    expect(written['QuickTime:CreateDate'], '2025:10:19 02:21:31');
    expect(written['QuickTime:CreationDate'], '2025:10:19 10:21:31+08:00');
  });

  testWidgets('overlays: a picture per change, placed, for the dive', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fonts = await _fonts();
      final renderer = HudRenderer(
        fonts,
        HudRules(
          jsonDecode(File('assets/hud_rules.json').readAsStringSync())
              as Map<String, dynamic>,
        ),
      );
      final tmp = _tmp();
      final engine = FakeEngine(
        const ClipInfo(width: 1280, height: 720, durationSeconds: 5, fps: 1),
      );
      final dive = buildDummyDive();
      final layer = HudLayerSource(
        loadLayoutFile(
          '$_template/normal.json',
          (path) => File(path).readAsStringSync(),
        ),
        skinBytes: File('$_template/normal.png').readAsBytesSync(),
        placement: (x: 0.05, y: 0.6, scale: 0.5),
      );
      await MobileVideoRun(
        engine: engine,
        tempDir: _tempDirIn(tmp),
        renderer: renderer,
        painter: HudPainter(fonts),
      ).process(
        input: _video,
        output: p.join(tmp.path, 'out.mp4'),
        layers: [layer],
        dive: dive,
        matchDate: dive.startTime.add(const Duration(minutes: 10)),
      );
      final job = engine.jobs.single;
      expect(job.luts, isEmpty);
      expect(job.frameWidth, 1280);
      expect(job.frameHeight, 720);
      final drawn = job.layers.single;
      expect(drawn.pictures, isNotEmpty);
      expect(drawn.pictures.first.seconds, 0);
      expect(drawn.pictures.length, lessThanOrEqualTo(5));
      // Placed on the lower left part of the frame, as the user put it.
      expect(drawn.x, lessThan(1280 ~/ 4));
      expect(drawn.y, greaterThan(720 ~/ 3));
      expect(engine.picturesSeen.single, isTrue);
      // The working folder of the pictures is gone.
      expect(
        tmp.listSync().whereType<Directory>().where(
          (d) => p.basename(d.path).startsWith('uwmedia_overlay_'),
        ),
        isEmpty,
      );
    });
  });

  testWidgets('the Color batch on a phone: into the album, dates kept', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fonts = await _fonts();
      final tmp = _tmp();
      final source = Directory(p.join(tmp.path, 'picked'))..createSync();
      File(_photo).copySync(p.join(source.path, 'DSC01.jpg'));
      File(_video).copySync(p.join(source.path, 'C0001.mp4'));
      final engine = FakeEngine(
        const ClipInfo(width: 1280, height: 720, durationSeconds: 2, fps: 25),
      );
      final library = FakeLibrary();
      final listener = Listener();
      final profiles = mergedColorProfiles(
        File('assets/color.yaml').readAsStringSync(),
        null,
      );
      final results =
          await MobileColorBatch(
            engine: engine,
            library: library,
            renderer: HudRenderer(
              fonts,
              HudRules(
                jsonDecode(File('assets/hud_rules.json').readAsStringSync())
                    as Map<String, dynamic>,
              ),
            ),
            painter: HudPainter(fonts),
            tempDir: _tempDirIn(tmp),
            now: () => naive(2026, 11, 14, 9, 30),
          ).run(
            ColorBatchSettings(
              source: source.path,
              output: p.join(tmp.path, 'out'),
              colorProfileName: 'default',
              colorProfile: ColorProfile.fromMap(
                profiles['default']!.cast<String, dynamic>(),
              ),
            ),
            listener,
          );
      expect(
        [for (final r in results) r.status],
        [FileStatus.done, FileStatus.done],
        reason: listener.lines.join('\n'),
      );
      expect([for (final s in library.saved) s.$1], ['C0001.mp4', 'DSC01.jpg']);
      expect(
        library.saved.every((s) => s.$2 == 'UWMedia 2026-11-14 09.30'),
        isTrue,
      );
      expect(engine.jobs.single.luts, isNotEmpty);
      // The corrected photo keeps the source's dates and offsets.
      final photo = library.saved.last.$3;
      final dir = Directory(p.join(tmp.path, 'check'))..createSync();
      final copy = File(p.join(dir.path, 'x.jpg'))..writeAsBytesSync(photo);
      final dates = readFileDates(copy.path);
      expect(dates['EXIF:DateTimeOriginal'], '2025:12:03 09:15:48');
      expect(dates['EXIF:OffsetTimeOriginal'], '+08:00');
      expect(photo, isNot(File(_photo).readAsBytesSync()));
      expect(
        listener.lines.last,
        'Saved into the album "UWMedia 2026-11-14 09.30".',
      );
      expect(Directory(p.join(tmp.path, 'out')).listSync(), isEmpty);
    });
  });
  testWidgets("Color Tuning's sample: a video's middle frame as a PNG", (
    tester,
  ) async {
    await tester.runAsync(() async {
      final tmp = _tmp();
      final engine = FakeEngine(
        const ClipInfo(width: 1280, height: 720, durationSeconds: 8, fps: 25),
      );
      final fromVideo = await pickSampleFromLibrary(
        _tempDirIn(tmp),
        engine: engine,
        pickMedia: () async => _video,
      )('');
      expect(engine.asked, [4.0]);
      expect(p.basename(fromVideo!), 'h264_10bit_422_720p_2s.png');
      final codec = await ui.instantiateImageCodec(
        File(fromVideo).readAsBytesSync(),
      );
      final image = (await codec.getNextFrame()).image;
      expect((image.width, image.height), (1920, 1920));
      image.dispose();

      // A photo is taken as it is.
      final fromPhoto = await pickSampleFromLibrary(
        _tempDirIn(tmp),
        engine: engine,
        pickMedia: () async => _photo,
      )('');
      expect(fromPhoto, _photo);
      expect(engine.asked, [4.0]);
    });
  });
}

Future<TtfFonts> _fonts() async {
  for (final family in fontRegistry.values) {
    for (final file in family.values) {
      final loader = FontLoader(fontFamilyOf(file))
        ..addFont(
          Future.value(
            ByteData.sublistView(File('assets/fonts/$file').readAsBytesSync()),
          ),
        );
      await loader.load();
    }
  }
  return TtfFonts(
    (file) => File('assets/fonts/$file').readAsBytesSync(),
    inkTables: InkTables.parse(
      File('assets/fonts/ink_tables.bin').readAsBytesSync(),
    ),
  );
}
