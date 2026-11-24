// Pre-release validation on the full-size media (Python
// tests/release_test.py): the clips and photos of test_data/release_test
// (4K video, 20 MB photos) and the real dive logs of test_data/logs, run
// through the Color page's batch with a real ffmpeg and exiftool:
// - the capture dates read from the files;
// - colour on the 4K clip (hardware encoder where the machine has one),
//   every photo, and the vivid and punchy profiles;
// - colour with an overlay on the DJI clip and on photos, matched to the
//   Garmin and Subsurface logs: the dive is found, and the overlay is
//   really drawn (its box differs from the colour-only output, the rest
//   of the picture does not);
// - the Overlay Generator from a log (Python's --render-log): the Garmin
//   log with each overlay of the Python test, the Shearwater UDDF with the
//   depth and temperature one, each a whole dive (Python stops after 20
//   waypoints, an option the page does not have). Python's --export-json
//   is not ported (spec §0), so its test has no counterpart here.
// The outputs stay in build/release_test for a look (like the platform
// check's reports in build/platform_check), and are replaced on the next
// run. `tool/run_tests.sh 3` (or 4) runs it; the
// default run leaves it out. Without the media or the tools it skips.
@Tags(['release', 'requires_media'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_batch.dart';
import 'package:uwmedia_app/engine/desktop/telemetry_run.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../helpers/test_data.dart';
import '../helpers/tools.dart';

const _sonyClip = '20251019_M0284.MP4';
const _djiClip = 'DJI_20260502110658_0002_D_A001.MP4';
const _photo = 'DSC03491.JPG';
const _ssrfPhoto = 'DSC06422.JPG';

/// The two layouts of the Python test (its Garmin X50 and generic depth and
/// temperature templates).
const _layouts = {
  'x50i': 'assets/overlays/templates/garmin/x50i/main/normal.json',
  'depth_temp':
      'assets/overlays/templates/generic/depth_temp/standard/normal.json',
};

/// The bundled templates for the overlays of Python's --render-log test
/// (its Garmin X50 simple and sidemount, Perdix 2 simple, and generic depth
/// and temperature in two sizes).
const _logLayouts = {
  'x50i_single_tank':
      'assets/overlays/templates/garmin/x50i/main/single_tank/normal.json',
  'x50i_sidemount':
      'assets/overlays/templates/garmin/x50i/main/sidemount/normal.json',
  'perdix_2':
      'assets/overlays/templates/shearwater/perdix_2/main/single_tank/'
      'normal.json',
  'depth_temp':
      'assets/overlays/templates/generic/depth_temp/standard/normal.json',
  'depth_temp_compact':
      'assets/overlays/templates/generic/depth_temp/compact/normal.json',
};

const _fitLog = '488 Phuket, Camera Bay.fit';
const _uddfLog = 'Perdix 2 453 2025-10-19 16-44-12.uddf';

/// Where each overlay goes: left, lower half, a third of the width.
const _x = 0.05, _y = 0.55, _scale = 0.35;

class _Heard implements ColorBatchListener {
  final messages = <String>[];

  @override
  void started(int total) {}

  @override
  void active(String file) {}

  @override
  void finished(int done, int total, FileResult result) {}

  @override
  void progress(String file, double percent) {}

  @override
  void message(String line) => messages.add(line);
}

typedef _Tools = ({FfmpegTools ffmpeg, Exiftool exiftool});

void main() {
  final media = '${testDataDir().path}/release_test';
  final logs = '${testDataDir().path}/logs';
  final results = Directory('build/release_test');
  final skip =
      skipIfNoTestData('release_test/$_djiClip') ??
      skipIfNoTestData('logs/fit') ??
      (hasTool('ffmpeg') && hasTool('ffprobe') && hasTool('exiftool')
          ? null
          : 'needs ffmpeg, ffprobe and exiftool on the PATH');
  const long = Timeout(Duration(minutes: 30));

  late _Tools tools;
  String? ffprobe;
  late String ffmpegPath;
  late ColorBatch batch;
  late OverlayBatch overlays;
  late ColorProfile defaultProfile;
  late Map<String, Map<String, dynamic>> profiles;

  Future<void> setUpEngine() async {
    for (final family in fontRegistry.values) {
      for (final file in family.values) {
        final loader = FontLoader(fontFamilyOf(file))
          ..addFont(
            Future.value(
              ByteData.sublistView(
                File('assets/fonts/$file').readAsBytesSync(),
              ),
            ),
          );
        await loader.load();
      }
    }
    final fonts = TtfFonts(
      (file) => File('assets/fonts/$file').readAsBytesSync(),
      inkTables: InkTables.parse(
        File('assets/fonts/ink_tables.bin').readAsBytesSync(),
      ),
    );
    final found = await ToolFinder.forThisMachine().findAll(const {});
    ffprobe = found[toolFfprobe];
    ffmpegPath = found[toolFfmpeg]!;
    tools = (
      ffmpeg: FfmpegTools(
        ffmpeg: ffmpegPath,
        ffprobe: ffprobe,
        os: currentEngineOs(),
      ),
      exiftool: Exiftool(found[toolExiftool]!),
    );
    final work = Directory.systemTemp.createTempSync('uwmedia_release_');
    addTearDown(() => work.deleteSync(recursive: true));
    final renderer = HudRenderer(
      fonts,
      HudRules(
        jsonDecode(File('assets/hud_rules.json').readAsStringSync())
            as Map<String, dynamic>,
      ),
    );
    final painter = HudPainter(fonts);
    batch = ColorBatch(
      tools: tools,
      renderer: renderer,
      painter: painter,
      tempDir: (prefix) => work.createTempSync(prefix),
    );
    overlays = OverlayBatch(tools: tools, renderer: renderer, painter: painter);
    profiles = mergedColorProfiles(
      File('assets/color.yaml').readAsStringSync(),
      null,
    ).map((k, v) => MapEntry(k, v.cast<String, dynamic>()));
    defaultProfile = ColorProfile.fromMap(profiles['default']!);
  }

  /// This test's own output folder, emptied first.
  Directory outFor(String name) {
    final dir = Directory(p.join(results.path, name));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    return dir..createSync(recursive: true);
  }

  /// One file through the batch to [output] (a file name); fails on
  /// anything but a clean run.
  Future<List<String>> run(
    String source,
    String output, {
    ColorProfile? profile,
    String profileName = 'default',
    String? logsDir,
    String? layout,
    bool hwAccel = true,
  }) async {
    final heard = _Heard();
    final done = await batch.run(
      ColorBatchSettings(
        source: source,
        output: output,
        logsDir: logsDir,
        colorProfileName: profileName,
        colorProfile: profile ?? defaultProfile,
        overlays: [
          if (layout != null)
            OverlayInstance(layoutPath: layout, x: _x, y: _y, scale: _scale),
        ],
        hwAccel: hwAccel,
      ),
      heard,
    );
    expect(
      done.single.status,
      FileStatus.done,
      reason: '$done ${heard.messages}',
    );
    expect(
      heard.messages.where(
        (m) => m.contains('Could not process') || m.startsWith('Error'),
      ),
      isEmpty,
      reason: '${heard.messages}',
    );
    expect(File(output).existsSync(), isTrue, reason: output);
    return heard.messages;
  }

  /// The encoder FFmpeg wrote into the video stream's tags.
  Future<String> encoderTag(String path) async {
    final r = await Process.run(ffprobe!, [
      '-v', 'error', '-select_streams', 'v:0', //
      '-show_entries', 'stream_tags=encoder',
      '-of', 'default=nw=1:nk=1', path,
    ]);
    return (r.stdout as String).trim();
  }

  /// A --hw-accel render really went through this machine's hardware
  /// encoder (where it has one).
  Future<void> expectHwEncoded(String path) async {
    final encoder = await tools.ffmpeg.encoder(hwAccel: true);
    if (encoder == 'libx265') {
      markTestSkipped('no hardware encoder on this machine');
      return;
    }
    expect(await encoderTag(path), contains(encoder), reason: path);
  }

  /// A [width] x [height] RGB grab of [path]: the frame at [seconds] of a
  /// video, or the photo (ffmpeg gives no frame for `-ss` on a still).
  Future<Uint8List> grab(
    String path,
    int width,
    int height, {
    double? seconds,
  }) async {
    final r = await Process.run(ffmpegPath, [
      '-nostdin', '-loglevel', 'error', //
      if (seconds != null) ...['-ss', '$seconds'],
      '-i', path, '-frames:v', '1',
      '-vf', 'format=rgb24,scale=$width:$height:flags=area',
      '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
    ], stdoutEncoding: null);
    final bytes = Uint8List.fromList(r.stdout as List<int>);
    expect(bytes.length, width * height * 3, reason: '$path: ${r.stderr}');
    return bytes;
  }

  /// How many pixels of [a] and [b] (one size) differ clearly (by more
  /// than 40 levels in a channel) inside the overlay's box and outside it,
  /// on a 640 pixel wide grab at [seconds].
  Future<(int inside, int outside)> overlayDiff(
    String a,
    String b, {
    double? seconds,
  }) async {
    final (w, h) = await tools.ffmpeg.dimensions(a);
    expect(await tools.ffmpeg.dimensions(b), (w, h));
    const gw = 640;
    final gh = (h * gw / w).round() ~/ 2 * 2;
    final fa = await grab(a, gw, gh, seconds: seconds);
    final fb = await grab(b, gw, gh, seconds: seconds);
    // The box: from (x, y), as wide as the scale; how high depends on the
    // layout, so the band down to the bottom.
    final x0 = (_x * gw).floor(), x1 = ((_x + _scale) * gw).ceil();
    final y0 = (_y * gh).floor();
    var inside = 0, outside = 0;
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        final i = (y * gw + x) * 3;
        var changed = false;
        for (var c = 0; c < 3 && !changed; c++) {
          changed = (fa[i + c] - fb[i + c]).abs() > 40;
        }
        if (!changed) {
          continue;
        }
        if (x >= x0 && x < x1 && y >= y0) {
          inside++;
        } else {
          outside++;
        }
      }
    }
    return (inside, outside);
  }

  void expectOverlayDrawn((int, int) diff, String what) {
    final (inside, outside) = diff;
    // The smallest layout (depth and temperature) covers some 600 pixels
    // of a 640 wide grab; encoder noise changes next to none by that much.
    expect(inside, greaterThan(200), reason: '$what: no overlay drawn');
    expect(outside, lessThan(inside ~/ 10), reason: '$what: $diff');
  }

  test('the capture dates of the clip and the photo', () async {
    final found = await ToolFinder.forThisMachine().findAll(const {});
    final exiftool = Exiftool(found[toolExiftool]!);
    // To the second, as the Python test reads it (the photo has 0.98 s
    // more in SubSecTimeOriginal).
    DateTime dateOf(String name, MediaTags? meta) {
      final d = localCreationDate(
        meta,
        fileModified: fileModified(p.join(media, name)),
      );
      return d.subtract(
        Duration(milliseconds: d.millisecond, microseconds: d.microsecond),
      );
    }

    final clip = p.join(media, _sonyClip);
    expect(
      dateOf(_sonyClip, await exiftool.metadata(clip)),
      naive(2025, 10, 19, 10, 21, 31),
    );
    final photo = p.join(media, _photo);
    expect(
      dateOf(_photo, await exiftool.metadata(photo)),
      naive(2025, 12, 3, 9, 15, 48),
    );
  }, skip: skip);

  testWidgets(
    'colour: the 4K clip, every photo, the profiles',
    (tester) async {
      await tester.runAsync(() async {
        await setUpEngine();
        final out = outFor('color');

        final video = p.join(out.path, 'color_sony.mp4');
        await run(p.join(media, _sonyClip), video);
        await expectHwEncoded(video);
        expect(await tools.ffmpeg.dimensions(video), (3840, 2160));

        final photos = [
          for (final f in Directory(media).listSync())
            if (f.path.toUpperCase().endsWith('.JPG')) f.path,
        ]..sort();
        expect(photos, hasLength(6));
        for (final photo in photos) {
          final target = p.join(out.path, 'color_${p.basename(photo)}');
          await run(photo, target);
          expect(
            await tools.ffmpeg.dimensions(target),
            await tools.ffmpeg.dimensions(photo),
          );
        }

        for (final name in ['vivid', 'punchy']) {
          final profile = ColorProfile.fromMap(profiles[name]!);
          await run(
            p.join(media, _photo),
            p.join(out.path, 'profile_${name}_$_photo'),
            profile: profile,
            profileName: name,
          );
          await run(
            p.join(media, _sonyClip),
            p.join(out.path, 'profile_${name}_sony.mp4'),
            profile: profile,
            profileName: name,
          );
        }
      });
    },
    skip: skip != null,
    timeout: long,
  );

  testWidgets(
    'colour and overlays: the DJI clip, with the Garmin logs',
    (tester) async {
      await tester.runAsync(() async {
        await setUpEngine();
        final out = outFor('overlay_video');
        final clip = p.join(media, _djiClip);
        final plain = p.join(out.path, 'color_only.mp4');
        await run(clip, plain);
        for (final MapEntry(key: name, value: layout) in _layouts.entries) {
          final target = p.join(out.path, 'overlay_$name.mp4');
          final messages = await run(
            clip,
            target,
            logsDir: '$logs/fit',
            layout: layout,
          );
          expect(
            messages.where((m) => m.contains('No matching')),
            isEmpty,
            reason: '$name: the dive was not found',
          );
          await expectHwEncoded(target);
          expectOverlayDrawn(
            await overlayDiff(target, plain, seconds: 2),
            'DJI $name',
          );
        }
      });
    },
    skip: skip != null,
    timeout: long,
  );

  testWidgets(
    'colour and overlays: photos, with the Garmin and Subsurface '
    'logs',
    (tester) async {
      await tester.runAsync(() async {
        await setUpEngine();
        final out = outFor('overlay_photo');
        final photo = p.join(media, _photo);
        final plain = p.join(out.path, 'color_only_$_photo');
        await run(photo, plain);
        for (final MapEntry(key: name, value: layout) in _layouts.entries) {
          final target = p.join(out.path, 'overlay_${name}_$_photo');
          final messages = await run(
            photo,
            target,
            logsDir: '$logs/fit',
            layout: layout,
          );
          expect(
            messages.where((m) => m.contains('No matching')),
            isEmpty,
            reason: '$name: the dive was not found',
          );
          expectOverlayDrawn(await overlayDiff(target, plain), '$_photo $name');
        }

        final ssrfPhoto = p.join(media, _ssrfPhoto);
        final ssrfPlain = p.join(out.path, 'color_only_$_ssrfPhoto');
        await run(ssrfPhoto, ssrfPlain);
        final target = p.join(out.path, 'overlay_depth_temp_$_ssrfPhoto');
        final messages = await run(
          ssrfPhoto,
          target,
          logsDir: '$logs/ssrf',
          layout: _layouts['depth_temp'],
        );
        expect(messages.where((m) => m.contains('No matching')), isEmpty);
        expectOverlayDrawn(
          await overlayDiff(target, ssrfPlain),
          '$_ssrfPhoto depth_temp',
        );
      });
    },
    skip: skip != null,
    timeout: long,
  );

  testWidgets(
    'the Overlay Generator from a log: the Garmin log with each overlay, '
    'the Shearwater UDDF',
    (tester) async {
      await tester.runAsync(() async {
        await setUpEngine();
        final out = outFor('render_log');
        Future<void> render(String log, String name, String layout) async {
          final dive = parseLogFile(log, File(log).readAsBytesSync())!.first;
          final target = await overlays.runLog(
            logPath: log,
            output: p.join(
              out.path,
              '${p.basenameWithoutExtension(log)}_$name.mp4',
            ),
            layoutPath: layout,
            look: (format: overlayFormatHevc, size: '1080p', fullFrame: false),
          );
          expect(File(target).existsSync(), isTrue, reason: target);
          await expectHwEncoded(target);
          expect(
            await tools.ffmpeg.duration(target),
            closeTo(TelemetryRun.logFrames(dive) / logRenderFps, 1),
            reason: name,
          );
          // Drawn on black: half way through the dive, the overlay is there.
          final (w, h) = await tools.ffmpeg.dimensions(target);
          final frame = await grab(
            target,
            w ~/ 4,
            h ~/ 4,
            seconds: dive.duration / 2,
          );
          var lit = 0;
          for (var i = 0; i < frame.length; i += 3) {
            if (frame[i] + frame[i + 1] + frame[i + 2] > 120) {
              lit++;
            }
          }
          expect(lit, greaterThan(200), reason: '$name: nothing drawn');
        }

        final fit = p.join(logs, 'fit', _fitLog);
        for (final MapEntry(key: name, value: layout) in _logLayouts.entries) {
          await render(fit, name, layout);
        }
        await render(
          p.join(logs, 'uddf', _uddfLog),
          'depth_temp',
          _logLayouts['depth_temp']!,
        );
      });
    },
    skip: (skip ?? skipIfNoTestData('logs/uddf/$_uddfLog')) != null,
    timeout: long,
  );
}
