// The Overlay Designer (lib/pages/overlay_designer/) on the bundled
// template tree, the repo's fonts and a temporary user folder: the
// cascade, selection and the inspector's rules, structural edits with undo
// and redo, alignment, the clipboard, drags with the marquee, zoom, the
// dummy telemetry, and saving (read-only bundled pages, Save as, Save,
// Revert and a new custom page). The rules follow the Python app's
// tests/test_overlay_designer_backend.py.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/app_paths.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/template_store.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/template_import.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';
import 'package:uwmedia_app/pages/overlay_designer/designer_controller.dart';
import 'package:uwmedia_app/pages/overlay_designer/overlay_designer_page.dart';

HudKit _kit() {
  final fonts = TtfFonts(
    (file) => File('assets/fonts/$file').readAsBytesSync(),
    inkTables: InkTables.parse(
      File('assets/fonts/ink_tables.bin').readAsBytesSync(),
    ),
  );
  final rules = HudRules(
    jsonDecode(File('assets/hud_rules.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  return HudKit(HudRenderer(fonts, rules), HudPainter(fonts));
}

// A made-up ffmpeg: a 10 fps, 100-frame, 640 x 360 clip of one grey.
class FakeMedia implements DesignerMedia {
  final frames = <double>[];

  @override
  Future<MediaTags?> metadata(String path) async => const {};

  @override
  Future<({double fps, int frames})> videoFacts(String path) async =>
      (fps: 10.0, frames: 100);

  @override
  Future<(int, int)> dimensions(String path) async => (640, 360);

  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds,
    int width,
    int height,
  ) async {
    frames.add(seconds);
    return RgbImage(
      width,
      height,
      Uint8List(width * height * 3)..fillRange(0, width * height * 3, 90),
    );
  }
}

// The made-up UDDF dive of the parser fixture.
Uint8List _uddf() => base64.decode(
  ((jsonDecode(
                File('test/fixtures/python_reference/dives/uddf.json')
                    .readAsStringSync(),
              ) as Map<String, dynamic>)['parse']
              as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .first['bytes_base64']
      as String,
);

// File dialogs that answer with what the test set.
class FakeDialogs implements DesignerDialogs {
  String? logFile;

  @override
  Future<String?> pickImage(String initialDirectory) async => null;
  @override
  Future<String?> pickMedia(String initialDirectory) async => null;
  @override
  Future<String?> pickLogFile(String initialDirectory) async => logFile;
  @override
  Future<String?> pickFolder(String initialDirectory) async => null;
  @override
  Future<String?> pickZip(String initialDirectory) async => null;
  @override
  Future<String?> saveZip(String initialDirectory, String name) async => null;
}

// The test's controller, let go of after each test.
DesignerController? _current;
DesignerController get c => _current!;
set c(DesignerController value) => _current = value;

void main() {
  final kit = _kit();
  late Directory tmp;
  late String userRoot;

  var templatesChanged = 0;

  Future<DesignerController> make({
    Dive? dive,
    DesignerMedia? media,
    String? checkout,
  }) async {
    final made = DesignerController(
      checkout: checkout != null,
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
      kit: kit,
      loadFolders: () async => (
        DiskTemplateFolder(checkout ?? bundledTemplatesRoot) as TemplateFolder,
        DiskTemplateFolder(userRoot) as TemplateFolder,
      ),
      onTemplatesChanged: () => templatesChanged++,
      media: media == null ? null : () async => media,
      tempDir: (prefix) => tmp.createTempSync(prefix),
      templateBytes: (path) async {
        final file = File(path);
        return file.existsSync() ? file.readAsBytesSync() : null;
      },
    );
    made.currentDive = dive;
    await made.start();
    return made;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('uwmedia_designer_');
    userRoot = p.join(tmp.path, 'templates');
  });

  tearDown(() {
    _current?.dispose();
    _current = null;
    tmp.deleteSync(recursive: true);
  });

  Future<void> pick(String brand, String computer, String page) async {
    await c.selectBrand(brand);
    await c.selectComputer(computer);
    await c.selectPage(page);
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    DesignerDialogs dialogs = const SystemDesignerDialogs(),
    bool settle = true,
  }) async {
    await tester.runAsync(() async {
      c = await make();
      await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    });
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
    );
    final controller = c;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: OverlayDesignerPage(
              services: services,
              dialogs: dialogs,
              setup: (_) async => controller,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    // The page as it is first seen: its first frame's follow-ups (the
    // zoom percent after Fit, the scroll bars) are through before a test
    // taps anything, as they are long before a user can.
    if (settle) {
      await tester.pumpAndSettle();
    }
  }

  test('the cascade loads a bundled page, read-only', () async {
    c = await make();
    expect(c.brandChoices.values, containsAll(['garmin', 'shearwater']));
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    expect(c.hasDocument, isTrue);
    expect(c.pageOrigin, originBundled);
    expect(c.canSave, isFalse);
    expect(c.readOnlyHint, contains('read-only'));
    expect(c.elementRows, isNotEmpty);
    expect(c.selectedVariant, 'single_tank');
    expect(c.elementBoxes, hasLength(c.elementRows.length));
    expect(await c.save(), isFalse);
  });

  test('selection, the inspector and undo', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    final doc = c.document!;
    final depth = c.elementRows.indexWhere((r) => r.field == 'depth');
    expect(depth, isNot(-1));
    c.selectElement(depth);
    expect(c.selectedElement['index'], depth);
    expect(c.selectedElement['field'], 'depth');

    c.setSelectedAttr('x_px', '42');
    expect(c.selectedElement['x_px'], 42.0);
    expect(c.isDirty, isTrue);
    c.setSelectedAttr('font_size', 'abc');
    expect(doc.elements[depth]['font_size'], isNot('abc'));
    c.setSelectedAttr('font_size', '0');
    expect(doc.elements[depth]['font_size'], 1);
    // A default is the key's absence.
    c.setSelectedAttr('align', 'center');
    expect(doc.elements[depth]['align'], 'center');
    c.setSelectedAttr('align', 'left');
    expect(doc.elements[depth].containsKey('align'), isFalse);
    c.setSelectedAttr('bold', true);
    expect(doc.elements[depth]['font_weight'], 'bold');
    c.setSelectedAttr('bold', false);
    expect(doc.elements[depth].containsKey('font_weight'), isFalse);

    while (c.canUndo) {
      c.undo();
    }
    expect(c.isDirty, isFalse);
    expect(c.canRedo, isTrue);
    c.redo();
    expect(c.isDirty, isTrue);
  });

  test('add, duplicate, copy, paste, remove and reorder', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    final count = c.elementRows.length;
    c.addElement('depth_small_decimals', 'text');
    expect(c.elementRows, hasLength(count + 1));
    expect(c.selectedIndex, count);
    expect(c.selectedElement['field'], 'depth');
    expect(c.selectedElement['small_suffix'], 'decimals');

    c.addElement('anything', 'graph');
    expect(c.selectedElement['field'], 'depth_graph');
    expect(c.selectedElement['kind'], 'graph');

    c.duplicateSelected();
    expect(c.elementRows, hasLength(count + 3));
    c.copySelected();
    c.paste();
    expect(c.elementRows, hasLength(count + 4));
    c.removeSelected();
    expect(c.elementRows, hasLength(count + 3));

    c.selectElement(0);
    c.bringToFront();
    expect(c.selectedIndex, count + 2);
    c.sendToBack();
    expect(c.selectedIndex, 0);

    c.addCustomLabel('  NDL ');
    expect(c.selectedElement['is_custom'], isTrue);
    expect(c.selectedElement['custom_text'], 'NDL');
  });

  test('align and distribute move the boxes', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    for (final _ in [0, 1, 2]) {
      c.addCustomLabel('X');
    }
    final n = c.elementRows.length;
    c
      ..selectElement(n - 3)
      ..setSelectedAttr('x_px', '10')
      ..selectElement(n - 2)
      ..setSelectedAttr('x_px', '50')
      ..selectElement(n - 1)
      ..setSelectedAttr('x_px', '200');
    c
      ..selectElement(n - 3)
      ..toggleElement(n - 2)
      ..toggleElement(n - 1);
    expect(c.selectionCount, 3);
    // Aligned to the primary (the last clicked) element.
    c.alignSelected('left');
    final lefts = {
      for (final i in [n - 3, n - 2, n - 1]) c.elementBoxes[i].$1,
    };
    expect(lefts, hasLength(1));
  });

  test('a press selects, a drag moves, a marquee picks', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    c.setViewportSize(800, 400);
    final box = c.elementBoxes.first;
    final x = box.$1 + box.$3 / 2;
    final y = box.$2 + box.$4 / 2;
    c.press(x, y);
    expect(c.selectedIndex, isNot(-1));
    final picked = c.selectedIndex;
    final before = c.elementBoxes[picked];
    c
      ..drag(x + 20, y + 10)
      ..release();
    expect(c.elementBoxes[picked].$1, closeTo(before.$1 + 20, 1.5));
    expect(c.canUndo, isTrue);

    // Off every element, in Design view: a marquee over the whole skin.
    c
      ..press(-5, -5)
      ..drag(c.canvasDisplayWidth + 5.0, c.canvasDisplayHeight + 5.0)
      ..release();
    expect(c.selectionCount, c.elementRows.length);
  });

  test('zoom steps and Fit', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    expect(c.zoomIsFit, isTrue);
    c.setZoomPercent(100);
    expect(c.zoom, 1.0);
    c.zoomIn();
    expect(c.zoom, 1.25);
    c.zoomOut();
    expect(c.zoom, 1.0);
    c.setZoomPercent(1000);
    expect(c.zoom, zoomMax);
    c.zoomFit();
    expect(c.zoomIsFit, isTrue);
    c.setViewMode(viewFrame);
    expect(c.canvasDisplayWidth, lessThanOrEqualTo(700));
  });

  test('the dummy telemetry, a forced state and the page units', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    expect(c.timeEnabled, isTrue);
    expect(c.timeValue, dummyDefaultSeconds);
    expect(c.timeText, '0:12:00');
    expect(c.dataText, startsWith('Dummy telemetry · Depth '));
    expect(c.dataText, contains(' m '));
    c.selectUnits(UnitSystem.imperial);
    expect(c.units, UnitSystem.imperial);
    expect(c.dataText, contains(' ft '));
    c.unitsChanged();
    expect(c.units, UnitSystem.metric);
    c.onTimeChanged(60);
    expect(c.timeText, '0:01:00');
    c.selectState('deco');
    expect(c.stateOverride, 'deco');
    expect(c.dataText, contains('State: '));
  });

  test('Save as, Save and Revert in the user folder', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    final targets = c.saveAsTargets;
    expect(targets.last.computer, '');
    expect(
      await c.saveAs(c.saveAsCurrentTargetIndex, '', '  '),
      'Enter a page name.',
    );
    expect(await c.saveAs(c.saveAsCurrentTargetIndex, '', 'My page'), '');
    expect(c.pageOrigin, originUser);
    expect(c.selectedPage, 'my_page');
    expect(c.canSave, isTrue);
    final state = File(p.join(userRoot, 'shearwater', 'perdix_2', 'my_page'));
    expect(Directory(state.path).existsSync(), isTrue);
    // The skin came along.
    expect(
      Directory(state.path)
          .listSync(recursive: true)
          .any((f) => f.path.endsWith('.png')),
      isTrue,
    );

    c.selectElement(0);
    c.setSelectedAttr('x_px', '33');
    expect(await c.save(), isTrue);
    expect(c.isDirty, isFalse);
    expect(c.selectedIndex, 0);
    expect(c.selectedElement['x_px'], 33.0);

    c.setSelectedAttr('x_px', '99');
    await c.revert();
    expect(c.isDirty, isFalse);
    expect(c.selectedElement['x_px'], 33.0);
  });

  test('checkout mode saves a built-in page in place (spec §10.84)', () async {
    // A copy of one computer's bundled pages stands in for the checkout.
    final checkout = p.join(tmp.path, 'checkout');
    for (final f in Directory(
      p.join(bundledTemplatesRoot, 'shearwater', 'perdix_2'),
    ).listSync(recursive: true).whereType<File>()) {
      final to = p.join(
        checkout,
        p.relative(f.path, from: bundledTemplatesRoot),
      );
      Directory(p.dirname(to)).createSync(recursive: true);
      f.copySync(to);
    }
    c = await make(checkout: checkout);
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    // The status says why a page did not load (seen on Windows only).
    expect(c.pageOrigin, originBundled, reason: c.status);
    expect(c.canSave, isTrue);
    expect(c.readOnlyHint, isEmpty);
    expect(c.writeTargetText, contains('Checkout mode'));
    Map<String, String> states() => {
      for (final f in Directory(checkout).listSync(recursive: true))
        if (f is File && f.path.endsWith('.json')) f.path: f.readAsStringSync(),
    };
    final before = states();
    c.selectElement(0);
    c.setSelectedAttr('x_px', '33');
    expect(await c.save(), isTrue);
    // Written into the checkout's page, nothing into the user's folder.
    expect(Directory(userRoot).existsSync(), isFalse);
    final after = states();
    expect(after.keys, before.keys);
    expect([
      for (final path in after.keys)
        if (after[path] != before[path]) path,
    ], isNotEmpty);
    await c.revert();
    expect(c.selectedElement['x_px'], 33.0);
    // Save as a page id the bundled tree has: refused, as in Python.
    expect(
      await c.saveAs(c.saveAsCurrentTargetIndex, '', c.selectedPage!),
      contains('already exists'),
    );
  });

  test('checkout mode is off unless asked for, and needs a checkout', () {
    expect(checkoutTemplatesDir(), isNull);
    final repo = Directory(p.join(tmp.path, 'repo'));
    Directory(p.join(repo.path, 'assets', 'overlays', 'templates'))
        .createSync(recursive: true);
    File(p.join(repo.path, 'pubspec.yaml')).writeAsStringSync('name: x');
    final exe = p.join(repo.path, 'build', 'macos', 'App.app', 'uwmedia');
    // Not a git checkout: no.
    expect(checkoutTemplatesDir(asked: true, executable: exe), isNull);
    Directory(p.join(repo.path, '.git')).createSync();
    expect(
      checkoutTemplatesDir(asked: true, executable: exe),
      p.join(repo.path, 'assets', 'overlays', 'templates'),
    );
    expect(checkoutTemplatesDir(asked: false, executable: exe), isNull);
    // An installed app, outside any checkout.
    expect(
      checkoutTemplatesDir(
        asked: true,
        executable: p.join(tmp.path, 'Applications', 'uwmedia'),
      ),
      isNull,
    );
  });

  test('a new custom computer with a shape page', () async {
    c = await make();
    // test_create_custom_template_from_image_under_new_custom_computer
    expect(c.rulesProfiles, ['Default', 'Shearwater', 'Garmin', 'Suunto']);
    final error = await c.createCustomTemplate(
      targetIndex: c.saveAsTargets.length - 1,
      newComputerName: 'GoPro HUD',
      pageName: 'Main',
      backgroundKind: 'shape',
      shapeWidth: 300,
      shapeHeight: 120,
      shapeColor: '#112233',
    );
    expect(error, '');
    expect(c.selectedBrand, customBrand);
    expect(c.selectedComputer, 'gopro_hud');
    expect(c.selectedPage, 'main');
    expect(c.skinAttrs['type'], 'shape');
    expect(c.skinAttrs['width'], 300);
    expect(c.elementRows, isEmpty);
    expect(
      await c.createCustomTemplate(
        targetIndex: c.saveAsTargets.length - 1,
        newComputerName: '',
        pageName: 'Main',
        backgroundKind: 'shape',
      ),
      'Enter a name for the new computer.',
    );
  });

  testWidgets('on screen: pick, edit, add and save as', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late DesignerController made;
    await tester.runAsync(() async {
      made = c = await make();
      await pick('shearwater', 'perdix_2', made.pageChoices.values.first);
    });
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: OverlayDesignerPage(
              services: services,
              setup: (_) async => made,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    expect(find.textContaining('read-only'), findsOneWidget);
    expect(find.text('Skin and placement'), findsOneWidget);

    // An element from the list, then its X in the inspector.
    final row = c.elementRows.firstWhere((r) => r.field == 'depth');
    await tester.tap(find.byKey(ValueKey('element-${row.index}')));
    await tester.pump();
    expect(find.textContaining('Element · text'), findsOneWidget);
    final x = find.descendant(
      of: find.byKey(ValueKey('el:${row.index}:x_px')),
      matching: find.byType(TextField),
    );
    await tester.enterText(x, '120');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(c.selectedElement['x_px'], 120.0);
    expect(find.text('● Unsaved changes'), findsOneWidget);

    // A click on the element on the canvas, then keys: nudge and undo.
    final box = c.elementBoxes[row.index];
    await tester.tapAt(
      tester.getTopLeft(find.byKey(designerCanvasKey)) +
          Offset(box.$1 + box.$3 / 2, box.$2 + box.$4 / 2),
    );
    await tester.pump();
    expect(c.selectedIndex, row.index);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(c.selectedElement['x_px'], 121.0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(c.selectedElement['x_px'], 120.0);

    // + Add: a State badge.
    final count = c.elementRows.length;
    await tester.tap(find.text('+ Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('State badge'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(c.elementRows, hasLength(count + 1));
    expect(c.selectedElement['kind'], 'badge');

    // Save as a page of the user's.
    await tester.tap(find.text('Save as…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'e.g. My main screen'),
      'Mine',
    );
    await tester.pump();
    expect(find.textContaining('shearwater/perdix_2/mine'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      // Until the dialog's save is through.
      for (var i = 0; i < 200 && c.pageOrigin != originUser; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(c.pageOrigin, originUser);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('the canvas is drawn in both views', (tester) async {
    await tester.runAsync(() async {
      c = await make();
      await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
      await c.rendered;
      expect(c.status, isNot(contains('render error')));
      final design = c.canvasImage;
      expect(design, isNotNull);
      expect(design!.width, c.canvasDisplayWidth);
      // On a screen scaled to 150 %: drawn in its pixels, shown at the
      // same size.
      final shown = c.canvasDisplayWidth;
      expect(c.setPixelRatio(1.5), isTrue);
      expect(c.setPixelRatio(1.5), isFalse);
      c.viewportFitted();
      await c.rendered;
      expect(c.canvasDisplayWidth, shown);
      expect(c.canvasImage!.width, closeTo(shown * 1.5, 1));
      c.setViewMode(viewFrame);
      await c.rendered;
      expect(c.status, isNot(contains('render error')));
      expect(c.canvasImage!.width, frameW);
      expect(c.canvasImage!.height, frameH);
    });
  });

  testWidgets('a drag with the pointer moves the element', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    final row = c.elementRows.firstWhere((r) => r.field == 'depth');
    final box = c.elementBoxes[row.index];
    final origin = tester.getTopLeft(find.byKey(designerCanvasKey));
    final gesture = await tester.startGesture(
      origin + Offset(box.$1 + box.$3 / 2, box.$2 + box.$4 / 2),
    );
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(c.selectedIndex, row.index);
    expect(c.elementBoxes[row.index].$1, closeTo(box.$1 + 50, 1.5));
    expect(c.pressing, isFalse);
    expect(c.canUndo, isTrue);

    // A marquee from outside the skin picks what it covers.
    final size = tester.getSize(find.byKey(designerCanvasKey));
    final marquee = await tester.startGesture(origin + const Offset(1, 1));
    await tester.pump();
    await marquee.moveTo(origin + Offset(size.width - 1, size.height - 1));
    await tester.pump();
    expect(c.marqueeBox, isNotNull);
    await marquee.up();
    await tester.pump();
    expect(c.selectionCount, greaterThan(1));
  });

  testWidgets('a typed value stays with its element', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    final rows = c.elementRows;
    final a = rows.firstWhere((r) => r.field == 'depth').index;
    final b = rows.indexWhere((r) => r.index != a && r.kind == 'text');
    await tester.tap(find.byKey(ValueKey('element-$a')));
    await tester.pump();
    final bX = c.document!.elementPositionPx(b).$1;
    await tester.enterText(
      find.descendant(
        of: find.byKey(ValueKey('el:$a:x_px')),
        matching: find.byType(TextField),
      ),
      '77',
    );
    await tester.pump();
    // Another element picked before the field is left.
    await tester.tap(find.byKey(ValueKey('element-$b')));
    await tester.pump();
    expect(c.selectedIndex, b);
    expect(c.document!.elementPositionPx(a).$1, 77.0);
    expect(c.document!.elementPositionPx(b).$1, bX);
  });

  testWidgets('Fit is in place in the canvas\'s first frame', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester, settle: false);
    // Laid out at the fit zoom at once, not at the old zoom and resized a
    // frame later.
    final first = tester.getSize(find.byKey(designerCanvasKey));
    expect(c.zoomIsFit, isTrue);
    expect(
      first,
      Size(c.canvasDisplayWidth * 1.0, c.canvasDisplayHeight * 1.0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(designerCanvasKey)), first);
    expect(find.text('${c.zoomPercent}%'), findsOneWidget);
  });

  // Adding with nothing selected: the inspector swaps its hint for the new
  // element's form while the dialog closes.
  for (final kind in const [
    'Telemetry field',
    'Custom label',
    'State badge',
    'Tank icon',
    'Depth graph',
    'Tissue load bar',
    'Ascent chevrons',
    'Notice',
    'Tank switch arrows',
    'Arc gauge',
    'Segment bar',
  ]) {
    testWidgets('$kind from the dialog with nothing selected', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpPage(tester);
      expect(c.selectedIndex, -1);
      expect(find.textContaining('Click an element on the canvas'), findsOne);
      final count = c.elementRows.length;
      await tester.tap(find.text('+ Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kind));
      await tester.pump();
      if (kind == 'Custom label') {
        await tester.enterText(find.widgetWithText(TextField, 'Text'), 'NDL');
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(c.elementRows, hasLength(count + 1));
      expect(c.selectedIndex, isNot(-1));
      expect(
        find.textContaining('Click an element on the canvas'),
        findsNothing,
      );
      expect(find.textContaining('Element · '), findsOneWidget);
    });
  }

  // Python 0.8.0 AddElementPopup.qml and OverlayElementInspector.qml.
  testWidgets('an arc gauge and a segment bar from the dialog', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester);

    Future<void> add(String kind) async {
      await tester.ensureVisible(find.text('+ Add'));
      await tester.pump();
      await tester.tap(find.text('+ Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kind));
      await tester.pump();
    }

    Finder inDialog(Finder finder) =>
        find.descendant(of: find.byType(AlertDialog), matching: finder);

    Future<void> type(String attr, String text) async {
      await tester.enterText(
        find.descendant(
          of: find.byKey(ValueKey('el:${c.selectedIndex}:$attr')),
          matching: find.byType(TextField),
        ),
        text,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    // Nothing selected: the inspector goes from its hint to the new
    // element's form as the dialog closes.
    expect(c.selectedIndex, -1);

    // The arc: the field picker preset to the NDL, its help text.
    final count = c.elementRows.length;
    await add('Arc gauge');
    expect(inDialog(find.text('Field')), findsOneWidget);
    expect(inDialog(find.text('ndl')), findsOneWidget);
    expect(
      inDialog(find.textContaining('Arc gauge (Suunto EON style)')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(c.elementRows, hasLength(count + 1));
    expect(c.selectedElement['kind'], 'arc');
    expect(c.selectedElement['field'], 'ndl');

    // Its inspector: heading, field picker, Quick size, width and height,
    // and the Arc gauge section.
    expect(find.text('Element · arc'), findsOneWidget);
    expect(find.text('Quick size'), findsOneWidget);
    expect(find.byKey(ValueKey('el:${c.selectedIndex}:width')), findsOne);
    expect(find.byKey(ValueKey('el:${c.selectedIndex}:height')), findsOne);
    expect(find.text('▾  Arc gauge'), findsOneWidget);
    for (final attr in const ['thickness', 'start_angle', 'sweep']) {
      expect(find.byKey(ValueKey('el:${c.selectedIndex}:$attr')), findsOne);
    }
    expect(find.text('Colour by'), findsNothing);
    await type('range_max', '6000');
    await type('segments', '4');
    await type('segment_gap', '3');
    await type('sweep', '180');
    await type('track_color', '#112233');
    expect(c.selectedElement['range_max'], 6000);
    expect(c.selectedElement['segments'], 4);
    expect(c.selectedElement['segment_gap'], 3);
    expect(c.selectedElement['sweep'], 180);
    expect(c.selectedElement['track_color'], '#112233');
    final width = c.selectedElement['width']! as num;
    final grow = find.byTooltip('Grow width and height 5 % (or the + key)');
    await tester.ensureVisible(grow);
    await tester.pump();
    await tester.tap(grow);
    // Until its tooltip is gone again.
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(c.selectedElement['width']! as num, greaterThan(width));

    // The segment bar: preset to the ascent rate; Colour by, no angles.
    await add('Segment bar');
    expect(inDialog(find.text('ascent_rate')), findsOneWidget);
    expect(
      inDialog(find.textContaining('Vertical stack of segments')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(c.selectedElement['kind'], 'segment_bar');
    expect(c.selectedElement['field'], 'ascent_rate');
    expect(find.text('Element · segment bar'), findsOneWidget);
    expect(find.text('▾  Segment bar'), findsOneWidget);
    expect(find.byKey(ValueKey('el:${c.selectedIndex}:sweep')), findsNothing);
    await type('range_min', '1');
    await type('range_max', '10');
    await type('color', '#00c000');
    expect(c.selectedElement['range_min'], 1);
    expect(c.selectedElement['range_max'], 10);
    expect(c.selectedElement['color'], '#00C000');
    expect(c.selectedElement['color_mode'], 'value');
    await tester.ensureVisible(find.widgetWithText(TextButton, 'Place'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Place'));
    await tester.pump();
    expect(c.selectedElement['color_mode'], 'position');
    await tester.ensureVisible(find.widgetWithText(TextButton, 'Value'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Value'));
    await tester.pump();
    expect(c.selectedElement['color_mode'], 'value');
  });

  testWidgets("a text element's Box colour is set and cleared", (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    final row = c.elementRows.firstWhere((r) => r.field == 'depth');
    await tester.tap(find.byKey(ValueKey('element-${row.index}')));
    await tester.pump();
    expect(c.selectedElement['box_color'], '');
    expect(
      find.byTooltip(
        "A filled box behind the value (a Nautic's stop timer). Empty the "
        'field for none.',
      ),
      findsOneWidget,
    );
    final box = find.descendant(
      of: find.byKey(ValueKey('el:${row.index}:box_color')),
      matching: find.byType(TextField),
    );
    Future<void> type(String text) async {
      await tester.enterText(box, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    await type('#ffb000');
    expect(c.selectedElement['box_color'], '#FFB000');
    expect(c.document!.elements[row.index]['box_color'], '#FFB000');
    // Half a colour is not kept; an empty field takes the box away.
    await type('#FF');
    expect(c.selectedElement['box_color'], '#FFB000');
    await type('');
    expect(c.selectedElement['box_color'], '');
    expect(c.document!.elements[row.index].containsKey('box_color'), isFalse);
  });

  test('a later page choice wins over a slower load', () async {
    c = await make();
    await c.selectBrand('shearwater');
    await c.selectComputer('perdix_2');
    final pages = c.pageChoices.values.toList();
    await c.selectBrand('garmin');
    // Both loads start; the second one asked for is the one shown.
    final first = c.selectBrand('shearwater');
    final second = c.selectBrand('garmin');
    await Future.wait([first, second]);
    expect(c.selectedBrand, 'garmin');
    expect(c.document!.ref!.brand, 'garmin');
    expect(pages, isNotEmpty);
  });

  test('numbers that are not finite are not kept', () async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    c.selectElement(0);
    final before = c.selectedElement['x_px'];
    c
      ..setSelectedAttr('x_px', 'inf')
      ..setSelectedAttr('font_size', 'nan')
      ..setSelectedAttr('scale', '-inf');
    expect(c.selectedElement['x_px'], before);
    expect(c.isDirty, isFalse);
    c.selectSkin();
    c.setSkinAttr('scale', 'inf');
    expect(c.isDirty, isFalse);
  });

  // The cases below follow tests/test_overlay_designer_backend.py.

  Future<void> perdixAt100() async {
    c = await make();
    await pick('shearwater', 'perdix_2', c.pageChoices.values.first);
    c.setZoomPercent(100);
  }

  test('test_sidemount_dive_resolves_sidemount_variant', () async {
    c = await make(dive: buildDummyDive(variant: 'sidemount'));
    await pick('garmin', 'x50i', 'main');
    expect(c.document!.ref!.variant, 'sidemount');
    expect(c.elementRows.map((r) => r.field), contains('secondary_tank_name'));
  });

  test('test_inspector_attribute_edits_store_non_defaults_only', () async {
    await perdixAt100();
    c.selectElement(0);
    final elem = c.document!.elements[0];
    c
      ..setSelectedAttr('align', 'right')
      ..setSelectedAttr('valign', 'middle')
      ..setSelectedAttr('bold', true)
      ..setSelectedAttr('font_family', 'Roboto')
      ..setSelectedAttr('outline', true)
      ..setSelectedAttr('font_size', '90.4')
      ..setSelectedAttr('scale', '1.25')
      ..setSelectedAttr('color', '#00ADED');
    expect(elem['align'], 'right');
    expect(elem['valign'], 'middle');
    expect(elem['font_weight'], 'bold');
    expect(elem['font_family'], 'Roboto');
    expect(elem['outline'], true);
    expect(elem['font_size'], 90);
    expect(elem['scale'], 1.25);
    expect(elem['color'], '#00ADED');
    c
      ..setSelectedAttr('align', 'left')
      ..setSelectedAttr('valign', 'top')
      ..setSelectedAttr('bold', false)
      ..setSelectedAttr('font_family', 'Arial')
      ..setSelectedAttr('outline', false);
    for (final key in ['align', 'valign', 'font_weight', 'font_family']) {
      expect(elem.containsKey(key), isFalse, reason: key);
    }
    expect(elem.containsKey('outline'), isFalse);
    c.setSelectedAttr('align', 'diagonal');
    expect(elem.containsKey('align'), isFalse);
  });

  test('test_small_suffix_inspector_attribute_round_trip', () async {
    c = await make(); // mk3i main, single tank
    final diveTime = c.elementRows.firstWhere((r) => r.field == 'dive_time');
    c.selectElement(diveTime.index);
    final elem = c.document!.elements[diveTime.index];
    expect(c.selectedElement['small_suffix'], 'seconds');
    expect(c.selectedElement['small_suffix_scale'], 0.33);
    c.setSelectedAttr('small_suffix', '');
    expect(elem.containsKey('small_suffix'), isFalse);
    expect(c.selectedElement['small_suffix'], '');
    c.setSelectedAttr('small_suffix', 'bogus');
    expect(elem.containsKey('small_suffix'), isFalse);
    c
      ..setSelectedAttr('small_suffix', 'decimals')
      ..setSelectedAttr('small_suffix_scale', '5');
    expect(elem['small_suffix'], 'decimals');
    expect(elem['small_suffix_scale'], 1.0);
  });

  test(
    'test_skin_attr_edits_anchor_by_display_name_and_scale_refits',
    () async {
      await perdixAt100();
      c
        ..selectSkin()
        ..setSkinAttr('anchor', 'Top Right');
      expect(c.skinAttrs['anchor'], 'TOP_RIGHT');
      c.setSkinAttr('anchor', 'Nowhere');
      expect(c.skinAttrs['anchor'], 'TOP_RIGHT');
      c.setSkinAttr('opacity', '5');
      expect(c.skinAttrs['opacity'], 1.0);
      c.setSkinAttr('ref_offset_x', '-40');
      expect(c.skinAttrs['ref_offset_x'], -40.0);
      c.setSkinAttr('scale', '0.5');
      expect(c.skinAttrs['scale'], 0.5);
      expect(c.anchorChoices.keys.first, 'Top Left');
      expect(c.fontFamilies, contains('Roboto'));
    },
  );

  test('test_designer_adds_and_edits_gauges', () async {
    c = await make();
    await pick('garmin', 'x50i', c.pageChoices.values.first);
    c.addElement('primary_tank_pressure', 'arc');
    var sel = c.selectedElement;
    expect(sel['kind'], 'arc');
    expect(sel['field'], 'primary_tank_pressure');
    expect(sel['sweep'], 270);
    c
      ..setSelectedAttr('range_max', '250')
      ..setSelectedAttr('sweep', '180.4')
      ..setSelectedAttr('track_color', '#202020');
    final elem = c.document!.elements[sel['index'] as int];
    expect(
      [elem['range_max'], elem['sweep'], elem['track_color']],
      [250.0, 180, '#202020'],
    );
    final w = c.selectedElement['width'] as num;
    c.resizeSelected(1);
    expect(c.selectedElement['width'] as num, greaterThan(w));

    c.addElement('ascent_rate', 'segment_bar');
    sel = c.selectedElement;
    expect(sel['kind'], 'segment_bar');
    expect(sel['color_mode'], 'value');
    c.setSelectedAttr('color_mode', 'position');
    expect(c.selectedElement['color_mode'], 'position');
    c.setSelectedAttr('color_mode', 'value');
    expect(
      c.document!.elements[c.selectedElement['index'] as int],
      isNot(contains('color_mode')),
    );

    c.addElement('dive_time', 'text');
    c.setSelectedAttr('box_color', '#FF8000');
    expect(c.selectedElement['box_color'], '#FF8000');
    c.setSelectedAttr('box_color', '');
    expect(
      c.document!.elements[c.selectedElement['index'] as int],
      isNot(contains('box_color')),
    );
  });

  test('test_resize_selected_scales_fonts_and_icon_geometry', () async {
    await perdixAt100();
    final elements = c.document!.elements;
    c.selectElement(0);
    final font = elements[0]['font_size'] as num;
    c.resizeSelected(1);
    expect(elements[0]['font_size'], (font * 1.05).round());
    c.resizeSelected(-1);
    expect(elements[0]['font_size'], font);
    final icon = elements.indexWhere((e) => e['type'] == 'tank_icon');
    c.selectElement(icon);
    final w = elements[icon]['width'] as num;
    final h = elements[icon]['height'] as num;
    c.resizeSelected(1);
    expect(elements[icon]['width'], w + 1);
    expect(elements[icon]['height'], (h * 1.05).round());
    c
      ..resizeSelected(-1)
      ..resizeSelected(-1);
    expect(elements[icon]['width'] as num, lessThan(w));
    c
      ..selectElement(0)
      ..toggleElement(icon)
      ..resizeSelected(2);
    expect(elements[0]['font_size'], (font * 1.05 * 1.05).round());
  });

  test('test_snap_to_grid_and_to_element_edges', () async {
    c = await make();
    expect(
      await c.createCustomTemplate(
        targetIndex: c.saveAsTargets.length - 1,
        newComputerName: 'Snap Cam',
        pageName: 'Main',
        backgroundKind: 'shape',
      ),
      '',
    );
    c
      ..setZoomPercent(100)
      ..setSnapEnabled(true)
      ..setGridSize(16)
      ..addElement('depth', 'text')
      ..setSelectedAttr('x_px', '96')
      ..setSelectedAttr('y_px', '96');

    void dragPrimary(double dx, double dy) {
      final (x, y, w, h) = c.elementBoxes[c.selectedIndex];
      c
        ..press(x + w / 2, y + h / 2)
        ..drag(x + w / 2 + dx, y + h / 2 + dy)
        ..release();
    }

    (Object?, Object?) at() =>
        (c.selectedElement['x_px'], c.selectedElement['y_px']);

    dragPrimary(3, 2);
    expect(at(), (96.0, 96.0));
    dragPrimary(13, 0);
    expect(at(), (112.0, 96.0));
    dragPrimary(7, 0);
    expect(c.selectedElement['x_px'] as double, closeTo(119, 0.2));
    c.setSnapEnabled(false);
    dragPrimary(3, 0);
    expect(c.selectedElement['x_px'] as double, closeTo(122, 0.2));

    c
      ..setSnapEnabled(true)
      ..setGridSize(32)
      ..addElement('depth', 'text')
      ..setSelectedAttr('x_px', '124.5')
      ..setSelectedAttr('y_px', '150');
    dragPrimary(0.2, 0);
    expect(c.elementBoxes[1].$1, closeTo(c.elementBoxes[0].$1, 0.01));
    expect(c.selectedElement['x_px'] as double, closeTo(122, 0.2));
  });

  test('test_time_slider_scrubs_dummy_dive', () async {
    c = await make();
    c.onTimeChanged(0);
    expect(c.dataText, contains('Depth 0.0 m'));
    expect(c.timeText, '0:00:00');
    c.onTimeChanged(10 * 60);
    expect(c.dataText, contains('Depth 30.0 m'));
  });

  test('test_state_selector_forces_resolved_state', () async {
    c = await make();
    expect(c.stateOverride, 'auto');
    c.selectState('deco');
    expect(c.dataText, contains('State: deco (far)'));
    c.selectState('safety_stop');
    expect(c.dataText, contains('State: safety_stop'));
    c.selectState('auto');
    expect(c.dataText, contains('State: normal'));
  });

  testWidgets('test_play_runs_the_time_slider_at_ten_x_and_stops_at_the_end', (
    tester,
  ) async {
    await tester.runAsync(() async => c = await make());
    expect(c.playing, isFalse);
    c
      ..onTimeChanged(100)
      ..togglePlay();
    expect(c.playing, isTrue);
    await tester.pump(const Duration(milliseconds: playTickMs * 5 + 10));
    expect(c.timeValue, 100 + 5 * playSpeed * playTickMs ~/ 1000);
    c.togglePlay();
    expect(c.playing, isFalse);
    c
      ..onTimeChanged(c.timeMax - 1)
      ..togglePlay();
    await tester.pump(const Duration(milliseconds: playTickMs + 10));
    expect(c.timeValue, c.timeMax);
    expect(c.playing, isFalse);
    c.togglePlay();
    expect(c.playing, isTrue);
    expect(c.timeValue, c.timeMin);
    c.togglePlay();
  });

  test(
    'a shape needs a width and a height; saves tell the other pages',
    () async {
      c = await make();
      final before = templatesChanged;
      expect(
        await c.createCustomTemplate(
          targetIndex: c.saveAsTargets.length - 1,
          newComputerName: 'Cam',
          pageName: 'Main',
          backgroundKind: 'shape',
          shapeWidth: 'abc',
        ),
        'Enter a width and height for the shape.',
      );
      expect(templatesChanged, before);
      expect(
        await c.createCustomTemplate(
          targetIndex: c.saveAsTargets.length - 1,
          newComputerName: 'Cam',
          pageName: 'Main',
          backgroundKind: 'shape',
          shapeWidth: ' 250.6 ',
          shapeHeight: '90',
        ),
        '',
      );
      expect(c.skinAttrs['width'], 251);
      expect(templatesChanged, before + 1);
      c.addCustomLabel('X');
      expect(await c.save(), isTrue);
      expect(templatesChanged, before + 2);
      // Nothing selected: every key there, at its default.
      c.clearSelection();
      expect(c.selectedElement['index'], -1);
      expect(c.selectedElement['color'], '#FFFFFF');
      expect(c.selectedElement['font_size'], 16);
    },
  );

  // -- the More menu ---------------------------------------------------------

  test('a log file alone is previewed over its dive time', () async {
    c = await make();
    final log = File(p.join(tmp.path, 'reef.uddf'))..writeAsBytesSync(_uddf());
    await c.loadLogFile(log.path);
    expect(c.status, startsWith('Loaded 1 dive(s) from reef.uddf'));
    expect(c.logFileList, hasLength(1));
    expect(c.logFileList.single, startsWith('reef.uddf — '));
    expect(c.selectedLogLabel, c.logFileList.single);
    expect(c.telemetrySource, sourceLog);
    expect(c.logTelemetryAvailable, isTrue);
    expect(c.timeEnabled, isTrue);
    expect(c.timeText, '00:00:00');
    final dive = c.currentDive!;
    expect(
      c.timeMax,
      dive.waypoints
          .map((w) => w.timeSinceStart)
          .reduce((a, b) => a > b ? a : b)
          .ceil(),
    );
    expect(c.dataText, startsWith('Log telemetry · Depth '));
    expect(c.logText, startsWith('Current Log: '));
    c.onTimeChanged(120);
    expect(c.currentWaypoint!.timeSinceStart, greaterThanOrEqualTo(120));
    expect(c.timeText, '0:02:00');
    final json = c.waypointJson()!;
    expect(jsonDecode(json), containsPair('time_since_start', isA<num>()));

    final text = File(p.join(tmp.path, 'notes.txt'))..writeAsStringSync('hi');
    await c.loadLogFile(text.path);
    expect(c.status, startsWith('Unsupported log file: notes.txt'));
  });

  testWidgets('a photo behind the frame, matched to the dive by its date', (
    tester,
  ) async {
    await tester.runAsync(() async {
      c = await make();
      final log = File(p.join(tmp.path, 'reef.uddf'))
        ..writeAsBytesSync(_uddf());
      await c.loadLogFile(log.path);
      final start = c.currentDive!.startTime;
      // A photo from the boat ten minutes before the dive (by its file
      // time): within the half hour a match allows.
      final photo = File(p.join(tmp.path, 'shot.png'))
        ..writeAsBytesSync(base64.decode(_redPng4x3));
      photo.setLastModifiedSync(
        DateTime(
          start.year,
          start.month,
          start.day,
          start.hour,
          start.minute - 10,
        ),
      );
      await c.loadBackground(photo.path);
      expect(c.hasBackground, isTrue);
      expect(c.timeText, 'Photo Mode');
      expect(c.timeEnabled, isFalse);
      expect((c.viewW, c.viewH), (1920.0, 1440.0));
      expect(c.dataText, startsWith('Log telemetry'));
      expect(c.currentWaypoint, isNotNull);

      await c.setTz(5);
      expect(c.tzText, '5h');
      expect(c.currentDive, isNull);
      expect(
        c.dataText,
        'No matching dive found for this date/offset - showing dummy '
        'telemetry.',
      );
      await c.setTz(0);
      expect(c.currentDive, isNotNull);

      // A file that is no picture leaves the one shown and its date.
      final broken = File(p.join(tmp.path, 'broken.png'))
        ..writeAsStringSync('not a picture');
      await c.loadBackground(broken.path);
      expect(c.status, 'Could not read image: ${broken.path}');
      expect(c.hasBackground, isTrue);
      expect(c.currentDive, isNotNull);

      // A dive previewed on its own has no media date to match any more.
      await c.selectLogFile(c.logFileList.first);
      final previewed = c.currentDive;
      await c.setTz(7);
      expect(c.currentDive, same(previewed));
      expect(c.hasBackground, isFalse);

      c.clearBackground();
      expect(c.hasBackground, isFalse);
      expect(c.timeValue, dummyDefaultSeconds);
      expect((c.viewW, c.viewH), (1920.0, 1080.0));
    });
  });

  testWidgets('a video background runs the slider over its frames', (
    tester,
  ) async {
    final media = FakeMedia();
    await tester.runAsync(() async {
      c = await make(media: media);
      await c.loadBackground(p.join(tmp.path, 'clip.MP4'));
      expect(c.hasBackground, isTrue);
      expect((c.viewW, c.viewH), (1920.0, 1080.0));
      expect((c.timeMin, c.timeMax, c.timeValue), (0, 99, 0));
      expect(c.playStep, 10);
      c.onTimeChanged(50);
      expect(c.timeText, '0:00:05');
      await c.rendered;
      for (var i = 0; i < 300 && !media.frames.contains(5.0); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(media.frames, contains(5.0));
    });
  });

  testWidgets('a page out as a zip and back in as a new page', (tester) async {
    await tester.runAsync(() async {
      await perdixAt100();
      final zip = p.join(tmp.path, 'out', 'mine');
      Directory(p.dirname(zip)).createSync();
      expect(c.exportZipName, 'perdix_2_${c.selectedPage}.zip');
      expect(await c.exportZip(zip), isTrue);
      final archive = ZipDecoder().decodeBytes(
        File('$zip.zip').readAsBytesSync(),
      );
      expect(
        archive.files.map((f) => f.name),
        containsAll(['normal.json', 'template.json', 'normal.png']),
      );
      final meta = jsonDecode(
        utf8.decode(archive.findFile('template.json')!.content),
      ) as Map<String, dynamic>;
      expect(meta['brand'], 'shearwater');
      expect(meta['computer'], 'perdix_2');

      // The same zip on a phone (lib/engine/template_import.dart): among
      // the user's templates under its own brand and computer; the page
      // is a bundled one, so this one is numbered, and again numbered.
      final bytes = File('$zip.zip').readAsBytesSync();
      expect(isPageZip(bytes), isTrue);
      expect(isPageZip(Uint8List.fromList(utf8.encode('PK no zip'))), isFalse);
      final phone = p.join(tmp.path, 'phone_templates');
      Future<String> bringIn() => importPageZip(
        bytes,
        bundled: DiskTemplateFolder('assets/overlays/templates'),
        user: DiskTemplateFolder(phone),
        tempDir: (prefix) => tmp.createTempSync(prefix),
      );
      final pageId = c.selectedPage;
      expect(await bringIn(), startsWith('perdix_2 / '));
      final brought = p.join(phone, 'shearwater', 'perdix_2', '${pageId}_2');
      expect(File(p.join(brought, 'normal.json')).existsSync(), isTrue);
      expect(File(p.join(brought, 'normal.png')).existsSync(), isTrue);
      expect(await bringIn(), endsWith(' 3'));
      final listed = TemplateTree(
        bundled: DiskTemplateFolder('assets/overlays/templates'),
        user: DiskTemplateFolder(phone),
      );
      expect(listed.page('shearwater', 'perdix_2', '${pageId}_3'), isNotNull);

      // What the phone lists under Settings → My overlays, and Remove:
      // the page's folder and its line in the manifest go, the other
      // page stays; with the last page the computer and the brand go.
      final mine = userOverlays(DiskTemplateFolder(phone));
      expect([for (final o in mine) o.page], ['${pageId}_2', '${pageId}_3']);
      expect(mine.first.brand, 'shearwater');
      expect(mine.first.label, contains(' · '));
      removeUserOverlay(phone, mine.first);
      expect(Directory(brought).existsSync(), isFalse);
      expect(
        [for (final o in userOverlays(DiskTemplateFolder(phone))) o.page],
        ['${pageId}_3'],
      );
      expect(
        () => removeUserOverlay(phone, (
          brand: '..',
          computer: 'x',
          page: 'y',
          label: '',
        )),
        throwsA(isA<FileSystemException>()),
      );
      removeUserOverlay(phone, mine.last);
      expect(userOverlays(DiskTemplateFolder(phone)), isEmpty);
      expect(Directory(p.join(phone, 'shearwater')).existsSync(), isFalse);
      // Brought in again for what follows.
      expect(await bringIn(), isNotEmpty);
      expect(await bringIn(), isNotEmpty);
      await expectLater(
        importPageZip(
          Uint8List.fromList(utf8.encode('hello')),
          bundled: null,
          user: DiskTemplateFolder(phone),
          tempDir: (prefix) => tmp.createTempSync(prefix),
        ),
        throwsFormatException,
      );

      // A zip whose page is not one: refused, not an error of its own.
      final odd = Archive();
      final oddState = utf8.encode('{"hud_skin": "x"}');
      odd.addFile(ArchiveFile('normal.json', oddState.length, oddState));
      await expectLater(
        importPageZip(
          Uint8List.fromList(ZipEncoder().encode(odd)),
          bundled: null,
          user: DiskTemplateFolder(phone),
          tempDir: (prefix) => tmp.createTempSync(prefix),
        ),
        throwsFormatException,
      );

      expect(c.importZip('$zip.zip'), isNotEmpty);
      expect(c.importPending, isTrue);
      final count = c.elementRows.length;
      expect(
        await c.finishImport(c.saveAsTargets.length - 1, 'Zip Cam', 'Main'),
        '',
      );
      expect(c.importPending, isFalse);
      expect(c.selectedBrand, 'custom');
      expect(c.selectedComputer, 'zip_cam');
      expect(c.elementRows, hasLength(count));
      expect(c.status, startsWith('Imported as '));

      // A zip without a page, and one without its skin.
      final empty = Archive()..addFile(ArchiveFile('x.txt', 1, [65]));
      final bad = File(p.join(tmp.path, 'bad.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(empty));
      expect(c.importZip(bad.path), '');
      expect(c.status, 'bad.zip has no normal.json.');
      final noSkin = Archive()..addFile(archive.findFile('normal.json')!);
      final skinless = File(p.join(tmp.path, 'skinless.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(noSkin));
      expect(c.importZip(skinless.path), '');
      expect(c.status, 'skinless.zip has no normal.png skin image.');
      expect(await c.finishImport(0, '', 'x'), 'Nothing to import.');
    });
  });

  testWidgets('the More menu: a log file and its raw sample', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dialogs = FakeDialogs();
    await pumpPage(tester, dialogs: dialogs);
    final log = File(p.join(tmp.path, 'reef.uddf'))..writeAsBytesSync(_uddf());
    dialogs.logFile = log.path;
    await tester.tap(find.text('More ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Background and dive logs…'));
    await tester.pumpAndSettle();
    expect(find.text('Background and dive logs (optional)'), findsOneWidget);
    expect(find.text('No logs loaded'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Select log file'));
      for (var i = 0; i < 100 && c.logFileList.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(find.textContaining('reef.uddf — '), findsWidgets);
    expect(find.textContaining('Current Log: '), findsOneWidget);
    await tester.tap(find.text('Show raw waypoint data'));
    await tester.pumpAndSettle();
    expect(find.text('Current Waypoint Raw Data'), findsOneWidget);
    expect(find.textContaining('"time_since_start"'), findsOneWidget);
  });

  test('a log folder: one broken file does not stop the rest', () async {
    c = await make();
    final folder = Directory(p.join(tmp.path, 'logs'))..createSync();
    File(p.join(folder.path, 'reef.uddf')).writeAsBytesSync(_uddf());
    File(p.join(folder.path, 'broken.uddf')).writeAsStringSync(
      '<?xml version="1.0"?><uddf><profiledata><repetitiongroup><dive>'
      '<samples><waypoint><depth>x</depth></waypoint></samples>'
      '</dive></repetitiongroup></profiledata></uddf>',
    );
    await c.loadLogFolder(folder.path);
    expect(c.status, startsWith('Loaded '));
    expect(c.status, endsWith(' log files from logs'));
    expect(c.logFileList, isNotEmpty);
    expect(c.logFileList.first, startsWith('reef.uddf — '));
  });

  test('the imported logs: loaded, and not remembered as the folder', () async {
    c = await make();
    final before = c.config.dialogDirFor(logDirField, home: c.home);
    final kept = Directory(p.join(tmp.path, 'dive_logs'))..createSync();
    File(p.join(kept.path, 'reef.uddf')).writeAsBytesSync(_uddf());
    await c.loadLogFolder(kept.path, kept: true);
    expect(c.status, endsWith(' log files from the imported logs'));
    expect(c.logFileList.first, startsWith('reef.uddf — '));
    expect(c.config.dialogDirFor(logDirField, home: c.home), before);
  });

  test('an imported zip staged and let go of', () async {
    await perdixAt100();
    final zip = p.join(tmp.path, 'page.zip');
    expect(await c.exportZip(zip), isTrue);
    expect(c.importZip(zip), isNotEmpty);
    List<FileSystemEntity> staged() => tmp
        .listSync()
        .where((e) => p.basename(e.path).startsWith('uwmedia_import_'))
        .toList();
    expect(staged(), hasLength(1));
    // Read again: the first staging folder goes.
    expect(c.importZip(zip), isNotEmpty);
    expect(staged(), hasLength(1));
    c.cancelImport();
    expect(c.importPending, isFalse);
    expect(staged(), isEmpty);
    expect(
      await c.exportZip(p.join(tmp.path, 'no', 'such', 'dir', 'x.zip')),
      isFalse,
    );
    expect(c.status, startsWith('Could not export: '));
  });
}

// A 4 x 3 red PNG.
const _redPng4x3 =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGP4z8AARww4OQD1'
    'MQv1NXv7ggAAAABJRU5ErkJggg==';
