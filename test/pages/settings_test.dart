// The phones' Settings page (lib/pages/settings/) on a temporary config
// folder: the settings it shares with the desktop's Color page (profile,
// output names, hardware encoding) and the units (the open pages told),
// and the tank sensor names from picked Garmin logs (the FIT edit
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

class FakeDialogs implements SettingsDialogs {
  List<String> logs = const [];

  @override
  Future<List<String>> pickLogs() async => logs;
}

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
          body: SettingsPage(
            services: services,
            dialogs: FakeDialogs(),
            bundledColorYaml: bundled,
          ),
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

  testWidgets('on a phone: units, profile and tank names from picked logs', (
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
    final logs = <String>[];
    for (final name in ['air', 'nitrox_30_min_later']) {
      final path = p.join(tmp.path, '$name.FIT');
      File(path).writeAsBytesSync(base64.decode(_sources[name] as String));
      logs.add(path);
    }
    final dialogs = FakeDialogs()..logs = logs;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SettingsPage(
            services: services,
            dialogs: dialogs,
            bundledColorYaml: bundled,
          ),
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
    await tester.tap(find.text('Tank Sensor Names…'));
    await tester.pumpAndSettle();
    expect(find.text('Tank Sensor Names'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Read Garmin Logs…'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('sensor(s) in .fit files'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(config.tankConfig().tanks.tanks, isNotEmpty);
  });
}
