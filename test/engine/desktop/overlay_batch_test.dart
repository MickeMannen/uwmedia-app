// The Overlay Generator's runs (lib/engine/desktop/overlay_batch.dart) end
// to end with a real ffmpeg and exiftool, in a temporary folder: a clip and
// a photo stamped inside the invented Garmin dive of the FIT edit fixture,
// rendered as transparent ProRes (and PNG), as HEVC on black (and a JPEG),
// and as a PNG sequence, again with "skip if target exists", and the whole
// dive from its log file.
// Needs ffmpeg, ffprobe and exiftool on the PATH; without them the test
// skips itself.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_batch.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../../helpers/tools.dart';

const _layout = 'assets/overlays/templates/garmin/mk3i/main/normal.json';

class Heard implements ColorBatchListener {
  // A page's controller listens, and it holds a timer, which cannot be
  // sent to another isolate: nothing the run sends there may hold the
  // listener.
  final held = Timer(Duration.zero, () {})..cancel();
  final ended = <FileResult>[];
  final messages = <String>[];
  final percents = <String, double>{};

  @override
  void started(int total) {}

  @override
  void active(String file) {}

  @override
  void finished(int done, int total, FileResult result) => ended.add(result);

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
    'a folder in three formats, skip, and a whole log',
    (tester) async {
      await tester.runAsync(() async {
        for (final family in fontRegistry.values) {
          for (final file in family.values) {
            await (FontLoader(fontFamilyOf(file))..addFont(
                  Future.value(
                    ByteData.sublistView(
                      File('assets/fonts/$file').readAsBytesSync(),
                    ),
                  ),
                ))
                .load();
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
        final tmp = Directory.systemTemp.createTempSync('uwmedia_overlays_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        Directory dir(String name) =>
            Directory(p.join(tmp.path, name))..createSync(recursive: true);
        final media = dir('media');
        final logs = dir('logs');

        final fixture = jsonDecode(
          utf8.decode(
            gzip.decode(
              File(
                'test/fixtures/python_reference/dives/fit_edit_cases.json.gz',
              ).readAsBytesSync(),
            ),
          ),
        ) as Map<String, dynamic>;
        final fit = base64.decode(
          (fixture['sources'] as Map<String, dynamic>)['air'] as String,
        );
        final logPath = p.join(logs.path, 'dive.fit');
        File(logPath).writeAsBytesSync(fit);
        final dive = parseLogFile(logPath, fit)!.single;
        final stamp = pyStrftime(
          dive.startTime.add(const Duration(minutes: 2)),
          '%Y:%m:%d %H:%M:%S',
        );

        Future<void> make(List<String> args) async {
          final made = await Process.run(ffmpegPath, ['-v', 'error', ...args]);
          expect(made.exitCode, 0, reason: '${made.stderr}');
        }

        final clip = p.join(media.path, 'Reef.MP4');
        await make([
          '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=10:duration=1', //
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

        final batch = OverlayBatch(
          tools: tools,
          renderer: HudRenderer(
            fonts,
            HudRules(
              jsonDecode(File('assets/hud_rules.json').readAsStringSync())
                  as Map<String, dynamic>,
            ),
          ),
          painter: HudPainter(fonts),
        );

        OverlayFolderSettings folder(
          String format,
          String out, {
          bool skip = false,
        }) => OverlayFolderSettings(
          source: media.path,
          output: out,
          logsDir: logs.path,
          layoutPath: _layout,
          look: (format: format, size: '1080p', fullFrame: false),
          filenameFormat: '{filename}_{hud}',
          noOverwrite: skip,
          hwAccel: false,
        );

        // --- transparent ProRes: a .mov and a transparent PNG ---------------
        final prores = dir('prores').path;
        final heard = Heard();
        final results = await batch.runFolder(
          folder(overlayFormatProres, prores),
          heard,
        );
        expect(
          {for (final r in results) r.file: r.status},
          {'Fish.jpg': FileStatus.done, 'Reef.MP4': FileStatus.done},
          reason: '$results ${heard.messages}',
        );
        expect(heard.messages.where((m) => m.contains('No matching')), isEmpty);
        expect(
          Directory(prores).listSync().map((f) => p.basename(f.path)).toSet(),
          {'Reef_normal.mov', 'Fish_normal.png'},
        );
        expect(
          await tools.ffmpeg.pixFmt(p.join(prores, 'Reef_normal.mov')),
          startsWith('yuva444p'),
        );
        expect(
          (await tools.exiftool.tags(p.join(prores, 'Reef_normal.mov'), [
            'QuickTime:CreationDate',
          ])).values.single,
          '$stamp+00:00',
        );

        // --- the same again, skipping what is there ---------------------------
        final again = await batch.runFolder(
          folder(overlayFormatProres, prores, skip: true),
          Heard(),
        );
        expect(again.map((r) => r.status), everyElement(FileStatus.skipped));

        // --- HEVC on black: the photo stays a JPEG ------------------------------
        final hevc = dir('hevc').path;
        expect(
          (await batch.runFolder(
            folder(overlayFormatHevc, hevc),
            Heard(),
          )).map((r) => r.status),
          everyElement(FileStatus.done),
        );
        expect(
          Directory(hevc).listSync().map((f) => p.basename(f.path)).toSet(),
          {'Reef_normal.mp4', 'Fish_normal.jpg'},
        );

        // --- a PNG sequence: a folder of frames ---------------------------------
        final png = dir('png').path;
        await batch.runFolder(folder(overlayFormatPng, png), Heard());
        final frames = Directory(p.join(png, 'Reef_normal'));
        expect(frames.existsSync(), isTrue);
        expect(frames.listSync(), hasLength(10));

        // --- the whole dive from its log, twice ---------------------------------
        final fromLog = dir('log').path;
        final first = await batch.runLog(
          logPath: logPath,
          output: fromLog,
          layoutPath: _layout,
          look: (format: overlayFormatHevc, size: '1080p', fullFrame: false),
          hwAccel: false,
        );
        expect(p.basename(first), 'dive_normal.mp4');
        final second = await batch.runLog(
          logPath: logPath,
          output: fromLog,
          layoutPath: _layout,
          look: (format: overlayFormatHevc, size: '1080p', fullFrame: false),
          hwAccel: false,
        );
        expect(p.basename(second), 'dive_normal_1.mp4');
        final seconds = await tools.ffmpeg.duration(first);
        expect(seconds, closeTo(dive.duration, 1));
        expect(
          (await tools.exiftool.tags(first, [
            'QuickTime:CreationDate',
          ])).values.single,
          '${pyStrftime(dive.startTime, '%Y:%m:%d %H:%M:%S')}+00:00',
        );
        expect(
          () => batch.runLog(
            logPath: photo,
            output: fromLog,
            layoutPath: _layout,
            look: (format: overlayFormatHevc, size: '1080p', fullFrame: false),
          ),
          throwsFormatException,
        );
      });
    },
    skip: skip != null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
