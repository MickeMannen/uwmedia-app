// The Color Tuning page (lib/pages/color_tuning/) with a temporary config
// folder: the sliders from the default profile, a sample picture scaled
// to 600 on its longest side and corrected, another profile's values, a
// reset, saving the profile and a new one into the user's color.yaml,
// and the page on screen.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_params.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/yaml_text.dart';
import 'package:uwmedia_app/pages/color_tuning/color_tuning_controller.dart';
import 'package:uwmedia_app/pages/color_tuning/color_tuning_page.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';

import 'photos_test.dart' show FakePhotos;

const _sample = 'assets/overlays/templates/garmin/mk3i/main/normal.png';

void main() {
  final bundled = File('assets/color.yaml').readAsStringSync();
  late Directory tmp;
  late ConfigStore config;
  final asked = <ColorProfile>[];

  ColorTuningController controller() => ColorTuningController(
    config: config,
    home: '/Users/diver',
    bundledColorYaml: bundled,
    correct: (job) async {
      asked.add(job.$1);
      return correctedSample(job);
    },
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_tuning_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    asked.clear();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('a sample, the sliders, the profiles, saving', (tester) async {
    await tester.runAsync(() async {
      final c = controller();
      expect(c.statusText, noImageText);
      expect(c.profileList, containsAll(['default', 'vivid', 'subtle']));
      expect(c.currentProfile, 'default');
      expect(c.textOf('gw_blur_radius'), '9');
      expect(c.textOf('cifval'), '1.000');
      // The sliders show the profile shown, not the code's defaults
      // (spec §10.79): "default" has Sharpness and Darkness of its own.
      expect(c.valueOf('sharpness'), 0.47);
      expect(c.valueOf('darkness'), -0.26);

      await c.loadImage(_sample);
      expect(c.statusText, _sample);
      // 692 x 922 to 600 on its longest side.
      expect(c.originalImage!.height, 600);
      expect(c.originalImage!.width, 450);
      expect(c.resultImage, isNotNull);
      expect(config.fields()[tuningImageDirField], p.dirname(_sample));

      c.setValue('red_scale', 0.123656);
      expect(c.valueOf('red_scale'), 0.1237);
      expect(c.textOf('red_scale'), '0.124');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked.last.redScale, 0.1237);

      // A burst of moves: the one going, then one with the last value.
      asked.clear();
      for (var v = 0.30; v < 0.40; v += 0.01) {
        c.setValue('blue_threshold', v);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(asked.length, lessThanOrEqualTo(2));
      expect(asked.last.blueThreshold, c.valueOf('blue_threshold'));

      c.newProfileName = '🐠🐠🐠🐠🐠🐠🐠🐠🐠🐠🐠🐠';
      expect(c.newProfileName.runes.length, 10);
      c.newProfileName = '';

      c.reset('red_scale');
      expect(c.valueOf('red_scale'), 0.2);

      c.currentProfile = 'vivid';
      final vivid = config.colorProfiles(bundled)['vivid']!;
      expect(c.valueOf('cifval'), (vivid['cifval']! as num).toDouble());

      c.setValue('gw_blur_radius', 12.6);
      expect(c.textOf('gw_blur_radius'), '12');
      c.saveProfile();
      expect(c.statusText, "Saved profile 'vivid'");
      final saved = readYamlMap(File(config.colorYamlPath).readAsStringSync());
      expect(yamlValue((saved['vivid']! as Map)['gw_blur_radius']), 12);

      c.newProfileName = 'my reef of the year';
      expect(c.newProfileName, 'my reef of');
      c.saveNewProfile();
      expect(c.statusText, "Saved new profile 'my reef of'");
      expect(c.currentProfile, 'my reef of');
      expect(c.profileList, contains('my reef of'));
      expect(c.newProfileName, '');

      await c.loadImage(p.join(tmp.path, 'none.png'));
      expect(c.statusText, startsWith('Could not load:'));
      c.dispose();
    });
  });

  testWidgets('the sample drawn by the shaders is the engine\'s correction', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final c = ColorTuningController(
        config: config,
        home: '/Users/diver',
        bundledColorYaml: bundled,
      );
      await c.loadImage(_sample);
      Future<Uint8List> bytes(ui.Image image) async =>
          (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!
              .buffer
              .asUint8List();
      final original = await bytes(c.originalImage!);
      Future<void> check(String what) async {
        final shown = await bytes(c.resultImage!);
        final rgb = Uint8List(original.length ~/ 4 * 3);
        for (var i = 0, o = 0; i < original.length; i += 4, o += 3) {
          rgb.setRange(o, o + 3, original, i);
        }
        final profile = ColorProfile.fromMap({
          for (final param in colorParamsByKey.values)
            param.key: c.valueOf(param.key),
        });
        final want = correctedSample((
          profile,
          RgbImage(c.originalImage!.width, c.originalImage!.height, rgb),
        )).rgb;
        var worst = 0;
        var changed = 0;
        var opaque = 0;
        for (var i = 0, o = 0; i < want.length; i += 3, o += 4) {
          expect(shown[o + 3], 255);
          if (original[o + 3] != 255) {
            // A see-through pixel's colour is not exact enough to compare.
            continue;
          }
          opaque++;
          for (var k = 0; k < 3; k++) {
            final d = (shown[o + k] - want[i + k]).abs();
            if (d > worst) worst = d;
            changed += (want[i + k] - original[o + k]).abs();
          }
        }
        expect(worst, lessThanOrEqualTo(2), reason: what);
        expect(opaque, greaterThan(want.length ~/ 12), reason: what);
        expect(changed / (opaque * 3), greaterThan(1), reason: what);
      }

      await check('the default profile');
      c.setValue('sharpness', 0.0);
      c.setValue('cifval', 0.6);
      // Until the sample is drawn again: a fixed 300 ms compared the
      // picture before with the new correction on a busy runner (69
      // levels apart, Gitea runs 156 and 160).
      expect(c.updating, isTrue);
      final waited = Stopwatch()..start();
      while (c.updating && waited.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(c.updating, isFalse);
      await check('no sharpening, partly mixed in');
      c.dispose();
    });
  });

  testWidgets('on screen', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ColorTuningPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: config,
                home: '/Users/diver',
              ),
              bundledColorYaml: bundled,
              pickImage: (_) async => _sample,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.tap(find.text('Load Image…'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    expect(find.text('Color Restoration & Blend'), findsOneWidget);
    expect(find.text(_sample), findsOneWidget);
    expect(find.byType(RawImage), findsNWidgets(2));
    expect(find.byType(Slider), findsWidgets);
  });

  testWidgets('the sample from Apple Photos (spec §10.67(g))', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final photos = FakePhotos()
      ..offered = [File(_sample).copySync(p.join(tmp.path, 'IMG_9.png')).path];
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ColorTuningPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: config,
                home: '/Users/diver',
                tempDir: (prefix) => tmp.createTempSync(prefix),
              ),
              bundledColorYaml: bundled,
              pickImage: (_) async => null,
              photos: photos,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.tap(find.text('Load Image…'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, photoLibraryPlaceLabel),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    // One photo is asked for, and its working folder is not where the
    // file dialog opens next time.
    expect(photos.asked, ['photos']);
    expect(find.byType(RawImage), findsNWidgets(2));
    expect(config.fields()[tuningImageDirField], isNull);
  });

  test('the lite sliders: the bundled defaults in the middle', () {
    final c = controller();
    final byKey = {for (final s in liteSliders) s.key: s};
    expect(byKey.keys, [
      'cifval',
      'red_restore',
      'blue_reduce',
      'dehaze_min',
      'exposure_max',
      'darkness',
      'sharpness',
    ]);
    // The default profile's red and blue pairs read as half strength.
    expect(c.liteValueOf(byKey['red_restore']!), closeTo(0.5, 1e-9));
    expect(c.liteValueOf(byKey['blue_reduce']!), closeTo(0.5, 1e-9));
    // Strength sets the pair together; more strength, a lower pair.
    c.setLite(byKey['red_restore']!, 1.0);
    expect(c.valueOf('red_threshold'), 0.0);
    expect(c.valueOf('red_scale'), 0.01);
    c.setLite(byKey['red_restore']!, 0.0);
    expect(c.valueOf('red_threshold'), 0.6);
    expect(c.valueOf('red_scale'), 0.4);
    c.setLite(byKey['blue_reduce']!, 0.5);
    expect(c.valueOf('blue_threshold'), 0.3);
    expect(c.valueOf('blue_scale'), closeTo(0.605, 1e-9));
    // A one-to-one slider sets its own parameter.
    c.setLite(byKey['exposure_max']!, 3.25);
    expect(c.valueOf('exposure_max'), 3.25);
    c.dispose();
  });

  testWidgets('the lite page on a phone', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ColorTuningPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: false),
                config: config,
                home: '/Users/diver',
              ),
              bundledColorYaml: bundled,
              lite: true,
              pickImage: (_) async => null,
              pickFile: (_) async => _sample,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    await tester.pump();
    // One button, which asks where from: the library gave nothing here,
    // the phone's files the sample.
    Future<void> loadFrom(String place) async {
      await tester.tap(find.text('Load Image…'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(MenuItemButton, place));
        // The choice is acted on once the menu has closed.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
    }

    await loadFrom(fromLibraryLabel);
    expect(find.byType(RawImage), findsNothing);
    await loadFrom(fromFilesLabel);
    // The picked file's name on one line, not its whole path.
    expect(find.text('normal.png'), findsOneWidget);
    expect(find.text(_sample), findsNothing);
    expect(find.text('Adjust'), findsOneWidget);
    expect(find.text('Color Restoration & Blend'), findsNothing);
    expect(find.text('Red restore'), findsOneWidget);
    // One picture: the adjusted one, the original while it is held.
    final made = tester.state<State<ColorTuningPage>>(
      find.byType(ColorTuningPage),
    );
    expect(made.mounted, isTrue);
    expect(find.byType(RawImage), findsOneWidget);
    final adjusted = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(find.textContaining('Press and hold the picture'), findsOneWidget);
    final hold = await tester.startGesture(
      tester.getCenter(find.byType(RawImage)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Original'), findsOneWidget);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      isNot(same(adjusted)),
    );
    await hold.up();
    await tester.pump();
    expect(find.text('Original'), findsNothing);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(adjusted),
    );

    // The sliders scroll under the picture, which stays; the file and
    // profile row goes.
    final pictureTop = tester.getTopLeft(find.byType(RawImage)).dy;
    await tester.drag(find.text('Adjust'), const Offset(0, -400));
    await tester.pump();
    expect(find.text('Load Image…').hitTestable(), findsNothing);
    expect(find.byType(RawImage).hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.byType(RawImage)).dy, lessThan(pictureTop));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 1000));
    await tester.pump();

    // Save asks: over the profile, or a new one.
    expect(find.text('Save Profile'), findsNothing);
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite "default"'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Save As New'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'reef');
    await tester.pump();
    await tester.tap(find.text('Save As New'));
    await tester.pumpAndSettle();
    expect(config.colorProfiles(bundled).keys, contains('reef'));
    expect(find.text('reef'), findsOneWidget);
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Overwrite "reef"'));
    await tester.pumpAndSettle();
    expect(find.text("Saved profile 'reef'"), findsOneWidget);
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text("Saved profile 'reef'"), findsOneWidget);
    expect(
      phoneStatusText('Could not load: /private/var/tmp/a b/IMG 1.HEIC'),
      'Could not load: IMG 1.HEIC',
    );
    expect(phoneStatusText("Saved profile 'reef'"), "Saved profile 'reef'");
  });
}
