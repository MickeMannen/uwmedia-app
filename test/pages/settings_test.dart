// The phones' Settings page (lib/pages/settings/) on a temporary config
// folder: the settings it shares with the desktop's Color page (profile,
// output names, hardware encoding) and the units (the open pages told),
// and the tank sensor names of the kept Garmin logs (the FIT edit
// fixture's invented ones); on a phone-sized screen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/pages/color/color_controller.dart'
    show colorProfileField, filenameFormatField, hwAccelSwitchField;
import 'package:uwmedia_app/pages/settings/settings_controller.dart';
import 'package:uwmedia_app/pages/settings/settings_page.dart';

import '../helpers/wait.dart';

final Map<String, dynamic> _sources =
    (jsonDecode(
          utf8.decode(
            gzip.decode(
              File(
                'test/fixtures/python_reference/dives/fit_edit_cases.json.gz',
              ).readAsBytesSync(),
            ),
          ),
        ) as Map<String, dynamic>)['sources']
        as Map<String, dynamic>;

void main() {
  late Directory tmp;
  late ConfigStore config;
  final bundled = File('assets/color.yaml').readAsStringSync();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_settings_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the settings shared with the Color page, and the units', () {
    var told = 0;
    final c = SettingsController(
      config: config,
      home: tmp.path,
      bundledColorYaml: bundled,
      onUnitsChanged: () => told++,
    );
    expect(c.units, UnitSystem.metric);
    c.units = UnitSystem.imperial;
    expect(config.settings()['units'], 'imperial');
    expect(told, 1);
    c.units = UnitSystem.imperial;
    expect(told, 1);

    expect(c.profiles, containsAll(['default', 'vivid', 'punchy']));
    expect(c.profile, c.profiles.first);
    c.profile = 'vivid';
    expect(config.fields()[colorProfileField], 'vivid');
    c.profile = 'no such';
    expect(c.profile, 'vivid');

    // An earlier version's label is today's.
    config.setField(filenameFormatField, 'Date taken');
    expect(c.filenameFormat, 'Date + time (20260905_143000)');
    c.filenameFormat = c.filenameFormats.last;
    expect(config.fields()[filenameFormatField], c.filenameFormats.last);

    expect(c.hwAccel, isTrue);
    c.hwAccel = false;
    expect(config.fields()[hwAccelSwitchField], isFalse);
    expect(c.hwAccel, isFalse);
    c.dispose();
  });

  testWidgets('on a phone: no overlays section (spec §10.69(e)); an overlay '
      'of the user\'s own is still listed and removed by the services', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    final cam = Directory(
      p.join(tmp.path, 'data', 'templates', 'custom', 'cam'),
    )..createSync(recursive: true);
    File(p.join(cam.path, 'manifest.json')).writeAsStringSync(
      jsonEncode({
        'manufacturer': 'Custom',
        'model': 'Cam',
        'pages': [
          {'id': 'main', 'name': 'Main'},
        ],
      }),
    );
    final page = Directory(p.join(cam.path, 'main'))..createSync();
    File(p.join(page.path, 'normal.json'))
        .writeAsStringSync('{"hud_skin": {}}');
    var told = 0;
    services.templatesRevision.addListener(() => told++);

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SettingsPage(services: services, bundledColorYaml: bundled),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('My overlays'), findsNothing);
    expect(find.text('Import overlay zip…'), findsNothing);
    expect(find.text('Custom · Cam · Main'), findsNothing);
    expect(find.text('My watermarks'), findsOneWidget);

    final overlay = services.userOverlayPages().single;
    expect(overlay.label, 'Custom · Cam · Main');
    services.removeUserOverlayPage(overlay);
    expect(page.existsSync(), isFalse);
    expect(services.userOverlayPages(), isEmpty);
    expect(told, 1, reason: 'the Color page is told');
  });

  testWidgets('on a phone: units, and the tank names with no log kept', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    var revision = 0;
    services.unitsRevision.addListener(() => revision++);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SettingsPage(services: services, bundledColorYaml: bundled),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.text(UnitSystem.metric.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(UnitSystem.imperial.label).last);
    await tester.pumpAndSettle();
    expect(config.settings()['units'], 'imperial');
    expect(revision, 1);

    await tester.ensureVisible(find.text('Tank Sensor Names…'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Tank Sensor Names…'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpUntilFound(tester, find.textContaining('No tank sensors yet'));
    expect(find.text('Tank Sensor Names'), findsOneWidget);
    // No log is picked here: the sensors come from the Dive Logs page's
    // logs (owner, 2026-11-25).
    expect(find.text('Read Garmin Logs…'), findsNothing);
    expect(find.textContaining('No tank sensors yet'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Tank Sensor Names'), findsNothing);
  });

  testWidgets('on a phone: the tank sensors of the dive logs the app keeps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    // A kept Garmin log: its sensors are in the window when it opens,
    // with no file picked (owner, 2026-11-24).
    final kept = services.logStore.folder..createSync(recursive: true);
    File(p.join(kept.path, 'air.fit'))
        .writeAsBytesSync(base64.decode(_sources['air'] as String));
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SettingsPage(services: services, bundledColorYaml: bundled),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Tank Sensor Names…'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Tank Sensor Names…'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    // The log is read on an isolate: as long as that takes.
    await pumpUntilFound(tester, find.textContaining('from your dive logs'));
    expect(find.text('Tank Sensor Names'), findsOneWidget);
    expect(find.textContaining('from your dive logs'), findsOneWidget);
    expect(find.textContaining('1 dive'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(config.tankConfig().tanks.tanks, isNotEmpty);
  });
}
