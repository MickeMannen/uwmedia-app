// The Dive Profile Builder (lib/pages/dive_profile/) with a temporary
// config folder: the settings kept under the Python app's names and
// restored, the chart's scale and waypoints placed, moved and snapped on
// it, the gases (a deco gas, a name clash, a range the wrong way round, the
// MOD note, sidemount twins), End dive, the hover readout, the log saved
// as UDDF, FIT and Subsurface XML and opened again as saved, another log
// imported, the units switched, and the page on screen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/plan/profile_chart.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/pages/dive_profile/dive_profile_controller.dart';
import 'package:uwmedia_app/pages/dive_profile/dive_profile_page.dart';
import 'package:uwmedia_app/pages/dive_profile/profile_painter.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';

void main() {
  late Directory tmp;
  late ConfigStore config;

  DiveProfileController controller() => DiveProfileController(
    config: config,
    home: '/Users/x',
    now: () => naive(2026, 11, 13, 9, 30),
    utcOffsetMinutes: (_) => 60,
  );

  // The chart pixel of a time and depth.
  (double, double) at(DiveProfileController c, int seconds, double depth) =>
      xyOf(seconds, depth, canvasWidth, canvasHeight, c.axes!);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_builder_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('the start, and the settings kept and restored', () {
    final c = controller();
    expect(c.plan.gases.single.id, 'Air');
    expect(c.statusText, 'Click in the chart to place the first waypoint');
    expect(c.gfLowText, '30');
    expect(c.scaleDefined, isFalse);
    expect(c.defineScale('deep', '50'), 'Enter the max depth in metres');
    expect(
      c.defineScale('30', 'soon'),
      'Enter the planned runtime in minutes (or mm:ss)',
    );
    expect(c.defineScale('30', '0'), 'Planned runtime must be greater than 0');
    expect(c.defineScale('30', '50'), '');
    expect(c.scaleDefined, isTrue);
    c
      ..setGfLow('40')
      ..setGfHigh('85')
      ..setName('Wreck')
      ..selectDiveType('CCR')
      ..setSerial('12a');
    expect(c.logErrorText, 'The serial number must be digits only');
    c.setGfHigh('20');
    expect(c.gfErrorText, "GF low can't be higher than GF high");
    expect(c.plan.gfHigh, 85);

    final fields = config.fields();
    expect(fields['dive_profile_gf_low'], 40);
    expect(fields['dive_profile_name'], 'Wreck');
    expect(fields['dive_profile_dive_type'], 'ccr');
    expect(fields['dive_profile_max_depth'], 30);
    expect(fields['dive_profile_planned_runtime_sec'], 3000);

    final again = controller();
    expect(again.plan.name, 'Wreck');
    expect(again.plan.gfLow, 40);
    expect(again.isCcr, isTrue);
    // A CCR dive's first gas is the loop.
    expect(again.plan.gases.single.diluent, isTrue);
    expect(again.gasTableRows.single[1], 'DIL');
    expect(again.runtimeText, '50');
    c.dispose();
    again.dispose();
  });

  test('waypoints on the chart, End dive, the readout', () {
    final c = controller()..defineScale('40', '40');
    final (x1, y1) = at(c, 120, 30);
    c.addWaypointAt(x1 + 3, y1 - 2);
    expect(c.waypointRows.single.take(2), ['2:00', '30.0']);
    expect(c.waypointRows.single[2], 'Air (auto)');
    final (x2, y2) = at(c, 1500, 30);
    c.addWaypointAt(x2, y2);
    expect(c.waypointRows.map((r) => r[0]), ['2:00', '25:00']);
    expect(
      c.statusText,
      startsWith('${c.samples.length} samples · max depth 30m'),
    );

    // Grabbed and moved; never past its neighbour.
    final row = c.waypointIndexAt(x2, y2);
    expect(row, 1);
    final (x3, y3) = at(c, 60, 25);
    c.moveWaypoint(1, x3, y3);
    expect(c.dragging, isTrue);
    c.dropWaypoint(1);
    expect(c.waypointRows[1].take(2), ['3:00', '25.0']);
    c.moveWaypoint(1, x2, y2);
    c.dropWaypoint(1);

    // A click near the end of the axis grows it.
    final (x4, y4) = at(c, 2280, 20);
    c.addWaypointAt(x4, y4);
    expect(c.plan.plannedRuntimeSec, 3000);
    expect(c.runtimeText, '50');

    c.endDive();
    expect(
      c.endDiveStatusText,
      anyOf(startsWith('Deco ascent added:'), startsWith('No deco needed')),
    );
    expect(c.plan.sortedWaypoints().last.depthM, 0);
    c.endDive();
    expect(
      c.endDiveStatusText,
      startsWith('The dive already ends at the surface'),
    );

    final (x5, _) = at(c, 900, 0);
    c.scrub(x5);
    final labels = [for (final line in c.cursorInfo) line.label];
    expect(labels.take(4), ['Time', 'Depth', 'Gas', 'PO2']);
    expect(labels, contains('CNS'));
    expect(labels.last, 'Tank');
    c.clearCursor();
    expect(c.cursorInfo, isEmpty);
    c.dispose();
  });

  test('gases: a deco gas, mistakes, the MOD note, removing one', () {
    final c = controller()..defineScale('40', '40');
    c
      ..editGasField(() {
        c
          ..gasNameText = 'EAN50'
          ..gasType = 'Nitrox'
          ..gasO2Text = '50'
          ..gasMaxDepthText = '30'
          ..gasPhase = 'ascent';
      })
      ..addGas();
    expect(
      c.gasStatusText,
      startsWith("Note: EAN50's range goes to 30m but its MOD at PO2 1.6 is"),
    );
    expect(c.gasTableRows[1].take(4), ['EAN50', 'NITROX', '50', '0']);
    expect(c.gasTableRows[1].last, '0-30m ↑');
    expect(c.gasTableRows[1][4], startsWith('T2 11.1L/207'));

    c
      ..editGasField(() => c.gasNameText = 'Air')
      ..addGas();
    expect(
      c.gasStatusText,
      "Could not add gas: another gas is already named 'Air'",
    );
    c
      ..editGasField(() {
        c
          ..gasNameText = 'Deep'
          ..gasMinDepthText = '30'
          ..gasMaxDepthText = '20';
      })
      ..addGas();
    expect(c.gasStatusText, contains("the 'from' depth must be shallower"));

    // Rename the selected gas: its waypoints follow.
    final (x, y) = at(c, 120, 10);
    c
      ..addWaypointAt(x, y)
      ..selectGasRow(0)
      ..editGasField(() => c.gasNameText = 'Back gas')
      ..addGas();
    expect(c.plan.gases.first.id, 'Back gas');
    expect(c.plan.waypoints.single.gasId, 'Back gas');
    c.removeGasAt(1);
    expect(c.plan.gases.map((g) => g.id), ['Back gas']);
    c.dispose();
  });

  test('sidemount: the left tank, its twin offered, the same gas', () {
    final c = controller()..selectDiveType('Sidemount');
    expect(c.plan.gases.single.side, 'left');
    c.newGas();
    expect(c.gasSide, 'right');
    expect(c.gasNameText, 'Air R');
    expect(c.gasTankText, 'T2');
    c
      ..editGasField(() => c.gasO2Text = '32')
      ..addGas();
    expect(c.gasStatusText, contains('must hold the same gas'));
    c
      ..editGasField(() => c.gasO2Text = '21')
      ..addGas();
    expect(c.gasStatusText, isEmpty);
    expect(c.gasTableRows[1][4], startsWith('T2 Right'));
    c.dispose();
  });

  test('saved in each format, opened again; another log imported', () {
    final c = controller()..defineScale('30', '40');
    for (final (t, d) in [(120, 25.0), (1500, 25.0)]) {
      final (x, y) = at(c, t, d);
      c.addWaypointAt(x, y);
    }
    c
      ..endDive()
      ..setStartTime('2026-03-05 10:00')
      ..setName('Reef dive');
    expect(c.suggestedLogName, 'Reef_dive.uddf');
    // A FIT comes from a Garmin.
    final refused = c.saveLog(p.join(tmp.path, 'x.fit'), 'Garmin FIT (*.fit)');
    expect(refused.ok, isFalse);
    expect(refused.message, contains("doesn't write them"));
    c.selectComputer('Garmin Descent Mk3i');
    final expected = c.plan.toJson();
    for (final ext in ['.uddf', '.fit', '.ssrf']) {
      final format = logFormats.entries.firstWhere((e) => e.value == ext).key;
      final picked = p.join(tmp.path, 'reef');
      final result = c.saveLog(picked, format);
      expect(result.ok, isTrue, reason: result.message);
      expect(result.message, startsWith('Dive log written to:\n$picked$ext'));
      expect(config.fields()[logFormatField], format);

      final opened = controller();
      expect(
        opened.loadLog('$picked$ext'),
        'Opened reef$ext: plan restored as saved',
      );
      expect(
        jsonEncode(opened.plan.toJson()['waypoints']),
        jsonEncode(expected['waypoints']),
      );
      expect(opened.plan.name, 'Reef dive');
      opened.dispose();
    }
    expect(c.saveLog(p.join(tmp.path, 'x.txt'), 'nothing').ok, isFalse);

    final uddf = base64.decode(
      ((jsonDecode(
                    File('test/fixtures/python_reference/dives/uddf.json')
                        .readAsStringSync(),
                  ) as Map<String, dynamic>)['parse']
                  as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .first['bytes_base64']
          as String,
    );
    final other = File(p.join(tmp.path, 'other.uddf'))..writeAsBytesSync(uddf);
    expect(c.openLog(other.path), isNull);
    expect(
      c.endDiveStatusText,
      startsWith('Imported other.uddf: plan rebuilt'),
    );
    expect(c.plan.waypoints, isNotEmpty);
    expect(
      c.openLog(p.join(tmp.path, 'notes.txt')),
      contains('does not exist'),
    );
    c.dispose();
  });

  test('the units switched: texts follow, the plan stays SI', () {
    final c = controller()..defineScale('30', '40');
    config.updateSettings({'units': 'imperial'});
    c.unitsChanged();
    expect(c.maxDepthText, '98.4');
    expect(c.gasStartPressureText, '3002');
    expect(c.waypointHeaders[1], 'Depth (ft)');
    c.setMaxDepth('100');
    expect(c.plan.maxDepthM, closeTo(30.48, 1e-9));
    c.dispose();
  });

  test('a selected waypoint: kept by time, Update in feet', () {
    final c = controller()..defineScale('40', '40');
    final (x, y) = at(c, 120, 30);
    c
      ..addWaypointAt(x, y)
      ..selectWaypointRow(0);
    expect(c.selectedWaypointRow, 0);
    config.updateSettings({'units': 'imperial'});
    c
      ..unitsChanged()
      ..selectWaypointRow(0);
    expect(c.wpDepthText, '98.4');
    c.addOrUpdateWaypoint();
    expect(c.plan.waypoints.single.depthM, closeTo(30, 0.02));
    expect(c.selectedWaypointRow, isNull);
    c.dispose();
  });

  testWidgets('on screen: a right-click deletes and places nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    config.updateSettings({
      'fields': {
        'dive_profile_max_depth': 30,
        'dive_profile_planned_runtime_sec': 2400,
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: DiveProfilePage(
            services: AppServices(
              capabilities: const Capabilities(desktop: true),
              config: config,
              home: '/Users/x',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chart = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ProfilePainter,
    );
    final origin = tester.getTopLeft(chart);
    final scale = tester.getSize(chart).width / canvasWidth;
    final (x, y) = xyOf(600, 20, canvasWidth, canvasHeight, (2400.0, 33.0));
    await tester.tapAt(origin + Offset(x, y) * scale);
    await tester.pumpAndSettle();
    expect(find.textContaining('(auto)'), findsOneWidget);
    // The click lands where it points: 10:00 at 20 m.
    expect(find.text('10:00'), findsWidgets);
    expect(find.text('20.0'), findsOneWidget);
    final point = tester.widget<CustomPaint>(chart).painter! as ProfilePainter;
    final wp = point.plan.sortedWaypoints().single;
    final axes = chartAxes(point.plan, point.samples)!;
    final (wx, wy) = xyOf(
      wp.runtimeSec,
      wp.depthM,
      canvasWidth,
      canvasHeight,
      axes,
    );
    await tester.tapAt(
      origin + Offset(wx, wy) * scale,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('(auto)'), findsNothing);
  });

  testWidgets('on screen: a log opened from the imported logs', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final uddf = base64.decode(
      ((jsonDecode(
                    File('test/fixtures/python_reference/dives/uddf.json')
                        .readAsStringSync(),
                  ) as Map<String, dynamic>)['parse']
                  as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .first['bytes_base64']
          as String,
    );
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: config,
      home: '/Users/x',
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    final kept = services.logStore.folder..createSync(recursive: true);
    File(p.join(kept.path, 'reef.uddf')).writeAsBytesSync(uddf);
    final before = config.dialogDirFor(logDirField, home: '/Users/x');
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(body: DiveProfilePage(services: services)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(openLogLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(importedLogsPlaceLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('reef.uddf'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Imported reef.uddf: plan rebuilt'),
      findsOneWidget,
    );
    // The app's own folder is not where the file dialog opens next.
    expect(config.dialogDirFor(logDirField, home: '/Users/x'), before);
  });

  testWidgets('on screen: the chart asks for its scale first', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: DiveProfilePage(
            services: AppServices(
              capabilities: const Capabilities(desktop: true),
              config: config,
              home: '/Users/x',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dive settings'), findsOneWidget);
    expect(find.text('Gases'), findsOneWidget);
    await tester.tapAt(
      tester.getTopLeft(
            find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is ProfilePainter,
            ),
          ) +
          const Offset(300, 200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Set up the dive profile'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Max depth (m)').last,
      '30',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Planned runtime (min)').last,
      '40',
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('(auto)'), findsOneWidget);
  });
}
