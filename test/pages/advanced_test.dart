// The Advanced page (lib/pages/advanced/) with a temporary config and data
// folder and a made-up machine for the tool finder: the unit system and
// its signal, the folders set and reset, ffmpeg and exiftool set only when
// they run, and the tank sensor names (order, names, a serial added, the
// Garmin logs of the FIT edit fixture scanned, saved into config.yaml with
// whatever else it holds, an unreadable file noticed).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/shell.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/native_tools.dart';
import 'package:uwmedia_app/pages/advanced/advanced_controller.dart';
import 'package:uwmedia_app/pages/advanced/advanced_page.dart';
import 'package:uwmedia_app/pages/tag_editor_lite/tag_editor_lite_page.dart';

void main() {
  final sources =
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

  late Directory tmp;
  late ConfigStore config;
  var unitsTold = 0;

  ToolFinder machine() => ToolFinder(
    os: EngineOs.macos,
    env: const {'HOME': '/Users/x', 'PATH': '/usr/local/bin'},
    fileExists: {'/usr/local/bin/ffmpeg', '/my/ffmpeg', '/my/broken'}.contains,
    runs: (file, args, timeout) async => file != '/my/broken',
  );

  AdvancedController controller() => AdvancedController(
    config: config,
    home: '/Users/x',
    dataDir: () => Directory(p.join(tmp.path, 'data')),
    finder: machine,
    onUnitsChanged: () => unitsTold++,
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_advanced_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    unitsTold = 0;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('units, folders, tools', () async {
    final c = controller();
    await c.refreshTools();
    expect(c.ffmpegPathText, '/usr/local/bin/ffmpeg');
    expect(c.exiftoolPathText, 'Not found');

    expect(c.units, UnitSystem.metric);
    c.units = UnitSystem.imperial;
    expect(config.settings()['units'], 'imperial');
    expect(unitsTold, 1);
    c.units = UnitSystem.imperial;
    expect(unitsTold, 1);

    expect(c.layoutsDirText, p.join(tmp.path, 'data', 'layouts'));
    expect(c.templatesDirText, p.join(tmp.path, 'data', 'templates'));
    expect(c.colorDirText, p.join(tmp.path, 'config'));
    // Shown short while they are in the app's own folders (spec §10.113).
    expect(c.shown(c.layoutsDirText), "UWMedia's own folder › layouts");
    expect(c.shown(c.colorDirText), "UWMedia's own folder");
    expect(c.shown(c.tankNamesPathText), "UWMedia's own folder › config.yaml");
    expect(c.shown('/my/templates'), '/my/templates');
    c
      ..setFolder('templates', '/my/templates')
      ..setFolder('color', '/my/colors');
    expect(config.settings()['templates_dir'], '/my/templates');
    expect(c.templatesDirText, '/my/templates');
    expect(c.colorDirText, '/my/colors');
    c.resetFolder('templates');
    expect(config.settings()['templates_dir'], isNull);
    expect(c.templatesDirText, p.join(tmp.path, 'data', 'templates'));

    expect(
      await c.setTool(toolFfmpeg, '/my/broken'),
      contains("Running '/my/broken -version' didn't succeed"),
    );
    expect(config.settings()[ffmpegPathKey], isNull);
    expect(await c.setTool(toolFfmpeg, '/my/ffmpeg'), isNull);
    expect(config.settings()[ffmpegPathKey], '/my/ffmpeg');
    expect(c.ffmpegPathText, '/my/ffmpeg');
    await c.resetTool(toolFfmpeg);
    expect(c.ffmpegPathText, '/usr/local/bin/ffmpeg');
    c.dispose();
  });

  test('the tank sensor names: the kept logs\' sensors, order, names, '
      'save', () async {
    // The logs the app keeps: their sensors are the window's.
    final logs = Directory(p.join(tmp.path, 'logs'))..createSync();
    final expected = <String>{};
    for (final name in ['air', 'nitrox_30_min_later', 'ccr_1_h_later']) {
      final bytes = base64.decode(sources[name] as String);
      File(p.join(logs.path, '$name.FIT')).writeAsBytesSync(bytes);
      expected.addAll(uniqueTankSerials(readFitMessages(bytes)));
    }
    File(p.join(logs.path, 'notes.txt')).writeAsStringSync('x');
    config.saveConfigYaml(
      '# my notes\ntanks:\n  "111": Left\n  "222": Right\nother: kept\n',
    );

    final c = controller();
    final tanks = c.tanks..open();
    expect(
      [for (final row in tanks.rows) (row.serial, row.name)],
      [('111', 'Left'), ('222', 'Right')],
    );
    expect(tanks.unreadable, isFalse);
    tanks.reorder(1, 0);
    expect(tanks.rows.first.serial, '222');
    tanks.setName('111', '  ');

    await tanks.readKept(logs.path);
    final fresh = expected.difference({'111', '222'});
    expect(tanks.rows.length, 2 + fresh.length);
    expect(tanks.rows.first.seen, isNull, reason: 'saved, in no kept log');
    for (final row in tanks.rows.skip(2)) {
      expect(row.name, 'Tank ${row.serial}');
      expect(row.seen!.dives, greaterThan(0));
    }
    expect(
      tanks.statusText,
      fresh.isEmpty ? '' : contains('${fresh.length} new sensor(s)'),
    );

    expect(tanks.save(), config.configYamlPath);
    final saved = config.tankConfig();
    expect(saved.tanks.tanks.keys.take(2), ['222', '111']);
    expect(saved.tanks.tanks['111'], 'Tank 111');
    expect(saved.tanks.tanks.length, 2 + fresh.length);
    expect(
      File(config.configYamlPath).readAsStringSync(),
      contains('other: kept'),
    );

    config.saveConfigYaml('tanks: [unclosed');
    tanks.open();
    expect(tanks.unreadable, isTrue);
    expect(tanks.rows, isEmpty);
    c.dispose();
  });

  testWidgets('on screen: units, the tank names window', (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    config.saveConfigYaml('tanks:\n  "111": Left\n');
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: config,
      home: '/Users/x',
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: AdvancedPage(services: services, finder: machine),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('/usr/local/bin/ffmpeg'), findsOneWidget);
    await tester.tap(find.text(UnitSystem.metric.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(UnitSystem.imperial.label).last);
    await tester.pumpAndSettle();
    expect(services.unitsRevision.value, 1);

    await tester.tap(find.text('Edit Tank Sensor Names…'));
    await tester.pumpAndSettle();
    expect(find.text('Tank Sensor Names'), findsOneWidget);
    expect(find.text('Sensor 111'), findsOneWidget);
    // No log picker in the window: the sensors are the kept logs'.
    expect(find.textContaining('Scan'), findsNothing);
    expect(find.text('Add'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('name-111')), 'Port');
    await tester.enterText(find.byKey(const ValueKey('sidemount-111')), 'Left');
    // Imperial units: the size in cubic feet at the rated pressure.
    await tester.enterText(find.byKey(const ValueKey('size-111')), '77.4');
    expect(find.byKey(const ValueKey('working-111')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('side-111')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Right').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = config.tankConfig().tanks;
    expect(saved.tanks, {'111': 'Port'});
    expect(saved.sidemountNames, {'111': 'Left'});
    expect(saved.sides, {'111': TankSide.right});
    expect(saved.sizes['111'], closeTo(10.6, 0.01));
    expect(saved.workingBar['111'], closeTo(206.84, 0.01));
  });

  testWidgets('the video engine: offered only where the runner has one, '
      'ffmpeg until the other is chosen', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<AppServices> shown({required bool nativeVideo}) async {
      final services = AppServices(
        capabilities: Capabilities(desktop: true, nativeVideo: nativeVideo),
        config: config,
        home: '/Users/x',
        dataDir: () => Directory(p.join(tmp.path, 'data')),
        nativeEngine: () => const PlatformMediaEngine(),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              body: AdvancedPage(
                key: ValueKey(nativeVideo),
                services: services,
                finder: machine,
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      return services;
    }

    // Windows, Linux: no choice, and ffmpeg whatever the settings say.
    var services = await shown(nativeVideo: false);
    expect(find.text('Video engine'), findsNothing);
    config.updateSettings({videoEngineKey: videoEngineNative});
    expect(services.nativeVideoEngine, isNull);
    config.updateSettings({videoEngineKey: null});

    services = await shown(nativeVideo: true);
    expect(find.text('Video engine'), findsOneWidget);
    expect(services.nativeVideoEngine, isNull);
    await tester.tap(find.byKey(const ValueKey('video engine')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(videoEngineLabels[videoEngineNative]!).last);
    await tester.pumpAndSettle();
    expect(config.settings()[videoEngineKey], videoEngineNative);
    expect(services.nativeVideoEngine, isNotNull);
  });

  testWidgets('a build without ffmpeg and exiftool (spec §10.74): no tools '
      'and no engine to choose, the engine and the app\'s readers in their '
      'place', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(
        desktop: true,
        nativeVideo: true,
        externalTools: false,
      ),
      config: config,
      home: '/Users/x',
      dataDir: () => Directory(p.join(tmp.path, 'data')),
      // No tool is looked for.
      toolFinder: () => throw StateError('no tools in this build'),
    );
    // The engine writes every video, whatever was chosen before.
    expect(services.nativeVideoEngine, isNotNull);
    config.updateSettings({videoEngineKey: videoEngineFfmpeg});
    expect(services.nativeVideoEngine, isNotNull);
    final tools = await services.desktopTools();
    expect(tools.ffmpeg, isA<NativeFfmpegTools>());
    expect(tools.exiftool, isA<NativeExiftool>());
    // A desktop as before has both, and its tools are looked for.
    expect(const Capabilities(desktop: true).externalTools, isTrue);
    expect(const Capabilities(desktop: false).externalTools, isFalse);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: AdvancedPage(services: services, finder: machine),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Units'), findsOneWidget);
    expect(find.text('External tools'), findsNothing);
    expect(find.text('Video engine'), findsNothing);

    // The Tag Editor is the phones' one.
    final editor = pagesFor(services.capabilities)
        .firstWhere((page) => page.title == 'Tag Editor');
    expect(editor.build(services), isA<TagEditorLitePage>());
  });
}
