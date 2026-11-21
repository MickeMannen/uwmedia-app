// The pictures of README.md: the app's window on a computer and its
// screen on a phone, with the Color page on a video of a dive, and the
// video's frame as it was shot, colour-corrected, and with the dive
// overlay and a watermark. Drawn by the real app in a test window on a
// Mac, with its settings and data in a temporary folder. Run:
//   flutter test integration_test/readme_shots_test.dart -d macos \
//     --dart-define=MEDIA=/path/video.mp4 --dart-define=LOG=/path/dive.fit \
//     --dart-define=OUT=/path/docs/images [--dart-define=OFFSET=seconds]
// The pictures hold a frame of the video: they go into git only after
// the owner's review (AGENTS.md).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/shell.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/pages/color/color_controller.dart';
import 'package:uwmedia_app/pages/color/color_page.dart';

const _media = String.fromEnvironment('MEDIA');
const _log = String.fromEnvironment('LOG');
const _out = String.fromEnvironment('OUT');
const _offset = String.fromEnvironment('OFFSET');

final _shot = GlobalKey();

Future<void> _png(ui.Image image, String name) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(p.join(_out, name)).writeAsBytesSync(bytes!.buffer.asUint8List());
}

// The frame under [_shot] as a PNG, two pixels a point.
Future<void> _screen(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shot),
  );
  final image = await boundary.toImage(pixelRatio: 2);
  await _png(image, name);
  image.dispose();
}

// [image] no wider than [width], as a PNG.
Future<void> _picture(ui.Image image, String name, {int width = 1280}) async {
  final scale = width / image.width;
  final recorder = ui.PictureRecorder();
  final size = Size(width.toDouble(), (image.height * scale).roundToDouble());
  Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.high,
  );
  final small = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  await _png(small, name);
  small.dispose();
}

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: 'waited 60 s');
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the pictures of the README', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('uwmedia_shots_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory(_out).createSync(recursive: true);
    final source = Directory(p.join(tmp.path, 'Dive videos'))..createSync();
    Link(p.join(source.path, p.basename(_media))).createSync(_media);

    AppServices services({required bool desktop}) {
      final root = p.join(tmp.path, desktop ? 'computer' : 'phone');
      final made = AppServices(
        capabilities: desktop
            ? const Capabilities(desktop: true, nativeVideo: true)
            : const Capabilities(
                desktop: false,
                mobileEngine: true,
                resultFolders: true,
              ),
        config: ConfigStore(() => Directory(p.join(root, 'config'))),
        home: tmp.path,
        tempDir: (prefix) => (Directory(
          p.join(root, 'tmp'),
        )..createSync(recursive: true)).createTempSync(prefix),
        dataDir: () => Directory(p.join(root, 'data')),
      );
      // The dive log, kept as the Dive Logs page keeps it.
      final logs = made.logStore.folder..createSync(recursive: true);
      File(_log).copySync(p.join(logs.path, p.basename(_log)));
      made.watermarks.addText('© UWMedia');
      return made;
    }

    Future<ColorController> show(
      AppServices made,
      Size size, {
      required bool frame,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(),
          home: ColoredBox(
            color: Colors.black,
            child: FittedBox(
              child: RepaintBoundary(
                key: _shot,
                child: SizedBox.fromSize(
                  size: size,
                  child: MediaQuery(
                    data: MediaQueryData(
                      size: size,
                      padding: frame
                          ? const EdgeInsets.only(top: 47, bottom: 34)
                          : EdgeInsets.zero,
                    ),
                    child: AppShell(key: ValueKey(size), services: made),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _wait(tester, () => find.byType(ColorPage).evaluate().isNotEmpty);
      ColorController? controller() =>
          // ignore: avoid_dynamic_calls
          (tester.state(find.byType(ColorPage)) as dynamic).controller
              as ColorController?;
      await _wait(tester, () => controller() != null);
      final c = controller()!;
      await c.setSource(source.path);
      await _wait(tester, () => c.previewImage != null && c.scrubEnabled);
      if (_offset.isNotEmpty) {
        await c.nudgeOffset(double.parse(_offset));
      }
      // A frame some way into the video.
      await c.scrubTo((c.scrubMaximum * 0.35).round());
      await _wait(tester, () => c.matchedDive != null);
      return c;
    }

    // -- the computer --------------------------------------------------
    final computer = services(desktop: true);
    var c = await show(computer, const Size(1280, 860), frame: false);
    final original = c.originalImage!.clone();
    await _picture(original, 'frame-original.png');
    original.dispose();

    c.colorChecked = true;
    await _wait(tester, () => c.previewImage != null);
    await tester.pump(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    await _picture(c.previewImage!, 'frame-corrected.png');

    c.picker.reset();
    c.picker.selectBrand('generic');
    expect(await c.addPickedOverlay(), isTrue);
    c.setWatermark('© UWMedia', true);
    await tester.pump(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    c.pressAt(-10, -10, 1);
    await c.release();
    await tester.pump(const Duration(milliseconds: 500));
    await _picture(c.previewImage!, 'frame-overlay.png');
    await _screen(tester, 'desktop-color.png');

    // -- the phone -----------------------------------------------------
    await tester.pumpWidget(const SizedBox());
    final phone = services(desktop: false);
    c = await show(phone, const Size(393, 852), frame: true);
    c.colorChecked = true;
    c.picker.reset();
    c.picker.selectBrand('generic');
    expect(await c.addPickedOverlay(), isTrue);
    await tester.pump(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    c.pressAt(-10, -10, 1);
    await c.release();
    await tester.pump(const Duration(milliseconds: 500));
    await _screen(tester, 'phone-color.png');
  });
}
