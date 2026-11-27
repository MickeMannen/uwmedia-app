// The pictures of the website (the project `app_web`, its folder
// src/assets/uwmedia): a video's frame with a dive computer's overlay,
// three pages of the app's window on a computer, and three screens on an
// iPhone and on an Android phone. Drawn by the real app in a test window
// on a Mac, with its settings and data in a temporary folder, as the
// README's pictures are (readme_shots_test.dart). Run:
//   flutter test integration_test/web_shots_test.dart -d macos \
//     --dart-define=MEDIA=/path/video.mp4 --dart-define=LOG=/path/dive.fit \
//     --dart-define=OUT=/path/folder
// The dive of LOG must hold the time of MEDIA and two tanks' pressures
// (the overlays are the sidemount ones). The pictures are PNG; the site
// takes them as JPEG. They hold a frame of the video: they are published
// only after the owner's review (AGENTS.md).
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/shell.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/pages/color/color_controller.dart';
import 'package:uwmedia_app/pages/color/color_page.dart';
import 'package:uwmedia_app/pages/convertion/convertion_controller.dart';
import 'package:uwmedia_app/pages/convertion/convertion_page.dart';
import 'package:uwmedia_app/pages/log_viewer/log_viewer_controller.dart';
import 'package:uwmedia_app/pages/log_viewer/log_viewer_page.dart';
import 'package:uwmedia_app/pages/overlay_designer/designer_controller.dart';
import 'package:uwmedia_app/pages/overlay_designer/overlay_designer_page.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_controller.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_page.dart';
import 'package:uwmedia_app/pages/shared/tank_names.dart';
import 'package:window_manager/window_manager.dart';

const _media = String.fromEnvironment('MEDIA');
const _log = String.fromEnvironment('LOG');
const _out = String.fromEnvironment('OUT');

// 'computer' or 'phones' for only that half of the website's pictures;
// both when empty. 'store' for the Mac App Store's screenshots instead:
// five pages of the store's app (no ffmpeg, no exiftool; run it with
// --dart-define=UWMEDIA_STORE=true too) in a window of 1280 x 800 points,
// which gives the 2560 x 1600 pixels the store takes.
// 'photo' for a photo before and after the colour correction instead:
// PHOTO as shot, corrected, and the two halves side by side in one
// picture of 2560 x 1600 (the store's size).
// 'photo-overlays' for PHOTO before and after the colour correction with
// four overlays on it, one in each corner (the Garmin X50i's sidemount
// screen, the Perdix 2, the Perdix 3 and the plain depth and temperature
// box), in one picture of 2560 x 1600. LOG must hold the photo's time.
// 'store-overlays' for one more of the Mac App Store's screenshots: the
// Color page on PHOTO, corrected with PROFILE, with seven overlays spread
// over the picture (LOG must hold the photo's time) and, when LOGO names a
// picture, that as a watermark.
// 'iphone-store' for the iPhone App Store's screenshots: five screens of
// the phone's app at 440 x 956 points and three pixels a point, the 1320 x
// 2868 the store takes for a 6.9" iPhone. PHOTO is then a photo for the
// Color page (with PROFILE), and LOGS a folder of more dive logs for the
// Dive Logs page's list.
const _part = String.fromEnvironment('PART');
const _photo = String.fromEnvironment('PHOTO');
const _logs = String.fromEnvironment('LOGS');
const _logo = String.fromEnvironment('LOGO');
// The colour profile of the 'photo' part; the app's default when empty.
const _profile = String.fromEnvironment('PROFILE');

final _shot = GlobalKey();

Future<void> _png(ui.Image image, String name) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(p.join(_out, name)).writeAsBytesSync(bytes!.buffer.asUint8List());
}

// The frame under [_shot] as a PNG, two pixels a point (or [ratio]). The texts of
// [hide] (a tank sensor's serial number) are painted over with the colour
// beside them.
Future<void> _screen(
  WidgetTester tester,
  String name, {
  List<String> hide = const [],
  double ratio = 2.0,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shot),
  );
  var image = await boundary.toImage(pixelRatio: ratio);
  final covered = [
    for (final text in hide)
      for (final element in find.text(text).evaluate())
        if (element.renderObject case final RenderBox box)
          (box.localToGlobal(Offset.zero, ancestor: boundary) & box.size)
              .inflate(2),
  ];
  if (covered.isNotEmpty) {
    final pixels = (await image.toByteData())!;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawImage(image, Offset.zero, Paint());
    for (final rect in covered) {
      // The colour just left of the text.
      final x = ((rect.left - 4) * ratio).round().clamp(0, image.width - 1);
      final y = (rect.center.dy * ratio).round().clamp(0, image.height - 1);
      final at = (y * image.width + x) * 4;
      canvas.drawRect(
        Rect.fromLTRB(
          rect.left * ratio,
          rect.top * ratio,
          rect.right * ratio,
          rect.bottom * ratio,
        ),
        Paint()
          ..color = Color.fromARGB(
            255,
            pixels.getUint8(at),
            pixels.getUint8(at + 1),
            pixels.getUint8(at + 2),
          ),
      );
    }
    final masked = await recorder.endRecording().toImage(
      image.width,
      image.height,
    );
    image.dispose();
    image = masked;
  }
  await _png(image, name);
  image.dispose();
}

// [image] no wider than [width], as a PNG.
Future<void> _picture(ui.Image image, String name, {int width = 1600}) async {
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

// The left half of [before] and the right half of [after] in one picture
// of [width] by [height], each filling it, with a line between them and
// what each half is said in its lower corner.
Future<void> _halves(
  ui.Image before,
  ui.Image after,
  String name, {
  int width = 2560,
  int height = 1600,
  bool labelsByTheLine = false,
}) async {
  final size = Size(width.toDouble(), height.toDouble());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  void fill(ui.Image image, Rect part) {
    // The middle of the picture, in the shape of the whole.
    final scale = [
      size.width / image.width,
      size.height / image.height,
    ].reduce((a, b) => a > b ? a : b);
    final shown = Size(size.width / scale, size.height / scale);
    final from = Offset(
      (image.width - shown.width) / 2,
      (image.height - shown.height) / 2,
    );
    canvas
      ..save()
      ..clipRect(part)
      ..drawImageRect(
        image,
        from & shown,
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.high,
      )
      ..restore();
  }

  final half = size.width / 2;
  fill(before, Rect.fromLTWH(0, 0, half, size.height));
  fill(after, Rect.fromLTWH(half, 0, half, size.height));
  canvas.drawRect(
    Rect.fromLTWH(half - 3, 0, 6, size.height),
    Paint()..color = Colors.white,
  );
  void label(String text, {required bool left}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 44,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const pad = 28.0;
    final box = Size(painter.width + pad * 2, painter.height + pad);
    // In the lower corners, or beside the line where the corners hold
    // something (an overlay).
    final at = labelsByTheLine
        ? Offset(left ? half - 30 - box.width : half + 30, size.height - 150)
        : Offset(
            left ? 60 : size.width - 60 - box.width,
            size.height - 60 - box.height,
          );
    canvas.drawRRect(
      RRect.fromRectAndRadius(at & box, const Radius.circular(18)),
      Paint()..color = const Color(0xB3000000),
    );
    painter.paint(canvas, at + const Offset(pad, pad / 2));
  }

  label('As shot', left: true);
  label('Colour corrected', left: false);
  final image = await recorder.endRecording().toImage(width, height);
  await _png(image, name);
  image.dispose();
}

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: 'waited 60 s');
  await tester.pump(const Duration(milliseconds: 300));
}

// The drawing has caught up with what was just asked for.
Future<void> _settle(WidgetTester tester, {int seconds = 2}) async {
  await tester.pump(Duration(seconds: seconds));
  await Future<void>.delayed(Duration(seconds: seconds));
  await tester.pump(const Duration(milliseconds: 300));
}

// The page's controller, once the page has made it.
Future<T> _controller<T extends Object>(WidgetTester tester, Type page) async {
  await _wait(tester, () => find.byType(page).evaluate().isNotEmpty);
  T? made() =>
      // ignore: avoid_dynamic_calls
      (tester.state(find.byType(page)) as dynamic).controller as T?;
  await _wait(tester, () => made() != null);
  return made()!;
}

// A step of the app that never ends fails the run instead of hanging it.
const _patience = Duration(seconds: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the pictures of the website', (tester) async {
    // A window that another one covers is not drawn, and a pump then
    // waits for a frame that never comes: the test's window stays on top
    // while it runs (it takes no keyboard focus).
    await windowManager.ensureInitialized();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setVisibleOnAllWorkspaces(true);
    await windowManager.show(inactive: true);

    final tmp = Directory.systemTemp.createTempSync('uwmedia_shots_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory(_out).createSync(recursive: true);
    final source = Directory(p.join(tmp.path, 'Dive videos'))..createSync();
    final video = p.join(source.path, p.basename(_media));
    Link(video).createSync(_media);
    final logs = Directory(p.join(tmp.path, 'Dive logs'))..createSync();
    final log = File(_log).copySync(p.join(logs.path, p.basename(_log))).path;

    AppServices services(
      String name, {
      required bool desktop,
      bool store = false,
    }) {
      // The app's own folders, where a Mac has them.
      final root = p.join(tmp.path, 'Library', 'Application Support', name);
      final made = AppServices(
        capabilities: desktop
            ? Capabilities(
                desktop: true,
                nativeVideo: true,
                externalTools: !store,
              )
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
        dataDir: () => Directory(root),
      );
      // The dive log, kept as the Dive Logs page keeps it.
      final kept = made.logStore.folder..createSync(recursive: true);
      File(_log).copySync(p.join(kept.path, p.basename(_log)));
      made.watermarks.addText('© UWMedia');
      return made;
    }

    // The two tank sensors named, as on the Settings page: an overlay
    // shows the names, not the sensors' serial numbers.
    final serials = <String>{};
    Future<void> nameTanks(AppServices made) async {
      final names = TankNamesEditor(config: made.config)..open();
      await names.readKept(made.logStore.folder.path);
      for (final (i, row) in names.rows.indexed) {
        names.setName(row.serial, i == 0 ? 'Left' : 'Right');
        serials.add(row.serial);
      }
      expect(names.save(), isNotNull);
      names.dispose();
    }

    // The app's window, [size] points, with a phone's status bar and home
    // line left free when [insets] says so.
    Future<void> show(
      AppServices made,
      Size size, {
      EdgeInsets insets = EdgeInsets.zero,
    }) async {
      await tester.pumpWidget(const SizedBox());
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
                    data: MediaQueryData(size: size, padding: insets),
                    child: AppShell(key: UniqueKey(), services: made),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // The Color page on the video, at a frame some way in, the dive found.
    Future<ColorController> color(WidgetTester tester) async {
      final c = await _controller<ColorController>(tester, ColorPage);
      await c.setSource(source.path);
      await _wait(tester, () => c.previewImage != null && c.scrubEnabled);
      await c.scrubTo((c.scrubMaximum * 0.35).round());
      await _wait(tester, () => c.matchedDive != null);
      return c;
    }

    // The overlay of [brand]'s [computer] added, [size] times as large as
    // it comes, its lower left corner staying where it is.
    Future<void> overlay(
      ColorController c,
      String brand,
      String computer, {
      double size = 1,
    }) async {
      c.picker
        ..reset()
        ..selectBrand(brand)
        ..selectComputer(computer)
        ..selectPage('main')
        ..selectVariant('sidemount');
      expect(await c.addPickedOverlay().timeout(_patience), isTrue);
      await _settle(tester);
      if (size != 1) {
        // As a person does it: the upper right handle dragged.
        // (pressed first, which selects it and shows the handles).
        final (x0, y0, x1, y1) = c.boxOf(c.overlays.last)!;
        c.pressAt((x0 + x1) / 2, (y0 + y1) / 2, 1);
        await c.release().timeout(_patience);
        c
          ..pressAt(x1.toDouble(), y0.toDouble(), 1)
          ..dragTo(x0 + (x1 - x0) * size, y1 - (y1 - y0) * size);
        await c.release().timeout(_patience);
        await _settle(tester);
      }
      // Nothing selected: no frame around the overlay.
      c.pressAt(-10, -10, 1);
      await c.release().timeout(_patience);
      await tester.pump(const Duration(milliseconds: 500));
    }

    if (_part.isEmpty || _part == 'computer') {
      // -- the computer: the frame with an overlay ------------------------
      const window = Size(1280, 860);
      final computer = services('computer', desktop: true);
      await nameTanks(computer);
      await show(computer, window);
      final c = await color(tester);
      c.colorChecked = true;
      await _wait(tester, () => c.previewImage != null);
      await _settle(tester);

      await overlay(c, 'garmin', 'x50i');
      await _picture(
        c.previewImage!,
        'frame-overlay-garmin-x50i-sidemount.png',
      );
      await c.removeOverlayAt(0);
      await _settle(tester, seconds: 1);
      await overlay(c, 'shearwater', 'perdix_3', size: 0.6);
      await _picture(
        c.previewImage!,
        'frame-overlay-shearwater-perdix3-sidemount.png',
      );

      // -- the computer: three pages --------------------------------------
      computer.pageAsked.value = 'Overlay Generator';
      final generator = await _controller<OverlayGeneratorController>(
        tester,
        OverlayGeneratorPage,
      );
      generator
        ..setSource(source.path)
        ..setOutput(p.join(tmp.path, 'Overlays'));
      for (final (brand, model) in [
        ('garmin', 'x50i'),
        ('shearwater', 'perdix_3'),
      ]) {
        generator.selectBrand(brand);
        generator.picker
          ..selectComputer(model)
          ..selectPage('main')
          ..selectVariant('sidemount');
        await generator.addOverlay();
      }
      await _settle(tester);
      await _screen(tester, 'desktop-overlay-generator.png');

      computer.pageAsked.value = 'Log Viewer';
      final viewer = await _controller<LogViewerController>(
        tester,
        LogViewerPage,
      );
      await viewer.addFiles([log]);
      await _wait(tester, () => viewer.diveCount > 0);
      viewer.select(0);
      await _wait(tester, () => viewer.selected != null);
      await _settle(tester);
      await _screen(tester, 'desktop-log-viewer.png', hide: [...serials]);

      computer.pageAsked.value = 'Overlay Designer';
      final designer = await _controller<DesignerController>(
        tester,
        OverlayDesignerPage,
      );
      await designer.selectBrand('garmin');
      await designer.selectComputer('mk3i');
      await designer.selectPage('main');
      await _wait(tester, () => designer.hasDocument);
      await _settle(tester, seconds: 3);
      await _screen(tester, 'desktop-overlay-designer-garmin-mk3i.png');
    }

    // -- the Mac App Store: five screenshots ----------------------------
    if (_part == 'store') {
      final mac = services('store', desktop: true, store: true);
      await nameTanks(mac);
      await show(mac, const Size(1280, 800));
      final c = await color(tester);
      c.colorChecked = true;
      await _wait(tester, () => c.previewImage != null);
      await _settle(tester);
      await overlay(c, 'garmin', 'x50i');
      await _screen(tester, 'mac-store-1-color.png');

      mac.pageAsked.value = 'Overlay Generator';
      final generator = await _controller<OverlayGeneratorController>(
        tester,
        OverlayGeneratorPage,
      );
      generator
        ..setSource(source.path)
        ..setOutput(p.join(tmp.path, 'Overlays'));
      for (final (brand, model) in [
        ('garmin', 'x50i'),
        ('shearwater', 'perdix_3'),
      ]) {
        generator.selectBrand(brand);
        generator.picker
          ..selectComputer(model)
          ..selectPage('main')
          ..selectVariant('sidemount');
        await generator.addOverlay();
      }
      await _settle(tester);
      await _screen(tester, 'mac-store-2-overlay-generator.png');

      mac.pageAsked.value = 'Overlay Designer';
      final designer = await _controller<DesignerController>(
        tester,
        OverlayDesignerPage,
      );
      await designer.selectBrand('garmin');
      await designer.selectComputer('mk3i');
      await designer.selectPage('main');
      await _wait(tester, () => designer.hasDocument);
      await _settle(tester, seconds: 3);
      await _screen(tester, 'mac-store-3-overlay-designer.png');

      mac.pageAsked.value = 'Log Viewer';
      final viewer = await _controller<LogViewerController>(
        tester,
        LogViewerPage,
      );
      await viewer.addFiles([log]);
      await _wait(tester, () => viewer.diveCount > 0);
      viewer.select(0);
      await _wait(tester, () => viewer.selected != null);
      await _settle(tester);
      await _screen(tester, 'mac-store-4-log-viewer.png', hide: [...serials]);

      mac.pageAsked.value = 'Resize';
      final resize = await _controller<ConvertionController>(
        tester,
        ConvertionPage,
      );
      await resize.chooseSource(video).timeout(_patience);
      resize
        ..setChecked(resize.resolutionNames.first, true)
        ..setShareChecked(shareKeys.first, true);
      await _settle(tester);
      await _screen(tester, 'mac-store-5-resize.png');
      await tester.pumpWidget(const SizedBox());
    }

    // -- a photo before and after the colour correction ------------------
    if (_part == 'photo') {
      final photos = Directory(p.join(tmp.path, 'Dive photos'))..createSync();
      Link(p.join(photos.path, p.basename(_photo))).createSync(_photo);
      final mac = services('photo', desktop: true);
      await show(mac, const Size(1280, 800));
      final c = await _controller<ColorController>(tester, ColorPage);
      await c.setSource(photos.path);
      await _wait(tester, () => c.previewImage != null);
      await _settle(tester);
      final before = c.originalImage!.clone();
      if (_profile.isNotEmpty) c.colorProfile = _profile;
      c.colorChecked = true;
      await _wait(tester, () => c.previewImage != null);
      await _settle(tester, seconds: 3);
      final after = c.previewImage!.clone();
      await _picture(before, 'photo-original.png');
      await _picture(after, 'photo-corrected.png');
      await _halves(before, after, 'photo-before-after.png');
      debugPrint('photo: ${before.width} x ${before.height}');
      before.dispose();
      after.dispose();
      await tester.pumpWidget(const SizedBox());
    }

    // -- the Mac App Store: the Color page with seven overlays -----------
    if (_part == 'store-overlays') {
      final photos = Directory(p.join(tmp.path, 'Dive photos'))..createSync();
      Link(p.join(photos.path, p.basename(_photo))).createSync(_photo);
      final mac = services('store-overlays', desktop: true, store: true);
      final logo = _logo.isEmpty ? null : mac.watermarks.addPicture(_logo);
      await nameTanks(mac);
      await show(mac, const Size(1280, 800));
      final c = await _controller<ColorController>(tester, ColorPage);
      await c.setSource(photos.path);
      c.colorChecked = true;
      if (_profile.isNotEmpty) c.colorProfile = _profile;
      await _wait(tester, () => c.previewImage != null);
      await _wait(tester, () => c.matchedDive != null);
      if (logo != null) {
        c.setWatermark(logo.name, true);
        await _settle(tester);
      }
      final frame = c.previewImage!;
      final (w, h) = (frame.width.toDouble(), frame.height.toDouble());
      if (logo != null) {
        // The logo from its corner, lower right, to the upper left one.
        c
          ..pressAt(w * 0.93, h * 0.9, 1)
          ..dragTo(w * 0.11, h * 0.17);
        await c.release().timeout(_patience);
        await _settle(tester, seconds: 1);
      }
      // Each overlay with where its middle goes, as parts of the picture.
      for (final (brand, computer, page, x, y) in [
        ('shearwater', 'perdix_2', 'main', 0.5, 0.2),
        ('garmin', 'x50i', 'main', 0.83, 0.18),
        ('shearwater', 'peregrine', 'main', 0.15, 0.46),
        ('shearwater', 'perdix_3', 'main', 0.15, 0.77),
        ('generic', 'simple', 'box_dark', 0.84, 0.43),
        ('shearwater', 'petrel', 'main', 0.84, 0.73),
        ('generic', 'simple', 'row_dark', 0.52, 0.95),
      ]) {
        c.picker
          ..reset()
          ..selectBrand(brand)
          ..selectComputer(computer)
          ..selectPage(page);
        if (c.picker.variantChoices.values.contains('sidemount')) {
          c.picker.selectVariant('sidemount');
        }
        expect(await c.addPickedOverlay().timeout(_patience), isTrue);
        await _settle(tester);
        final (x0, y0, x1, y1) = c.boxOf(c.overlays.last)!;
        final (cx, cy) = ((x0 + x1) / 2, (y0 + y1) / 2);
        c
          ..pressAt(cx, cy, 1)
          ..dragTo(w * x, h * y);
        await c.release().timeout(_patience);
        await _settle(tester, seconds: 1);
      }
      // Nothing selected: no frame around an overlay.
      c.pressAt(-10, -10, 1);
      await c.release().timeout(_patience);
      await _settle(tester, seconds: 3);
      await _screen(tester, 'mac-store-2-overlays.png', hide: [...serials]);
      await tester.pumpWidget(const SizedBox());
    }

    // -- a photo before and after, an overlay in each corner -------------
    if (_part == 'photo-overlays') {
      final photos = Directory(p.join(tmp.path, 'Dive photos'))..createSync();
      Link(p.join(photos.path, p.basename(_photo))).createSync(_photo);
      final mac = services('photo-overlays', desktop: true);
      await nameTanks(mac);
      await show(mac, const Size(1280, 800));
      final c = await _controller<ColorController>(tester, ColorPage);
      await c.setSource(photos.path);
      await _wait(tester, () => c.previewImage != null);
      await _wait(tester, () => c.matchedDive != null);
      final frame = c.previewImage!;
      final (w, h) = (frame.width.toDouble(), frame.height.toDouble());
      // What the picture's shape cuts off the top and the bottom, and a
      // margin inside that.
      final cut = math.max(0, (h - w * 1600 / 2560) / 2);
      final (side, edge) = (w * 0.025, cut + w * 0.025);
      for (final (brand, computer, page, variant, right, low) in [
        ('garmin', 'x50i', 'main', 'sidemount', false, false),
        ('shearwater', 'perdix_2', 'main', null, true, false),
        ('shearwater', 'perdix_3', 'main', null, false, true),
        ('generic', 'depth_temp', 'standard', null, true, true),
      ]) {
        c.picker
          ..reset()
          ..selectBrand(brand)
          ..selectComputer(computer)
          ..selectPage(page);
        if (variant != null) {
          c.picker.selectVariant(variant);
        }
        expect(await c.addPickedOverlay().timeout(_patience), isTrue);
        await _settle(tester);
        // Dragged into its corner, as a person does it.
        final (x0, y0, x1, y1) = c.boxOf(c.overlays.last)!;
        final (cx, cy) = ((x0 + x1) / 2, (y0 + y1) / 2);
        c
          ..pressAt(cx, cy, 1)
          ..dragTo(
            cx + (right ? w - side - x1 : side - x0),
            cy + (low ? h - edge - y1 : edge - y0),
          );
        await c.release().timeout(_patience);
        await _settle(tester, seconds: 1);
      }
      // Nothing selected: no frame around an overlay.
      c.pressAt(-10, -10, 1);
      await c.release().timeout(_patience);
      await _settle(tester);
      final before = c.previewImage!.clone();
      c.colorChecked = true;
      if (_profile.isNotEmpty) c.colorProfile = _profile;
      await _wait(tester, () => c.previewImage != null);
      await _settle(tester, seconds: 3);
      final after = c.previewImage!.clone();
      await _halves(
        before,
        after,
        'photo-overlays-before-after.png',
        labelsByTheLine: true,
      );
      before.dispose();
      after.dispose();
      await tester.pumpWidget(const SizedBox());
    }

    // -- the iPhone App Store: five screenshots --------------------------
    if (_part == 'iphone-store') {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        Future<void> shot(String name) =>
            _screen(tester, name, ratio: 3, hide: [...serials]);
        Future<void> toPreview() async {
          await Scrollable.ensureVisible(
            tester.element(find.text('Live preview')),
          );
          await _settle(tester, seconds: 1);
        }

        final phone = services('iphone-store', desktop: false);
        await nameTanks(phone);
        await show(
          phone,
          const Size(440, 956),
          insets: const EdgeInsets.only(top: 62, bottom: 34),
        );
        final c = await color(tester);
        c.colorChecked = true;
        await _wait(tester, () => c.previewImage != null);
        await _settle(tester);
        await overlay(c, 'garmin', 'x50i');
        await toPreview();
        await shot('iphone-store-1-color-overlay.png');

        // The same cut to a portrait picture, the window on the diver.
        c
          ..pictureShape = ShareShape.portraitCropped
          ..setCrop(at: 0.28);
        await _settle(tester);
        await toPreview();
        await shot('iphone-store-2-portrait.png');
        c.pictureShape = ShareShape.values.first;
        await c.removeOverlayAt(0);
        await _settle(tester, seconds: 1);

        // A photo, corrected.
        if (_photo.isNotEmpty) {
          final photos = Directory(p.join(tmp.path, 'Dive photos'))
            ..createSync();
          Link(p.join(photos.path, p.basename(_photo))).createSync(_photo);
          await c.setSource(photos.path);
          if (_profile.isNotEmpty) c.colorProfile = _profile;
          await _wait(tester, () => c.previewImage != null);
          await _settle(tester, seconds: 3);
          await toPreview();
          await shot('iphone-store-3-photo.png');
        }

        // The Dive Logs page, with more logs than the one.
        if (_logs.isNotEmpty) {
          for (final file in Directory(_logs).listSync().whereType<File>()) {
            if (p.extension(file.path).toLowerCase() == '.fit') {
              file.copySync(
                p.join(phone.logStore.folder.path, p.basename(file.path)),
              );
            }
          }
        }
        phone.pageAsked.value = diveLogsTitle;
        await _settle(tester, seconds: 8);
        await shot('iphone-store-4-dive-logs.png');

        phone.pageAsked.value = 'Resize';
        final resize = await _controller<ConvertionController>(
          tester,
          ConvertionPage,
        );
        await resize.chooseSource(video).timeout(_patience);
        resize
          ..setChecked(resize.resolutionNames.first, true)
          ..setShareChecked(shareKeys.first, true);
        await _settle(tester);
        await shot('iphone-store-5-resize.png');
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    // -- the phones -----------------------------------------------------
    for (final (name, platform, size, insets) in [
      if (_part.isEmpty || _part == 'phones') ...[
        (
          'iphone',
          TargetPlatform.iOS,
          const Size(393, 852),
          const EdgeInsets.only(top: 47, bottom: 34),
        ),
        (
          'android',
          TargetPlatform.android,
          const Size(412, 915),
          const EdgeInsets.only(top: 32, bottom: 24),
        ),
      ],
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final phone = services(name, desktop: false);
        await nameTanks(phone);
        await show(phone, size, insets: insets);
        final c = await color(tester);
        c.colorChecked = true;
        await _wait(tester, () => c.previewImage != null);
        await _settle(tester);
        await _screen(tester, '$name-color.png');

        // The same, cut to a portrait picture, with the dive's overlay.
        // The window moved left, onto the diver.
        c
          ..pictureShape = ShareShape.portraitCropped
          ..setCrop(at: 0.28);
        await _settle(tester);
        // 2.2 times the template's own size, as before the overlay
        // started at its true size (spec §10.100): 2.2 / 1.2316.
        await overlay(c, 'garmin', 'x50i', size: 1.786);
        // The preview at the top of the screen, the whole picture seen.
        await Scrollable.ensureVisible(
          tester.element(find.text('Live preview')),
        );
        await _settle(tester, seconds: 1);
        await _screen(tester, '$name-color-overlay-portrait.png');

        phone.pageAsked.value = 'Resize';
        final resize = await _controller<ConvertionController>(
          tester,
          ConvertionPage,
        );
        await resize.chooseSource(video).timeout(_patience);
        // A smaller copy and one to send to a phone asked for.
        resize
          ..setChecked(resize.resolutionNames.first, true)
          ..setShareChecked(shareKeys.first, true);
        await _settle(tester);
        await _screen(tester, '$name-resize.png');
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });
}
