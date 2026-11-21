// The engine part of the platform check, the one that differs per
// platform: the pack's clip through the platform's real media engine. On
// the desktop the app's ffmpeg runs (the Color page's colour correction
// with an overlay, OverlayRun; the Convertion page's resize,
// FfmpegTools.processVideo), on a phone the phone engine (MobileVideoRun).
// Each output is probed and a few of its frames measured.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/app_paths.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/color_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_run.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/telemetry_run.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';

import 'checks.dart';

/// How long a probe or the clip's encode may take before it is stopped.
const _toolTimeout = Duration(minutes: 2);

/// How long making the 2 s clip may take.
const _generateTimeout = Duration(minutes: 10);

/// The mean of each channel of [image], over the whole frame and over each
/// cell of a [grid] x [grid] split (cell (gx, gy) covers the columns
/// gx * w ~/ grid to (gx + 1) * w ~/ grid, rows alike; row by row).
Map<String, Object?> frameStats(RgbImage image, int grid) {
  final w = image.width;
  final h = image.height;
  final cells = <List<double>>[];
  for (var gy = 0; gy < grid; gy++) {
    for (var gx = 0; gx < grid; gx++) {
      final x0 = gx * w ~/ grid;
      final x1 = (gx + 1) * w ~/ grid;
      final y0 = gy * h ~/ grid;
      final y1 = (gy + 1) * h ~/ grid;
      final sums = [0, 0, 0];
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = 3 * (y * w + x);
          sums[0] += image.rgb[i];
          sums[1] += image.rgb[i + 1];
          sums[2] += image.rgb[i + 2];
        }
      }
      final n = (x1 - x0) * (y1 - y0);
      cells.add([for (final s in sums) n == 0 ? 0.0 : s / n]);
    }
  }
  return {
    'size': [w, h],
    'mean': channelMeans(image.rgb),
    'grid': cells,
  };
}

/// The overlay layer of a run's overlay entry, from the app's assets, as
/// `overlayLayerSource` makes it from a file on the desktop.
Future<HudLayerSource> _overlayLayer(
  Map<String, dynamic> overlay,
  Map<String, String> texts, {
  bool placed = true,
}) async {
  final path =
      '$bundledTemplatesRoot/'
      '${(overlay['template'] as List<dynamic>).join('/')}/normal.json';
  final layout = loadLayoutFile(
    path,
    (file) =>
        texts[p.posix.normalize(file)] ??
        (throw StateError('no template file $file')),
  );
  final skin = layout['hud_skin'];
  final skinPath = skin is Map ? skin['path'] : null;
  Uint8List? bytes;
  if (skinPath is String && skinPath.isNotEmpty) {
    bytes = await templateFileBytes(
      p.posix.normalize(p.posix.join(p.posix.dirname(path), skinPath)),
    );
  }
  return HudLayerSource(
    layout,
    skinBytes: bytes,
    placement: !placed
        ? null
        : (
            x: (overlay['x'] as num).toDouble(),
            y: (overlay['y'] as num).toDouble(),
            scale: (overlay['scale'] as num).toDouble(),
          ),
  );
}

/// What one implementation of the engine does with a file: probe it and
/// take a frame out of it.
abstract interface class _Probe {
  Future<Map<String, Object?>> probe(String path);
  Future<RgbImage?> frame(String path, double seconds, int width, int height);
}

/// ffprobe and ffmpeg, with the commands REPORT_FORMAT.md gives.
class _DesktopProbe implements _Probe {
  _DesktopProbe(this.tools);

  final FfmpegTools tools;

  @override
  Future<Map<String, Object?>> probe(String path) async {
    final result = await runCapture(tools.ffprobe!, timeout: _toolTimeout, [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-count_frames',
      '-show_entries',
      'stream=codec_name,width,height,nb_read_frames:format=duration',
      '-of',
      'json',
      path,
    ]);
    if (result == null || result.exitCode != 0) {
      throw CheckFailure('ffprobe could not read ${p.basename(path)}');
    }
    final json = jsonDecode(result.stdout) as Map<String, dynamic>;
    final stream =
        (json['streams'] as List<dynamic>).first as Map<String, dynamic>;
    final format = json['format'] as Map<String, dynamic>;
    return {
      'codec': stream['codec_name'],
      'width': stream['width'],
      'height': stream['height'],
      'frames': int.tryParse('${stream['nb_read_frames']}'),
      'duration_s': double.tryParse('${format['duration']}'),
    };
  }

  @override
  Future<RgbImage?> frame(String path, double seconds, int width, int height) =>
      tools.frameAt(path, seconds, width: width, height: height);
}

/// The phone engine's own probe and frame grab.
class _MobileProbe implements _Probe {
  _MobileProbe(this.engine);

  final MobileMediaEngine engine;

  @override
  Future<Map<String, Object?>> probe(String path) async {
    final clip = await engine.probe(path);
    final mime = clip.mime ?? '';
    return {
      'codec': switch (mime) {
        'video/hevc' => 'hevc',
        'video/avc' => 'h264',
        _ => mime.isEmpty ? null : mime,
      },
      'width': clip.width,
      'height': clip.height,
      'frames': clip.frames,
      'duration_s': clip.durationSeconds,
    };
  }

  @override
  Future<RgbImage?> frame(String path, double seconds, int width, int height) =>
      engine.frameAt(
        path,
        seconds,
        maxWidth: width,
        maxHeight: height,
        exact: true,
      );
}

/// The output's probe and its frames at the pack's times.
Future<Map<String, Object?>> _measure(
  _Probe probe,
  String path,
  Map<String, dynamic> section,
) async {
  final info = await probe.probe(path);
  final width = info['width'] as int? ?? 0;
  final height = info['height'] as int? ?? 0;
  final grid = section['grid'] as int;
  final frames = <Map<String, Object?>>[];
  for (final t in section['frame_times_s'] as List<dynamic>) {
    final seconds = (t as num).toDouble();
    final image = await probe.frame(path, seconds, width, height);
    frames.add({
      't': t,
      if (image == null) 'missing': true else ...frameStats(image, grid),
    });
  }
  return {...info, 'bytes': File(path).lengthSync(), 'frames_at': frames};
}

void _expectSize(
  Map<String, Object?> result,
  int width,
  int height,
  String id,
) {
  if (result['width'] != width || result['height'] != height) {
    throw CheckFailure(
      '$id is ${result['width']}x${result['height']}, expected '
      '${width}x$height',
      result,
    );
  }
  final frames = result['frames_at']! as List<Map<String, Object?>>;
  if (frames.any((f) => f['missing'] == true)) {
    throw CheckFailure('a frame of $id could not be read', result);
  }
}

/// Facts about the engine for the report's header; filled by
/// [runEngineChecks].
typedef EngineInfo = Map<String, Object?>;

/// The middle of [values] (the mean of the two middle ones for an even
/// count).
double median(List<int> values) {
  final sorted = [...values]..sort();
  final n = sorted.length;
  if (n == 0) {
    return 0;
  }
  return n.isOdd
      ? sorted[n ~/ 2].toDouble()
      : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

/// One engine run of the pack done: where its output is, what wrote it,
/// and the run's own counts.
/// Which engine a Mac's checks run on: 'native' for the runner's media
/// engine, anything else for ffmpeg.
const _engineDefine = String.fromEnvironment('ENGINE');

typedef _Done = ({String output, String encoder, Map<String, Object?> stats});

/// The checks of the pack's `engine` section, through the desktop's ffmpeg
/// or the phone's engine. [clip] is the pack's clip; [work] a folder to
/// write in; [texts] the templates' JSON files by asset path, [colorYaml]
/// the bundled colour profiles; [perfRepeats] the times each perf run is
/// done (0: the pack's `perf.repeats`); [perfClipPath] the pack's perf clip
/// on this machine, `null` to skip the perf checks for [perfSkipReason].
Future<void> runEngineChecks(
  CheckRecorder recorder,
  Map<String, dynamic> pack,
  HudKit kit,
  Uint8List clip,
  Directory work,
  EngineInfo info, {
  required Map<String, String> texts,
  required String colorYaml,
  int perfRepeats = 0,
  String? perfClipPath,
  String perfSkipReason = 'no perf clip was given',
}) async {
  final section = pack['engine'] as Map<String, dynamic>;
  final clipSpec = section['clip'] as Map<String, dynamic>;
  final runs = [
    for (final r in section['runs'] as List<dynamic>) r as Map<String, dynamic>,
  ];
  final perf = section['perf'] as Map<String, dynamic>;
  final perfClip = perf['clip'] as Map<String, dynamic>;
  final perfRuns = [
    for (final id in perf['runs'] as List<dynamic>)
      runs.firstWhere((r) => r['id'] == id),
  ];
  final repeats = math.max(
    1,
    perfRepeats > 0 ? perfRepeats : perf['repeats'] as int,
  );
  final input = p.join(work.path, clipSpec['file'] as String);
  File(input).writeAsBytesSync(clip, flush: true);
  // A Mac has the phones' engine too (docs/design/macos-remove-ffmpeg.md): with
  // --dart-define=ENGINE=native the checks and the timed runs are its, as
  // on an iPhone, and not ffmpeg's.
  final mobile =
      Platform.isAndroid ||
      Platform.isIOS ||
      (Platform.isMacOS && _engineDefine == 'native');
  final profiles = mergedColorProfiles(colorYaml, null);
  final dive = buildDummyDive(
    variant: (section['dive'] as Map<String, dynamic>)['variant'] as String?,
    ccr: (section['dive'] as Map<String, dynamic>)['ccr'] == true,
    // Python's sample dive, without the port's SAC (spec §10.54).
    sac: false,
  );
  final creationDate = parseNaive(section['creation_date'] as String);
  final matchDate = parseNaive(section['match_date'] as String);

  ColorEngine colorOf(Map<String, dynamic> run) {
    final values = profiles[run['profile']];
    if (values == null) {
      throw CheckFailure('no profile "${run['profile']}" in color.yaml');
    }
    return ColorEngine(ColorProfile.fromMap(values));
  }

  Future<List<HudLayerSource>> overlaysOf(Map<String, dynamic> run) async => [
    for (final o in run['overlays'] as List<dynamic>? ?? const [])
      await _overlayLayer(o as Map<String, dynamic>, texts),
  ];

  void skipPerf(String reason) {
    recorder.skip('engine', 'engine/perf/clip', reason);
    for (final run in perfRuns) {
      recorder.skip('engine', 'engine/perf/${run['id']}', reason);
    }
  }

  if (mobile) {
    final engineName = Platform.isAndroid
        ? 'Media3 Transformer'
        : 'AVFoundation';
    info['kind'] = 'mobile';
    info['engine'] = engineName;
    const engine = PlatformMediaEngine();
    final probe = _MobileProbe(engine);
    recorder.skip(
      'engine',
      'engine/ffmpeg_generate',
      'a phone has no ffmpeg; the clip is the bundled one',
    );
    await _measureSource(recorder, probe, input, section);
    final videoRun = MobileVideoRun(
      engine: engine,
      tempDir: appTempDir,
      renderer: kit.renderer,
      painter: kit.painter,
    );
    for (final run in runs) {
      final id = 'engine/${run['id']}';
      if (run['desktop_only'] == true) {
        recorder.skip('engine', id, _notHere);
        continue;
      }
      final output = p.join(work.path, '${_stem(run)}.mp4');
      await recorder.run('engine', id, () async {
        final color = colorOf(run);
        final layers = await overlaysOf(run);
        final watch = Stopwatch()..start();
        final lines = await videoRun.process(
          input: input,
          output: output,
          color: color,
          layers: layers,
          dive: dive,
          matchDate: matchDate,
        );
        final ms = watch.elapsedMilliseconds;
        final result = {
          ...await _measure(probe, output, section),
          'run_ms': ms,
          'encoder': engineName,
          'hw_accel': true,
          'messages': lines,
        };
        _expectSize(
          result,
          clipSpec['width'] as int,
          clipSpec['height'] as int,
          id,
        );
        return result;
      });
    }
    await _perfChecks(
      recorder: recorder,
      perf: perf,
      perfRuns: perfRuns,
      clipPath: perfClipPath,
      skipReason: perfSkipReason,
      repeats: repeats,
      work: work,
      mobile: true,
      inputFacts: (path) async => {
        ...await probe.probe(path),
        'fps': (await engine.probe(path)).fps,
        'bytes': File(path).lengthSync(),
      },
      outputFacts: (run, output) => probe.probe(output),
      doRun: (run, source, stem, watch) async {
        final output = '$stem.mp4';
        final color = colorOf(run);
        final layers = await overlaysOf(run);
        watch.start();
        await videoRun.process(
          input: source,
          output: output,
          color: color,
          layers: layers,
          dive: dive,
          matchDate: matchDate,
        );
        watch.stop();
        return (
          output: output,
          encoder: engineName,
          stats: const <String, Object?>{},
        );
      },
    );
    return;
  }

  // The desktop.
  info['kind'] = 'desktop';
  final found = await ToolFinder.forThisMachine().findAll(const {});
  final ffmpeg = found[toolFfmpeg];
  final ffprobe = found[toolFfprobe];
  if (ffmpeg == null || ffprobe == null) {
    const reason = 'ffmpeg or ffprobe was not found (bundled, PATH, system)';
    info['engine'] = null;
    recorder
      ..skip('engine', 'engine/ffmpeg_generate', reason)
      ..skip('engine', 'engine/source_clip', reason);
    for (final run in runs) {
      recorder.skip('engine', 'engine/${run['id']}', reason);
    }
    skipPerf(reason);
    return;
  }
  final tools = FfmpegTools(
    ffmpeg: ffmpeg,
    ffprobe: ffprobe,
    os: currentEngineOs(),
  );
  info['engine'] = 'ffmpeg';
  info['ffmpeg'] = _homeless(ffmpeg);
  try {
    info['ffmpeg_version'] = await tools.version();
    info['encoder'] = await tools.encoder(hwAccel: true);
  } on Object catch (e) {
    info['ffmpeg_version'] ??= 'unknown: $e';
  }
  final probe = _DesktopProbe(tools);

  // One run of [run] on [source] into a name made from [stem]; only the
  // run itself is inside [watch].
  Future<_Done> desktopRun(
    Map<String, dynamic> run,
    String source,
    String stem,
    Stopwatch watch,
  ) async {
    final hwAccel = run['hw_accel'] != false;
    switch (run['kind']) {
      case 'color':
        final output = '$stem.mp4';
        final color = ColorRun(
          tools: tools,
          engine: colorOf(run),
          tempDir: appTempDir,
          hwAccel: hwAccel,
        );
        watch.start();
        final s = await color.processVideoLut(
          input: source,
          output: output,
          creationDate: creationDate,
        );
        watch.stop();
        return (
          output: output,
          encoder: await tools.encoder(hwAccel: hwAccel),
          stats: <String, Object?>{
            'source_frames': s.totalFrames,
            'samples': s.samples,
            'luts': s.luts,
          },
        );
      case 'color_overlay':
        final output = '$stem.mp4';
        final layers = await overlaysOf(run);
        final overlayRun = OverlayRun(
          color: ColorRun(
            tools: tools,
            engine: colorOf(run),
            tempDir: appTempDir,
            hwAccel: hwAccel,
          ),
          renderer: kit.renderer,
          painter: kit.painter,
        );
        watch.start();
        final s = await overlayRun.processVideo(
          input: source,
          output: output,
          creationDate: creationDate,
          layers: layers,
          dive: dive,
          matchDate: matchDate,
        );
        watch.stop();
        return (
          output: output,
          encoder: await tools.encoder(hwAccel: hwAccel),
          stats: <String, Object?>{
            'source_frames': s.totalFrames,
            'samples': s.samples,
            'layers': s.layers,
          },
        );
      case 'overlay':
        final format = run['format'] as String;
        final output = outputPathFor(format, '$stem.mp4');
        final layer = await _overlayLayer(
          run['overlay'] as Map<String, dynamic>,
          texts,
          placed: false,
        );
        // The Overlay Generator probes the clip before it renders.
        final fps = await tools.fps(source);
        final frames = await tools.frameCount(source);
        final telemetry = TelemetryRun(
          tools: tools,
          renderer: kit.renderer,
          painter: kit.painter,
          hwAccel: hwAccel,
        );
        watch.start();
        final s = await telemetry.render(
          source: layer,
          dive: dive,
          start: matchDate,
          fps: fps,
          totalFrames: frames,
          format: format,
          target: output,
          size: run['size'] as String?,
          fullFrame: run['full_frame'] == true,
        );
        watch.stop();
        return (
          output: output,
          encoder: switch (format) {
            overlayFormatProres => 'prores_ks',
            overlayFormatPng => 'png',
            _ => await tools.encoder(hwAccel: hwAccel),
          },
          stats: <String, Object?>{'pictures': s.pictures},
        );
    }
    throw CheckFailure('unknown run kind ${run['kind']}');
  }

  Future<Map<String, Object?>> measureOutput(
    Map<String, dynamic> run,
    String output,
    double fps,
  ) => run['kind'] == 'overlay' && run['format'] == overlayFormatPng
      ? _measurePngSequence(tools, output, fps, section)
      : _measure(probe, output, section);

  await recorder.run('engine', 'engine/ffmpeg_generate', () async {
    final out = p.join(work.path, 'generated.mp4');
    final watch = Stopwatch()..start();
    await _generate(ffmpeg, clipSpec, out);
    final ms = watch.elapsedMilliseconds;
    final hash = sha256Hex(File(out).readAsBytesSync());
    final result = {
      'sha256': hash,
      'same_as_pack_clip': hash == clipSpec['sha256'],
      'run_ms': ms,
      'encoder': 'libx264',
      ...await probe.probe(out),
    };
    _expectClip(result, clipSpec, 'the clip made here');
    return result;
  });

  await _measureSource(recorder, probe, input, section);
  final clipFps = (clipSpec['fps'] as num).toDouble();
  for (final run in runs) {
    final id = 'engine/${run['id']}';
    await recorder.run('engine', id, () async {
      final watch = Stopwatch();
      final done = await desktopRun(
        run,
        input,
        p.join(work.path, _stem(run)),
        watch,
      );
      final result = {
        ...await measureOutput(run, done.output, clipFps),
        'run_ms': watch.elapsedMilliseconds,
        'encoder': done.encoder,
        'hw_accel': run['hw_accel'] != false,
        ...done.stats,
      };
      if (run['kind'] == 'overlay') {
        _expectFrames(result, clipSpec['frames'] as int, id);
      } else {
        _expectSize(
          result,
          clipSpec['width'] as int,
          clipSpec['height'] as int,
          id,
        );
      }
      return result;
    });
  }

  final perfFps = (perfClip['fps'] as num).toDouble();
  await _perfChecks(
    recorder: recorder,
    perf: perf,
    perfRuns: perfRuns,
    clipPath: perfClipPath,
    skipReason: perfSkipReason,
    repeats: repeats,
    work: work,
    mobile: false,
    inputFacts: (path) async => {
      ...await probe.probe(path),
      'fps': await tools.fps(path),
      'bytes': File(path).lengthSync(),
    },
    outputFacts: (run, output) =>
        run['kind'] == 'overlay' && run['format'] == overlayFormatPng
        ? _pngSequenceFacts(tools, output, perfFps)
        : probe.probe(output),
    doRun: desktopRun,
  );
}

const _desktopOnly = 'the Overlay Generator is a desktop page (spec §0)';

// A Mac checked on its engine (ENGINE=native): the page is there, but its
// render is ffmpeg's (spec §10.70), timed by the check without the define.
const _macOverlay =
    'the Overlay Generator renders with ffmpeg on a Mac too (spec §10.70): '
    'checked and timed by the run without ENGINE=native';

String get _notHere => Platform.isMacOS ? _macOverlay : _desktopOnly;

/// The perf checks: `engine/perf/clip` (the pack's perf clip at
/// [clipPath], its SHA-256 checked and its facts read), then each of
/// [perfRuns] done [repeats] times on it by [doRun], only the run inside
/// its stopwatch. On a phone the desktop-only runs are skipped.
Future<void> _perfChecks({
  required CheckRecorder recorder,
  required Map<String, dynamic> perf,
  required List<Map<String, dynamic>> perfRuns,
  required String? clipPath,
  required String skipReason,
  required int repeats,
  required Directory work,
  required bool mobile,
  required Future<Map<String, Object?>> Function(String path) inputFacts,
  required Future<Map<String, Object?>> Function(
    Map<String, dynamic> run,
    String output,
  )
  outputFacts,
  required Future<_Done> Function(
    Map<String, dynamic> run,
    String input,
    String stem,
    Stopwatch watch,
  )
  doRun,
}) async {
  final spec = perf['clip'] as Map<String, dynamic>;
  void skipRuns(String reason) {
    for (final run in perfRuns) {
      recorder.skip('engine', 'engine/perf/${run['id']}', reason);
    }
  }

  if (clipPath == null) {
    recorder.skip('engine', 'engine/perf/clip', skipReason);
    skipRuns(skipReason);
    return;
  }
  Map<String, Object?>? facts;
  await recorder.run('engine', 'engine/perf/clip', () async {
    final hash = sha256Hex(File(clipPath).readAsBytesSync());
    final result = {...await inputFacts(clipPath), 'sha256': hash};
    if (hash != spec['sha256']) {
      throw CheckFailure(
        'the perf clip is not the pack\'s (SHA-256 ${hash.substring(0, 12)})',
        result,
      );
    }
    facts = result;
    return result;
  });
  final input = facts;
  if (input == null) {
    skipRuns('the perf clip could not be used (engine/perf/clip)');
    return;
  }
  final fps = (spec['fps'] as num).toDouble();
  for (final run in perfRuns) {
    final id = 'engine/perf/${run['id']}';
    if (mobile && run['desktop_only'] == true) {
      recorder.skip('engine', id, _notHere);
      continue;
    }
    final stem = p.join(work.path, 'perf_${_stem(run)}');
    await recorder.run('engine', id, () async {
      final times = <int>[];
      late _Done done;
      try {
        for (var i = 0; i < repeats; i++) {
          _removeOutputs(stem);
          final watch = Stopwatch();
          done = await doRun(run, clipPath, stem, watch);
          times.add(watch.elapsedMilliseconds);
        }
        final out = await outputFacts(run, done.output);
        final result = <String, Object?>{
          'input': input,
          'output': {...out, 'bytes': _bytesOf(done.output)},
          'encoder': done.encoder,
          'hw_accel': run['hw_accel'] != false,
          'repeats': repeats,
          'run_ms': times,
          'run_ms_median': median(times),
          ...done.stats,
        };
        final frames = out['frames'];
        final seconds = out['duration_s'] as num? ?? 0;
        if ((frames != null && frames != spec['frames']) ||
            (seconds - (spec['frames'] as int) / fps).abs() > 0.1 ||
            (run['kind'] != 'overlay' &&
                (out['width'] != spec['width'] ||
                    out['height'] != spec['height']))) {
          throw CheckFailure('$id: not the output expected', result);
        }
        return result;
      } finally {
        _removeOutputs(stem);
      }
    });
  }
}

/// A file name for a run's output (`overlay/prores` → `overlay_prores`).
String _stem(Map<String, dynamic> run) =>
    (run['id'] as String).replaceAll('/', '_');

/// Runs ffmpeg with a clip's `ffmpeg_args` into [out]; throws when it
/// fails.
Future<void> _generate(
  String ffmpeg,
  Map<String, dynamic> spec,
  String out,
) async {
  final args = [
    for (final a in spec['ffmpeg_args'] as List<dynamic>)
      a == '{output}' ? out : '$a',
  ];
  final run = await runCapture(ffmpeg, args, timeout: _generateTimeout);
  if (run == null || run.exitCode != 0) {
    throw CheckFailure('ffmpeg failed: ${run?.stderr ?? 'not started'}');
  }
}

void _expectClip(
  Map<String, Object?> result,
  Map<String, dynamic> spec,
  String what,
) {
  if (result['width'] != spec['width'] ||
      result['height'] != spec['height'] ||
      result['frames'] != spec['frames']) {
    throw CheckFailure('$what is not the pack\'s', result);
  }
}

void _expectFrames(Map<String, Object?> result, int frames, String id) {
  final frameList = result['frames_at']! as List<Map<String, Object?>>;
  if (result['frames'] != frames ||
      (result['width'] as int? ?? 0) <= 0 ||
      frameList.any((f) => f['missing'] == true)) {
    throw CheckFailure(
      '$id: ${result['frames']} frames of ${result['width']}x'
      '${result['height']}, expected $frames readable frames',
      result,
    );
  }
}

/// The bytes of a file, or of all the files of a folder (a PNG sequence).
int _bytesOf(String path) {
  if (FileSystemEntity.isDirectorySync(path)) {
    return Directory(path)
        .listSync()
        .whereType<File>()
        .fold(0, (sum, f) => sum + f.lengthSync());
  }
  return File(path).lengthSync();
}

/// Removes what a run wrote under [stem] (a file or a PNG folder).
void _removeOutputs(String stem) {
  for (final path in [stem, '$stem.mp4', '$stem.mov']) {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else if (type == FileSystemEntityType.file) {
        File(path).deleteSync();
      }
    } on FileSystemException {
      // Not there.
    }
  }
}

/// The frames of a PNG sequence ([frameFileName], from 1) in order.
List<File> _pngFrames(String folder) =>
    Directory(folder)
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('frame_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// What a PNG sequence is, as a probe gives a video: the codec, the first
/// frame's size, the frame count and its length at [fps].
Future<Map<String, Object?>> _pngSequenceFacts(
  FfmpegTools tools,
  String folder,
  double fps,
) async {
  final frames = _pngFrames(folder);
  if (frames.isEmpty) {
    throw CheckFailure('no frames in ${p.basename(folder)}');
  }
  final (width, height) = await tools.dimensions(frames.first.path);
  return {
    'codec': 'png',
    'width': width,
    'height': height,
    'frames': frames.length,
    'duration_s': frames.length / fps,
  };
}

/// A PNG sequence measured as a video is: its facts, and the frame shown at
/// each of the pack's times (frame `floor(t * fps) + 1`).
Future<Map<String, Object?>> _measurePngSequence(
  FfmpegTools tools,
  String folder,
  double fps,
  Map<String, dynamic> section,
) async {
  final facts = await _pngSequenceFacts(tools, folder, fps);
  final width = facts['width']! as int;
  final height = facts['height']! as int;
  final grid = section['grid'] as int;
  final out = <Map<String, Object?>>[];
  for (final t in section['frame_times_s'] as List<dynamic>) {
    final file = File(
      p.join(folder, frameFileName(((t as num) * fps).floor() + 1)),
    );
    final image = file.existsSync()
        ? await tools.frameAt(file.path, 0, width: width, height: height)
        : null;
    out.add({
      't': t,
      if (image == null) 'missing': true else ...frameStats(image, grid),
    });
  }
  return {...facts, 'bytes': _bytesOf(folder), 'frames_at': out};
}

/// `engine/source_clip`: the clip itself through the same probe and frame
/// grab as the outputs, the baseline of this platform's decoding.
Future<void> _measureSource(
  CheckRecorder recorder,
  _Probe probe,
  String input,
  Map<String, dynamic> section,
) => recorder.run('engine', 'engine/source_clip', () async {
  final clip = section['clip'] as Map<String, dynamic>;
  final result = await _measure(probe, input, section);
  _expectSize(result, clip['width'] as int, clip['height'] as int, 'clip');
  return result;
});

/// [path] with the home folder shown as `~`.
String _homeless(String path) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  return home != null && home.isNotEmpty && path.startsWith(home)
      ? '~${path.substring(home.length)}'
      : path;
}
