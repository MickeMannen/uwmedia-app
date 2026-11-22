// Before and after in one picture through the Color page's batch (spec
// §10.94) with a real ffmpeg and exiftool, in a temporary folder: a
// twelve-second clip split (ten seconds of it written), a photo split,
// and a photo's wipe video. The media are made at run time.
// Needs ffmpeg, ffprobe and exiftool on the PATH; without them the test
// skips itself.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../../helpers/tools.dart';

class _Quiet implements ColorBatchListener {
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

const _w = 320;
const _h = 240;

void main() {
  final skip = hasTool('ffmpeg') && hasTool('ffprobe') && hasTool('exiftool')
      ? null
      : 'needs ffmpeg, ffprobe and exiftool on the PATH';

  testWidgets(
    'a split video, a split photo and a wipe video',
    (tester) async {
      await tester.runAsync(() async {
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
        final tmp = Directory.systemTemp.createTempSync('uwmedia_compare_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        Directory dir(String name) =>
            Directory(p.join(tmp.path, name))..createSync(recursive: true);
        final media = dir('media');
        final out = dir('out');
        final work = dir('work');

        Future<void> make(List<String> args) async {
          final made = await Process.run(ffmpegPath, ['-v', 'error', ...args]);
          expect(made.exitCode, 0, reason: '${made.stderr}');
        }

        // A still, blue-green picture, as under water: the correction
        // changes it, and every frame of the clip is the same.
        const picture =
            'testsrc2=size=${_w}x$_h:rate=25,trim=end_frame=1,'
            'colorchannelmixer=rr=0.25:gg=0.8:bb=0.9';
        final clip = p.join(media.path, 'Reef.mp4');
        await make([
          '-f', 'lavfi', '-i', '$picture,loop=loop=299:size=1', //
          '-c:v', 'libx264', '-crf', '10', '-pix_fmt', 'yuv420p', clip,
        ]);
        expect(await tools.ffmpeg.duration(clip), closeTo(12, 0.1));
        final photo = p.join(media.path, 'Fish.jpg');
        await make([
          '-f', 'lavfi', '-i', picture, '-frames:v', '1', '-q:v', '1', photo, //
        ]);

        // A frame of a file as RGB bytes.
        Future<Uint8List> rgbOf(String path, {int frame = 0}) async {
          final got = await Process.run(ffmpegPath, [
            '-v', 'error', '-i', path, //
            '-vf', 'select=eq(n\\,$frame),scale=$_w:$_h',
            '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
          ], stdoutEncoding: null);
          expect(got.exitCode, 0, reason: '${got.stderr}');
          final bytes = Uint8List.fromList(got.stdout as List<int>);
          expect(bytes.length, _w * _h * 3);
          return bytes;
        }

        // How far the pictures are apart around ([x], [y]): the largest
        // difference of a channel's mean over a small square.
        double apart(Uint8List a, Uint8List b, int x, int y) {
          var worst = 0.0;
          for (var c = 0; c < 3; c++) {
            var sum = 0;
            for (var dy = -4; dy <= 4; dy++) {
              for (var dx = -4; dx <= 4; dx++) {
                final i = ((y + dy) * _w + x + dx) * 3 + c;
                sum += a[i] - b[i];
              }
            }
            final mean = (sum / 81).abs();
            worst = mean > worst ? mean : worst;
          }
          return worst;
        }

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
        ColorBatchSettings settings(String source, Compare? compare) =>
            ColorBatchSettings(
              source: source,
              output: out.path,
              colorProfileName: 'default',
              colorProfile: ColorProfile.fromMap(
                profiles['default']!.cast<String, dynamic>(),
              ),
              compare: compare,
              hwAccel: false,
            );
        Future<void> run(String source, Compare? compare) async {
          final heard = _Quiet();
          final results = await batch.run(settings(source, compare), heard);
          expect(
            results.single.status,
            FileStatus.done,
            reason: '$results ${heard.messages}',
          );
        }

        // --- the video: original left, corrected right, ten seconds ------
        await run(clip, null);
        await run(clip, const Compare(CompareKind.vertical));
        final corrected = p.join(out.path, 'Reef.mp4');
        final compared = p.join(out.path, 'Reef compare.mp4');
        expect(File(compared).existsSync(), isTrue);
        expect(await tools.ffmpeg.duration(corrected), closeTo(12, 0.1));
        expect(await tools.ffmpeg.duration(compared), closeTo(10, 0.1));
        final was = await rgbOf(clip);
        final now = await rgbOf(corrected);
        final both = await rgbOf(compared, frame: 100);
        // The correction changes the picture at both places looked at.
        expect(apart(was, now, 60, 120), greaterThan(12));
        expect(apart(was, now, 260, 120), greaterThan(12));
        expect(apart(both, was, 60, 120), lessThan(6));
        expect(apart(both, now, 260, 120), lessThan(6));
        // The line in the middle is bright.
        final middle = (120 * _w + 160) * 3;
        expect(
          both[middle] + both[middle + 1] + both[middle + 2],
          greaterThan(450),
        );

        // --- above and below ----------------------------------------------
        File(compared).deleteSync();
        await run(clip, const Compare(CompareKind.horizontal));
        final stacked = await rgbOf(compared);
        expect(apart(stacked, was, 160, 50), lessThan(6));
        expect(apart(stacked, now, 160, 190), lessThan(6));

        // --- the photo ------------------------------------------------------
        await run(photo, null);
        await run(photo, const Compare(CompareKind.diagonal));
        final photoWas = await rgbOf(photo);
        final photoNow = await rgbOf(p.join(out.path, 'Fish.jpg'));
        final photoBoth = await rgbOf(p.join(out.path, 'Fish compare.jpg'));
        expect(apart(photoWas, photoNow, 60, 120), greaterThan(12));
        expect(apart(photoBoth, photoWas, 60, 120), lessThan(6));
        expect(apart(photoBoth, photoNow, 260, 120), lessThan(6));
        // Leaning: at the top the original reaches past the middle, at
        // the bottom the corrected picture does.
        expect(apart(photoBoth, photoWas, 172, 10), lessThan(6));
        expect(apart(photoBoth, photoNow, 148, 230), lessThan(6));

        // --- the photo's wipe video ----------------------------------------
        await run(photo, const Compare(CompareKind.vertical, wipe: true));
        final wipe = p.join(out.path, 'Fish compare.mp4');
        expect(File(wipe).existsSync(), isTrue);
        expect(await tools.ffmpeg.countedFrames(wipe), 120);
        expect(await tools.ffmpeg.dimensions(wipe), (_w, _h));
        final first = await rgbOf(wipe);
        final half = await rgbOf(wipe, frame: 52);
        final last = await rgbOf(wipe, frame: 119);
        expect(apart(first, photoWas, 60, 120), lessThan(8));
        expect(apart(first, photoWas, 260, 120), lessThan(8));
        expect(apart(half, photoNow, 60, 120), lessThan(8));
        expect(apart(half, photoWas, 260, 120), lessThan(8));
        expect(apart(last, photoNow, 60, 120), lessThan(8));
        expect(apart(last, photoNow, 260, 120), lessThan(8));

        // Without the colour correction there is nothing to compare: the
        // file is written under its own name.
        final plain = dir('plain');
        final heard = _Quiet();
        await batch.run(
          ColorBatchSettings(
            source: photo,
            output: plain.path,
            compare: const Compare(CompareKind.vertical),
          ),
          heard,
        );
        expect(File(p.join(plain.path, 'Fish.jpg')).existsSync(), isTrue);
      });
    },
    skip: skip != null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
