// The Color page's batch (lib/engine/desktop/color_batch.dart) end to end
// with a real ffmpeg and exiftool, in a temporary folder: a clip and a
// photo made at run time and stamped inside the invented Garmin dive of
// the FIT edit fixture, a log folder with that dive and a log that cannot be read; a
// folder run with colour and an overlay, the same again with "skip if
// target exists", a single file to a given name with colour only, a plain
// copy, and Stop.
// Needs ffmpeg, ffprobe and exiftool on the PATH; without them the tests
// skip themselves.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/color_run.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_run.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../../helpers/tools.dart';

const _layout = 'assets/overlays/templates/garmin/mk3i/main/normal.json';

/// Everything the run says, for the test to look at.
class Heard implements ColorBatchListener {
  // A page's controller listens, and it holds a timer, which cannot be
  // sent to another isolate: nothing the run sends there may hold the
  // listener.
  final held = Timer(Duration.zero, () {})..cancel();
  int? total;
  final working = <String>[];
  final ended = <(int, int, FileResult)>[];
  final percents = <String, double>{};
  final messages = <String>[];

  @override
  void started(int total) => this.total = total;

  @override
  void active(String file) => working.add(file);

  @override
  void finished(int done, int total, FileResult result) =>
      ended.add((done, total, result));

  @override
  void progress(String file, double percent) => percents[file] = percent;

  @override
  void message(String line) => messages.add(line);
}

void main() {
  final skip = hasTool('ffmpeg') && hasTool('ffprobe') && hasTool('exiftool')
      ? null
      : 'needs ffmpeg, ffprobe and exiftool on the PATH';

  testWidgets(
    'a folder, again with skip, a single file, a copy, Stop',
    (tester) async {
      await tester.runAsync(() async {
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
        final ffmpegPath = found[toolFfmpeg]!;
        final tools = (
          ffmpeg: FfmpegTools(
            ffmpeg: ffmpegPath,
            ffprobe: found[toolFfprobe],
            os: currentEngineOs(),
          ),
          exiftool: Exiftool(found[toolExiftool]!),
        );
        final tmp = Directory.systemTemp.createTempSync('uwmedia_batch_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        Directory dir(String name) =>
            Directory(p.join(tmp.path, name))..createSync(recursive: true);
        final media = dir('media');
        final logs = dir('logs');
        final out = dir('out');
        final work = dir('work');

        // The invented dive, and a moment ten minutes into it.
        final fixture = jsonDecode(
          utf8.decode(
            gzip.decode(
              File(
                'test/fixtures/python_reference/dives/fit_edit_cases.json.gz',
              ).readAsBytesSync(),
            ),
          ),
        ) as Map<String, dynamic>;
        final sources = fixture['sources'] as Map<String, dynamic>;
        final fit = base64.decode(sources['air'] as String);
        File(p.join(logs.path, 'dive.fit')).writeAsBytesSync(fit);
        final locked = File(p.join(logs.path, 'locked.uddf'))
          ..writeAsStringSync('<uddf/>');
        if (canLockFiles) {
          // A log the run may not read.
          await Process.run('chmod', ['000', locked.path]);
        }
        final dive = parseLogFile('/x/dive.fit', fit)!.single;
        final taken = dive.startTime.add(const Duration(minutes: 10));
        final stamp = pyStrftime(taken, '%Y:%m:%d %H:%M:%S');

        Future<void> make(List<String> args) async {
          final made = await Process.run(ffmpegPath, ['-v', 'error', ...args]);
          expect(made.exitCode, 0, reason: '${made.stderr}');
        }

        final clip = p.join(media.path, 'Reef.MP4');
        await make([
          '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=25:duration=1', //
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', clip,
        ]);
        final photo = p.join(media.path, 'Fish.jpg');
        await make([
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=320x240',
          '-frames:v',
          '1',
          photo,
        ]);
        await tools.exiftool.setTags(clip, {
          'QuickTime:CreationDate': '$stamp+00:00',
          'QuickTime:CreateDate': stamp,
        });
        await tools.exiftool.setTags(photo, {'EXIF:DateTimeOriginal': stamp});
        File(p.join(media.path, '.DS_Store')).writeAsStringSync('x');

        final profiles = mergedColorProfiles(
          File('assets/color.yaml').readAsStringSync(),
          null,
        );
        final batch = ColorBatch(
          tools: tools,
          renderer: HudRenderer(
            fonts,
            HudRules(
              jsonDecode(File('assets/hud_rules.json').readAsStringSync())
                  as Map<String, dynamic>,
            ),
          ),
          painter: HudPainter(fonts),
          tempDir: (prefix) => work.createTempSync(prefix),
        );
        final settings = ColorBatchSettings(
          source: media.path,
          output: out.path,
          logsDir: logs.path,
          colorProfileName: 'default',
          colorProfile: ColorProfile.fromMap(
            profiles['default']!.cast<String, dynamic>(),
          ),
          overlays: const [
            OverlayInstance(layoutPath: _layout, x: 0.05, y: 0.6, scale: 0.4),
          ],
          hwAccel: false,
        );

        // --- a folder: colour and an overlay ------------------------------
        final heard = Heard();
        final results = await batch.run(settings, heard);
        expect(heard.total, 2);
        expect(heard.working, unorderedEquals(['Fish.jpg', 'Reef.MP4']));
        expect(
          {for (final r in results) r.file: r.status},
          {'Fish.jpg': FileStatus.done, 'Reef.MP4': FileStatus.done},
          reason: '$results ${heard.messages}',
        );
        expect(heard.ended.map((e) => (e.$1, e.$2)), [(1, 2), (2, 2)]);
        if (canLockFiles) {
          expect(
            heard.messages.where((m) => m.contains('locked.uddf')),
            hasLength(1),
          );
        }
        expect(heard.messages.where((m) => m.contains('No matching')), isEmpty);
        expect(heard.percents['Reef.MP4'], 100);
        final video = p.join(out.path, 'Reef.mp4');
        expect(await tools.ffmpeg.dimensions(video), (320, 240));
        expect(File(p.join(out.path, 'Fish.jpg')).existsSync(), isTrue);
        expect(
          (await tools.exiftool.tags(video, ['QuickTime:CreationDate'])).values,
          ['$stamp+00:00'],
        );

        // --- again, skipping what is there --------------------------------
        final again = Heard();
        final skipped = await batch.run(
          ColorBatchSettings(
            source: media.path,
            output: out.path,
            colorProfile: settings.colorProfile,
            overlays: settings.overlays,
            noOverwrite: true,
            hwAccel: false,
          ),
          again,
        );
        expect(skipped.map((r) => r.status), everyElement(FileStatus.skipped));
        expect(
          again.messages.where((m) => m.startsWith('Skipping')),
          hasLength(2),
        );

        // --- one file to a given name, colour only (the LUT path) ---------
        final single = await batch.run(
          ColorBatchSettings(
            source: clip,
            output: p.join(out.path, 'graded.mp4'),
            colorProfile: settings.colorProfile,
            hwAccel: false,
          ),
          Heard(),
        );
        expect(single.single.status, FileStatus.done);
        expect(File(p.join(out.path, 'graded.mp4')).existsSync(), isTrue);

        // --- nothing asked: a copy under the date's name ------------------
        final copies = dir('copies');
        final copied = await batch.run(
          ColorBatchSettings(
            source: photo,
            output: copies.path,
            filenameFormat: '%Y%m%d_%H%M%S',
            hwAccel: false,
          ),
          Heard(),
        );
        expect(copied.single.status, FileStatus.done);
        expect(copies.listSync().map((f) => p.basename(f.path)), [
          pyStrftime(taken, '%Y%m%d_%H%M%S.jpg'),
        ]);

        // --- files picked one by one: run as a folder's, the source path
        // not looked at; one that is gone is said (spec §10.65) ------------
        final pickedOut = dir('picked');
        final picked = await batch.run(
          ColorBatchSettings(
            source: '',
            sourceFiles: [photo],
            output: pickedOut.path,
            filenameFormat: '%Y%m%d_%H%M%S',
            hwAccel: false,
          ),
          Heard(),
        );
        expect(picked.single.status, FileStatus.done);
        expect(pickedOut.listSync().map((f) => p.basename(f.path)), [
          pyStrftime(taken, '%Y%m%d_%H%M%S.jpg'),
        ]);
        expect(pickedSourceFiles(const []), isNull);
        await expectLater(
          batch.run(
            ColorBatchSettings(
              source: '',
              sourceFiles: [photo, p.join(media.path, 'gone.jpg')],
              output: pickedOut.path,
            ),
            Heard(),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains("gone.jpg' does not exist"),
            ),
          ),
        );

        // --- a watermark alone: on every file, no dive, no colour ----------
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 40, 20),
          ui.Paint()..color = const ui.Color(0xFFFF0000),
        );
        final red = await recorder.endRecording().toImage(40, 20);
        final logo = (await red.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        final marked = dir('marked');
        final markHeard = Heard();
        final markedResults = await batch.run(
          ColorBatchSettings(
            source: media.path,
            output: marked.path,
            hwAccel: false,
            watermarks: [
              HudLayerSource(
                watermarkLayout(
                  const Watermark(
                    name: 'Logo',
                    picture: 'logo.png',
                    anchor: 'TOP_LEFT',
                    size: 0.25,
                    opacity: 1,
                  ),
                  pictureSize: (40, 20),
                )!,
                skinBytes: logo,
                always: true,
              ),
            ],
          ),
          markHeard,
        );
        expect(
          markedResults.map((r) => r.status),
          everyElement(FileStatus.done),
          reason: '$markedResults ${markHeard.messages}',
        );
        // A quarter of 320 is 80 wide (40 high), 6 pixels in from the top
        // left: red inside it, the test picture outside.
        bool isRed(RgbImage image, int x, int y) {
          final i = (y * image.width + x) * 3;
          return image.rgb[i] > 180 &&
              image.rgb[i + 1] < 70 &&
              image.rgb[i + 2] < 70;
        }

        final frame = (await tools.ffmpeg.frameAt(
          p.join(marked.path, 'Reef.mp4'),
          0.4,
          width: 320,
          height: 240,
        ))!;
        final plain = (await tools.ffmpeg.frameAt(
          clip,
          0.4,
          width: 320,
          height: 240,
        ))!;
        // Close to the source's own pixel (the encode moves it a little).
        bool same(int x, int y) {
          final i = (y * 320 + x) * 3;
          return [
            for (var c = 0; c < 3; c++)
              (frame.rgb[i + c] - plain.rgb[i + c]).abs(),
          ].every((d) => d < 40);
        }

        expect(isRed(plain, 46, 26), isFalse);
        expect(isRed(frame, 46, 26), isTrue, reason: 'the video carries it');
        expect(same(46, 26), isFalse);
        expect(same(46, 60), isTrue, reason: 'below the mark');
        expect(same(100, 26), isTrue, reason: 'right of the mark');
        expect(same(200, 200), isTrue);
        // --- an output size: portrait, cropped at the right end, the
        // watermark on the cropped picture (spec §10.51) ------------------
        final sized = dir('sized');
        final sizedHeard = Heard();
        final sizedResults = await batch.run(
          ColorBatchSettings(
            source: clip,
            output: sized.path,
            hwAccel: false,
            outputSize: const OutputSize.share(
              ShareCopy(shareInstagram, ShareShape.portraitCropped, cropAt: 1),
            ),
            watermarks: [
              HudLayerSource(
                watermarkLayout(
                  const Watermark(
                    name: 'Logo',
                    picture: 'logo.png',
                    anchor: 'TOP_LEFT',
                    size: 0.25,
                    opacity: 1,
                  ),
                  pictureSize: (40, 20),
                )!,
                skinBytes: logo,
                always: true,
              ),
            ],
          ),
          sizedHeard,
        );
        expect(
          sizedResults.single.status,
          FileStatus.done,
          reason: '$sizedResults ${sizedHeard.messages}',
        );
        final portrait = p.join(sized.path, 'Reef.mp4');
        // 240 * 9 / 16 = 135, even 134: no more than the source has.
        expect(await tools.ffmpeg.dimensions(portrait), (134, 240));
        final written = await Process.run('ffprobe', [
          '-v', 'error', '-select_streams', 'v:0', //
          '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', portrait,
        ]);
        expect('${written.stdout}'.trim(), 'h264');
        final cropped = (await tools.ffmpeg.frameAt(
          portrait,
          0.4,
          width: 134,
          height: 240,
        ))!;
        // The mark is a quarter of the cropped width in its top-left
        // corner; the right end of the source is under it.
        expect(isRed(cropped, 14, 8), isTrue, reason: 'the mark');
        final whole = (await tools.ffmpeg.frameAt(
          clip,
          0.4,
          width: 320,
          height: 240,
        ))!;
        for (final (x, y) in [(100, 200), (60, 120)]) {
          final a = (y * 134 + x) * 3;
          final b = (y * 320 + x + 186) * 3;
          for (var c = 0; c < 3; c++) {
            expect(
              cropped.rgb[a + c],
              closeTo(whole.rgb[b + c], 45),
              reason: '($x, $y) channel $c',
            );
          }
        }

        // --- the Resize page's run with a watermark (spec §10.52): the
        // mark on the picture, then the size; cropped copies too ---------
        final resized = dir('resized');
        final mark = HudLayerSource(
          watermarkLayout(
            const Watermark(
              name: 'Logo',
              picture: 'logo.png',
              anchor: 'TOP_LEFT',
              size: 0.25,
              opacity: 1,
            ),
            pictureSize: (40, 20),
          )!,
          skinBytes: logo,
          always: true,
        );
        final converted =
            await ConvertRun(
              ffmpeg: tools.ffmpeg,
              exiftool: tools.exiftool,
              marker: (hw) => OverlayRun(
                color: ColorRun(
                  tools: tools.ffmpeg,
                  engine: ColorEngine(ColorProfile.fromMap(const {})),
                  tempDir: (prefix) => tmp.createTempSync(prefix),
                  hwAccel: hw,
                ),
                renderer: HudRenderer(fonts, HudRules(const {})),
                painter: HudPainter(fonts),
              ),
            ).convert(
              source: clip,
              outputDir: resized.path,
              resolutions: ['360p'],
              shares: const [
                ShareCopy(shareWhatsApp, ShareShape.portraitCropped, cropAt: 1),
              ],
              watermarks: [mark],
              hwAccel: false,
            );
        expect(converted.failed, isEmpty, reason: '${converted.messages}');
        // 360p by name: 640 by 360, the 4:3 picture between bars (480
        // wide, from x 80); the mark in the picture's corner.
        final small360 = p.join(resized.path, 'Reef 360p.mp4');
        expect(await tools.ffmpeg.dimensions(small360), (640, 360));
        final at360 = (await tools.ffmpeg.frameAt(
          small360,
          0.4,
          width: 640,
          height: 360,
        ))!;
        expect(isRed(at360, 80 + 40, 30), isTrue, reason: 'the mark, 360p');
        expect(isRed(at360, 80 + 300, 200), isFalse);
        final share = p.join(resized.path, 'Reef WhatsApp portrait.mp4');
        expect(await tools.ffmpeg.dimensions(share), (134, 240));
        final atShare = (await tools.ffmpeg.frameAt(
          share,
          0.4,
          width: 134,
          height: 240,
        ))!;
        expect(isRed(atShare, 14, 8), isTrue, reason: 'the mark, cropped');

        // A phone's upright video (stored lying down, turned): sized by
        // the shape it is shown in.
        final upright = p.join(tmp.path, 'Upright.mp4');
        await make([
          '-display_rotation',
          '90',
          '-i',
          clip,
          '-c',
          'copy',
          upright,
        ]);
        final turned = dir('turned');
        final turnedResults = await batch.run(
          ColorBatchSettings(
            source: upright,
            output: turned.path,
            hwAccel: false,
            outputSize: const OutputSize.share(
              ShareCopy(shareInstagram, ShareShape.portraitCropped),
            ),
          ),
          Heard(),
        );
        expect(turnedResults.single.status, FileStatus.done);
        // Shown 240 by 320: a 9:16 window of its full height, 180 wide.
        expect(
          await tools.ffmpeg.displayDimensions(
            p.join(turned.path, 'Upright.mp4'),
          ),
          (180, 320),
        );

        // A resolution: 240 rows down to 360p is not made larger; a
        // video stays as it is in size.
        final small = dir('small');
        final smallResults = await batch.run(
          ColorBatchSettings(
            source: clip,
            output: small.path,
            hwAccel: false,
            outputSize: const OutputSize.resolution('360p'),
          ),
          Heard(),
        );
        expect(smallResults.single.status, FileStatus.done);
        expect(await tools.ffmpeg.dimensions(p.join(small.path, 'Reef.mp4')), (
          320,
          240,
        ));

        final codec = await ui.instantiateImageCodec(
          File(p.join(marked.path, 'Fish.jpg')).readAsBytesSync(),
        );
        final fish = (await codec.getNextFrame()).image;
        final fishRgba = (await fish.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!.buffer.asUint8List();
        final at = (26 * fish.width + 46) * 4;
        expect(fishRgba[at], greaterThan(180), reason: 'the photo carries it');
        expect(fishRgba[at + 1], lessThan(70));

        // --- Stop -----------------------------------------------------------
        final stopping = Heard();
        final going = batch.run(
          ColorBatchSettings(
            source: media.path,
            output: dir('stopped').path,
            colorProfile: settings.colorProfile,
            hwAccel: false,
          ),
          stopping,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await batch.stop();
        await expectLater(going, throwsA(isA<RunStopped>()));

        // --- what the run cannot start with ---------------------------------
        expect(
          () => batch.run(
            ColorBatchSettings(
              source: p.join(tmp.path, 'gone'),
              output: out.path,
            ),
            Heard(),
          ),
          throwsFormatException,
        );
      });
    },
    skip: skip != null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
