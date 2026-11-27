// The watermark store (lib/engine/watermark_store.dart), the "My
// watermarks" section of the Settings pages and the Color page's choice.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/watermark_editor.dart';
import 'package:uwmedia_app/pages/shared/watermarks_section.dart';

import '../helpers/menus.dart';
import 'photos_test.dart' show FakePhotos;

/// A PNG of one pixel.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  late Directory tmp;
  late ConfigStore config;
  late WatermarkStore store;
  late String logo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_watermarks_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    store = WatermarkStore(
      config,
      Directory(p.join(tmp.path, 'data', watermarksFolder)),
    );
    logo = p.join(tmp.path, 'My Logo.png');
    File(logo).writeAsBytesSync(_png);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('pictures are copied in, names kept apart, the choice follows', () {
    expect(store.list(), isEmpty);
    expect(store.selected, isEmpty);

    final first = store.addPicture(logo);
    expect(first.name, 'My Logo');
    expect(first.picture, 'My Logo.png');
    expect(File(p.join(store.folder.path, 'My Logo.png')).existsSync(), isTrue);
    // The picked file may go; the copy is the app's.
    final second = store.addPicture(logo);
    expect((second.name, second.picture), ('My Logo 2', 'My Logo_2.png'));
    final text = store.addText(' © Diver ');
    expect((text.name, text.text), ('© Diver', '© Diver'));
    expect(
      [for (final m in store.list()) m.name],
      ['My Logo', 'My Logo 2', '© Diver'],
    );

    File(p.join(tmp.path, 'notes.txt')).writeAsStringSync('hello');
    expect(
      () => store.addPicture(p.join(tmp.path, 'notes.txt')),
      throwsFormatException,
    );
    File(p.join(tmp.path, 'fake.png')).writeAsStringSync('hello');
    expect(
      () => store.addPicture(p.join(tmp.path, 'fake.png')),
      throwsFormatException,
    );

    // Several can be chosen; they come in the list's order.
    store
      ..select('© Diver', true)
      ..select('My Logo', true);
    expect([for (final m in store.selected) m.name], ['My Logo', '© Diver']);
    expect(store.selectedLayers(), hasLength(2));
    store.select('© Diver', false);
    expect(store.selected.single.name, 'My Logo');
    // One name, as it was kept before several could be chosen.
    config.setField(watermarkSelectField, 'My Logo');
    expect(store.selectedNames, ['My Logo']);
    config.setField(watermarkSelectField, '');
    expect(store.selectedNames, isEmpty);
    store.select('My Logo', true);
    // Renamed: still the one chosen; a taken name is made free.
    final renamed = store.update(
      'My Logo',
      first.copyWith(name: 'My Logo 2', place: placeOfAnchor('TOP_LEFT')),
    );
    expect(renamed.name, 'My Logo 2 2');
    expect(store.selected.single.name, 'My Logo 2 2');
    expect(anchorOfPlace(store.selected.single.place), 'TOP_LEFT');
    expect([for (final m in store.list()) m.name].first, 'My Logo 2 2');

    final layer = store.layerOf(renamed)!;
    expect(layer.always, isTrue);
    expect(layer.skinBytes, _png);
    expect((layer.layout['hud_skin'] as Map)['anchor'], 'TOP_LEFT');
    expect(store.layerOf(text)!.skinBytes, isNull);

    store.remove('My Logo 2 2');
    expect(store.selected, isEmpty);
    expect(store.selectedNames, isEmpty);
    expect(
      File(p.join(store.folder.path, 'My Logo.png')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(store.folder.path, 'My Logo_2.png')).existsSync(),
      isTrue,
    );
    // A picture that is gone draws nothing, and breaks nothing.
    File(p.join(store.folder.path, 'My Logo_2.png')).deleteSync();
    expect(store.layerOf(second), isNull);
  });

  testWidgets('My watermarks: add a picture and a text, change, remove', (
    tester,
  ) async {
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    var told = 0;
    services.watermarksRevision.addListener(() => told++);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WatermarksSection(
              services: services,
              pickFile: () async => logo,
            ),
          ),
        ),
      ),
    );
    expect(find.text('My watermarks'), findsOneWidget);
    expect(find.text('Add picture from the library…'), findsNothing);

    // A picture: kept, then its place, size and opacity asked for.
    await tester.tap(find.text('Add picture…'));
    await tester.pumpAndSettle();
    expect(find.text('Picture watermark'), findsOneWidget);
    expect(
      find.text('Size on landscape photos: 15 % of the width'),
      findsOneWidget,
    );
    expect(find.text('Opacity: 80 %'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Logo');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Logo'), findsOneWidget);
    expect(
      find.text('Picture · Bottom right · 15 % of the width · 80 % solid'),
      findsOneWidget,
    );
    expect(services.watermarks.list().single.name, 'Logo');
    expect(told, 2);

    // A text.
    await tester.tap(find.text('Add text…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Text'), '© Diver');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Text watermark'), findsOneWidget);
    expect(find.text('Colour'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      find.text('Text "© Diver" · Bottom right · letters 3.0 % of the width'),
      findsOneWidget,
    );
    expect(
      [for (final m in services.watermarks.list()) m.isPicture],
      [true, false],
    );

    await tester.tap(find.byTooltip('Remove Logo'));
    await tester.pumpAndSettle();
    expect(find.text('Logo'), findsNothing);
    expect(services.watermarks.list().single.text, '© Diver');
  });

  HudKit kit() {
    final fonts = TtfFonts(
      (file) => File('assets/fonts/$file').readAsBytesSync(),
      inkTables: InkTables.parse(
        File('assets/fonts/ink_tables.bin').readAsBytesSync(),
      ),
    );
    return HudKit(HudRenderer(fonts, HudRules(const {})), HudPainter(fonts));
  }

  Future<Watermark?> edit(
    WidgetTester tester,
    Watermark mark, {
    Uint8List? picture,
    Future<String?> Function()? pickSample,
    Future<void> Function()? then,
  }) async {
    Watermark? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => saved = await showDialog<Watermark>(
                context: context,
                builder: (context) => WatermarkDialog(
                  mark: mark,
                  pictureBytes: picture,
                  kit: () async => kit(),
                  pickSample: pickSample,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await then?.call();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    return saved;
  }

  final stage = find.byKey(const ValueKey('watermark stage'));
  final onStage = find.byKey(const ValueKey('watermark mark'));

  testWidgets('on a phone: one button to add a picture, from the library or '
      'from Files', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    final asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WatermarksSection(
              services: services,
              pickFile: () async {
                asked.add('files');
                return null;
              },
              pickFromLibrary: () async {
                asked.add('library');
                return null;
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('Add picture…'), findsOneWidget);
    expect(find.textContaining('Add picture from'), findsNothing);
    expect(find.text('Add text…'), findsOneWidget);

    await tester.tap(find.text('Add picture…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(fromLibraryLabel));
    await tester.pumpAndSettle();
    expect(asked, ['library']);
    await tester.tap(find.text('Add picture…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(fromFilesLabel));
    await tester.pumpAndSettle();
    expect(asked, ['library', 'files']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on the Mac: a picture and the editor\'s sample from a file or '
      'from Photos', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: true, photos: true),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
      tempDir: (prefix) => tmp.createTempSync(prefix),
    );
    final photos = FakePhotos();
    final asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WatermarksSection(
              services: services,
              photos: photos,
              pickFile: () async {
                asked.add('file');
                return null;
              },
              pickSampleFile: () async {
                asked.add('sample file');
                return null;
              },
            ),
          ),
        ),
      ),
    );

    // The button asks where from; a file as before.
    await choosePlace(tester, find.text('Add picture…'), filesPlaceLabel);
    expect(asked, ['file']);
    expect(photos.asked, isEmpty);

    // From Photos: one photo, no videos; kept, and its editor opens.
    final picked = p.join(tmp.path, 'From Photos.png');
    File(picked).writeAsBytesSync(_png);
    photos.offered = [picked];
    await choosePlace(
      tester,
      find.text('Add picture…'),
      photoLibraryPlaceLabel,
      real: true,
    );
    expect(photos.asked, ['photos']);
    expect(store.list().single.name, 'From Photos');
    expect(
      File(p.join(store.folder.path, 'From Photos.png')).existsSync(),
      isTrue,
    );
    expect(find.text('Picture watermark'), findsOneWidget);

    // The editor's sample: the same two places, Photos with its videos.
    await choosePlace(tester, find.text('Sample picture…'), filesPlaceLabel);
    expect(asked, ['file', 'sample file']);
    final sample = p.join(tmp.path, 'sample.png');
    File(sample).writeAsBytesSync(_png);
    photos.offered = [sample];
    await choosePlace(
      tester,
      find.text('Sample picture…'),
      photoLibraryPlaceLabel,
      real: true,
    );
    expect(photos.asked, ['photos', 'photos videos']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without Photos a computer has the one button, to a file', (
    tester,
  ) async {
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    final asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WatermarksSection(
              services: services,
              pickFile: () async {
                asked.add('file');
                return null;
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add picture…'));
    await tester.pumpAndSettle();
    expect(asked, ['file']);
    expect(find.text(photoLibraryPlaceLabel), findsNothing);
  });

  testWidgets('the editor: a picture dragged to its place, taken onto the '
      'lines, one place for landscape and one for portrait', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sample = p.join(tmp.path, 'sample.png');
    File(sample).writeAsBytesSync(_png);
    var asked = 0;
    final saved = await edit(
      tester,
      const Watermark(name: 'Logo', picture: 'logo.png', size: 0.2),
      picture: _png,
      pickSample: () async {
        asked++;
        return sample;
      },
      then: () async {
        // The stage is a landscape frame; the mark at the bottom right,
        // a fifth of its width, the margin in from the edges.
        final frame = tester.getRect(stage);
        expect(frame.width / frame.height, closeTo(16 / 9, 0.01));
        var box = tester.getRect(onStage);
        final margin = frame.width * watermarkMargin;
        expect(box.width, closeTo(frame.width * 0.2, 0.5));
        expect(box.right, closeTo(frame.right - margin, 0.5));
        expect(box.bottom, closeTo(frame.bottom - margin, 0.5));
        // No list of places: it is put where it goes by hand.
        expect(find.text('Place'), findsNothing);
        expect(find.text('Bottom right'), findsNothing);

        // Dragged up and left: where the finger left it.
        await tester.dragFrom(
          box.center,
          Offset(-frame.width * 0.3, -frame.height * 0.3),
        );
        await tester.pumpAndSettle();
        box = tester.getRect(onStage);
        expect(box.right, lessThan(frame.right - frame.width * 0.2));
        expect(box.bottom, lessThan(frame.bottom - frame.height * 0.2));
        // Dragged to near the top left corner, with the finger put down
        // beside the mark: it follows, and is taken onto the corner.
        await tester.dragFrom(
          frame.bottomRight - const Offset(10, 10),
          Offset(
            frame.left + margin + 6 - box.left,
            frame.top + margin + 5 - box.top,
          ),
        );
        await tester.pumpAndSettle();
        box = tester.getRect(onStage);
        expect(box.left, closeTo(frame.left + margin, 0.5));
        expect(box.top, closeTo(frame.top + margin, 0.5));

        // Portrait has its own place: still the bottom right, on an
        // upright stage, until it is dragged to the top's middle.
        await tester.tap(find.text('Portrait'));
        await tester.pumpAndSettle();
        final upright = tester.getRect(stage);
        expect(upright.height / upright.width, closeTo(16 / 9, 0.01));
        box = tester.getRect(onStage);
        expect(
          box.right,
          closeTo(upright.right - upright.width * watermarkMargin, 0.5),
        );
        await tester.dragFrom(
          box.center,
          Offset(
            upright.center.dx + 3 - box.center.dx,
            upright.top + 4 - box.top,
          ),
        );
        await tester.pumpAndSettle();
        box = tester.getRect(onStage);
        expect(box.center.dx, closeTo(upright.center.dx, 0.5));
        expect(find.text('Put it on portrait photos and videos'), findsOne);

        // The size shown is the portrait one: its own from now on.
        expect(
          find.text('Size on portrait photos: 20 % of the width'),
          findsOne,
        );
        await tester.ensureVisible(find.byType(Slider).first);
        final slider = tester.widget<Slider>(find.byType(Slider).first);
        slider.onChanged!(0.4);
        await tester.pumpAndSettle();
        expect(
          find.text('Size on portrait photos: 40 % of the width'),
          findsOne,
        );
        final larger = tester.getRect(onStage);
        expect(larger.width, closeTo(box.width * 2, 1));

        // A picture of the user's own to place it on.
        await tester.runAsync(() async {
          await tester.tap(find.text('Sample picture…'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
        expect(asked, 1);
        expect(
          find.descendant(of: stage, matching: find.byType(Image)),
          findsNWidgets(2),
        );
      },
    );
    expect(saved!.place, (x: 0.0, y: 0.0));
    expect(saved.placePortrait, (x: 0.5, y: 0.0));
    expect((saved.size, saved.sizePortrait), (0.2, 0.4));
    expect(
      watermarkSummary(saved),
      'Picture · Top left (portrait: top) · 20 % of the width '
      '(portrait: 40 %) · 80 % solid',
    );
  });

  testWidgets('the editor: a text is measured, placed between the nine, and '
      'given any colour', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final saved = await edit(
      tester,
      const Watermark(name: 'Name', text: '© Diver'),
      then: () async {
        final frame = tester.getRect(stage);
        var box = tester.getRect(onStage);
        // Its box is the renderer's measure: several letters wide.
        expect(box.width / box.height, inInclusiveRange(3, 7));
        await tester.dragFrom(
          box.center,
          Offset(-frame.width * 0.3, -frame.height * 0.2),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(onStage).center, isNot(box.center));
        // Longer words: a wider box, still inside the frame.
        await tester.enterText(
          find.widgetWithText(TextField, 'Text'),
          '© Diver under water',
        );
        await tester.pumpAndSettle();
        final longer = tester.getRect(onStage);
        expect(longer.width, greaterThan(box.width * 1.5));
        box = longer;

        // The named colours at a tap, any other under "More…".
        await tester.tap(find.byTooltip('Yellow'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('More…'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'As #RRGGBB'))
              .controller!
              .text,
          '#FFD60A',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'As #RRGGBB'),
          '12ab34',
        );
        await tester.pumpAndSettle();
        expect(
          (tester
                      .widget<Container>(
                        find.byKey(const ValueKey('picked colour')),
                      )
                      .decoration!
                  as BoxDecoration)
              .color,
          const Color(0xFF12AB34),
        );
        // The hue slider moves it off that colour.
        await tester.drag(
          find
              .descendant(
                of: find.byType(ColorPickerDialog),
                matching: find.byType(Slider),
              )
              .first,
          const Offset(60, 0),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      },
    );
    expect(saved!.text, '© Diver under water');
    expect(saved.textBox, isNotNull);
    expect(anchorOfPlace(saved.place), isNull);
    expect(saved.placePortrait, (x: 1.0, y: 1.0));
    expect(saved.color, matches(RegExp(r'^#[0-9A-F]{6}$')));
    expect(saved.color, isNot('#12AB34'));
    expect(saved.color, isNot('#FFD60A'));
    // The layout it gives lies by its measured box.
    expect((watermarkLayout(saved)!['hud_skin'] as Map)['anchor'], 'TOP_LEFT');
  });

  testWidgets('the editor: a mark for landscape frames only, or portrait '
      'ones only; never for neither', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final used = find.byKey(const ValueKey('watermark used'));
    final saved = await edit(
      tester,
      const Watermark(name: 'Logo', picture: 'logo.png', size: 0.2),
      picture: _png,
      then: () async {
        await tester.tap(find.text('Portrait'));
        await tester.pumpAndSettle();
        await tester.tap(used);
        await tester.pumpAndSettle();
        expect(
          find.text('Not put on portrait photos and videos.'),
          findsOneWidget,
        );
        // Off: a drag moves nothing.
        final before = tester.getRect(onStage);
        await tester.dragFrom(before.center, const Offset(-60, -200));
        await tester.pumpAndSettle();
        expect(tester.getRect(onStage), before);
      },
    );
    expect(saved!.frames, watermarkFramesLandscape);
    expect(saved.placePortrait, (x: 1.0, y: 1.0));
    expect(
      watermarkSummary(saved),
      'Picture · Landscape only · Bottom right · 20 % of the width · '
      '80 % solid',
    );

    // Taken off landscape too, it goes onto portrait.
    final other = await edit(
      tester,
      saved,
      picture: _png,
      then: () async {
        await tester.tap(used);
        await tester.pumpAndSettle();
      },
    );
    expect(other!.frames, watermarkFramesPortrait);
    expect(Watermark.fromJson(other.toJson())!.frames, watermarkFramesPortrait);
  });

  test('colours as the settings keep them', () {
    expect(hexOfColor(colorOfHex('#12ab34')), '#12AB34');
    expect(colorOfHex('red'), const Color(0xFFFFFFFF));
    expect(hexOfColor(const Color(0xFF000000)), '#000000');
  });

  test('what the list says of each', () {
    expect(
      watermarkSummary(
        const Watermark(name: 'n', text: 'Hi', anchor: 'TOP_CENTER'),
      ),
      'Text "Hi" · Top · letters 3.0 % of the width',
    );
  });
}
