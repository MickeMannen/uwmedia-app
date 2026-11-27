// The tanks of a sidemount overlay (spec §10.104): the sensor marked left
// first and the one marked right second, each under its sidemount name;
// an overlay with one tank is drawn from the dive's tanks as they are.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/sidemount_tanks.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import 'template_tree_test.dart' show bundledFolder;

Waypoint _waypoint(Map<String, double> tanks) => Waypoint(
  timestamp: naive(2026, 11, 25, 10),
  timeSinceStart: 60,
  depth: 12,
  tanks: {
    for (final MapEntry(:key, :value) in tanks.entries)
      key: TankData(pressureBar: value),
  },
);

void main() {
  group('the order and the names', () {
    // Sensors 1 to 4, named as on a single-tank overlay.
    final config = TankConfig(
      {'1': 'Micke01', '2': 'Micke02', '3': 'Stage', '4': 'Old'},
      const {},
      {'1': 'Left', '2': 'Right'},
      {'1': TankSide.left, '2': TankSide.right},
    );
    final tanks = SidemountTanks(config);

    test('by tank key, the name a dive has the sensor under', () {
      expect(tanks.sides, {
        'Micke01': TankSide.left,
        'Micke02': TankSide.right,
      });
      expect(tanks.names, {'Micke01': 'Left', 'Micke02': 'Right'});
      expect(tanks.isEmpty, isFalse);
      expect(SidemountTanks(TankConfig({'1': 'A'})).isEmpty, isTrue);
    });

    test('left first, right second, the rest as they were', () {
      expect(tanks.order(['Micke02', 'Stage', 'Micke01']), [
        'Micke01',
        'Micke02',
        'Stage',
      ]);
      expect(tanks.order(['Stage', 'Micke02']), ['Stage', 'Micke02']);
      expect(tanks.order(['Micke02']), ['Micke02']);
      expect(tanks.order(['Stage', 'Old', 'Micke01']), [
        'Micke01',
        'Stage',
        'Old',
      ]);
      expect(tanks.order(['Old', 'Stage']), ['Old', 'Stage']);
      expect(tanks.order([]), isEmpty);
    });

    test('a waypoint\'s view: reordered and renamed, the rest untouched', () {
      final wp = _waypoint({'Micke02': 150, 'Micke01': 180, 'Stage': 200});
      final view = tanks.view(wp);
      expect(view.tanks.keys, ['Micke01', 'Micke02', 'Stage']);
      expect(view.primaryTankName, 'Left');
      expect(view.primaryTankPressure, 180);
      expect(view.secondaryTankName, 'Right');
      expect(view.secondaryTankPressure, 150);
      expect(view.tanks['Stage']!.name, isNull);
      expect(view.toJson()..remove('tanks'), wp.toJson()..remove('tanks'));
      expect(wp.primaryTankName, 'Micke02', reason: 'the waypoint is not');
      expect(identical(tanks.view(wp), view), isTrue, reason: 'made once');

      final other = _waypoint({'Stage': 200, 'Old': 100});
      expect(identical(tanks.view(other), other), isTrue);
      expect(identical(SidemountTanks(TankConfig()).view(wp), wp), isTrue);
    });
  });

  group('drawn', () {
    final tree = TemplateTree(bundled: bundledFolder());
    HudRenderer renderer() => HudRenderer(
      TtfFonts(
        (file) => File('assets/fonts/$file').readAsBytesSync(),
        inkTables: InkTables.parse(
          File('assets/fonts/ink_tables.bin').readAsBytesSync(),
        ),
      ),
      HudRules(
        jsonDecode(File('assets/hud_rules.json').readAsStringSync())
            as Map<String, dynamic>,
      ),
    );
    Map<String, dynamic> layout(String variant) => jsonDecode(
      File(
        tree
            .resolveState('generic', 'simple', 'row_dark', variant: variant)!
            .replaceFirst('bundled/', 'assets/overlays/templates/'),
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    // The sample pair's tanks are keyed "Left" and "Right".
    final pair = buildDummyDive(variant: 'sidemount');
    final swapped = SidemountTanks(
      TankConfig(
        {'1': 'Left', '2': 'Right'},
        const {},
        {'1': 'Starboard', '2': 'Port'},
        {'1': TankSide.right, '2': TankSide.left},
      ),
    );
    String drawn(HudRenderer renderer, Map<String, dynamic> layout) =>
        jsonEncode([
          for (final op in renderer.drawHud(
            frameWidth: 1920,
            frameHeight: 1080,
            layout: layout,
            waypoint: waypointAt(pair, 600),
            waypoints: pair.waypoints,
          ))
            op.toJson(),
        ]);

    test('which overlay is a sidemount one', () {
      expect(showsSecondTank(layout('sidemount')), isTrue);
      expect(showsSecondTank(layout('single_tank')), isFalse);
      expect(showsSecondTank({}), isFalse);
    });

    test('a sidemount overlay takes the sides and the sidemount names', () {
      final plain = drawn(renderer(), layout('sidemount'));
      expect(plain, contains('"Left"'));
      expect(plain, isNot(contains('"Port"')));

      final named = drawn(renderer()..sidemount = swapped, layout('sidemount'));
      expect(named, contains('"Port"'));
      expect(named, contains('"Starboard"'));
      expect(named, isNot(contains('"Left"')));
      expect(
        named.indexOf('"Port"'),
        lessThan(named.indexOf('"Starboard"')),
        reason: 'the sensor marked left is the first tank',
      );
    });

    test('the notice along the dive names the same tanks: "Breathe from '
        'Left Tank" with the sidemount name of the tank marked left', () {
      // The Descent X50i's sidemount page, which has Garmin's notice.
      final loaded = loadLayoutFile(
        tree
            .resolveState('garmin', 'x50i', 'main', variant: 'sidemount')!
            .replaceFirst('bundled/', 'assets/overlays/templates/'),
        (path) => File(path).readAsStringSync(),
      );
      // The texts drawn, in a row (the notice is wrapped over lines).
      String at(HudRenderer renderer, int seconds) => [
        for (final op in renderer.drawHud(
          frameWidth: 1920,
          frameHeight: 1080,
          layout: loaded,
          waypoint: waypointAt(pair, seconds),
          waypoints: pair.waypoints,
          skinSize: (640, 360),
        ))
          if (op.toJson() case ['text', _, _, final String text, ...]) text,
      ].join(' ');
      final plain = renderer();
      // The sample pair starts on its first tank ("Left") and is told to
      // change to the other; the notice shows for some seconds.
      final toSecond = [
        for (var t = 0; t < 1300; t++)
          if (at(plain, t).contains('Breathe from Right Tank (Right).')) t,
      ];
      expect(toSecond, isNotEmpty);

      // The sensors swapped: the tank keyed "Right" is worn left and is
      // called Port in sidemount, the one keyed "Left" Starboard.
      final named = renderer()..sidemount = swapped;
      expect(
        at(named, toSecond.first),
        contains('Breathe from Left Tank (Port).'),
      );
      expect(at(named, toSecond.first), isNot(contains('(Right)')));
    });

    test('a dive\'s list is viewed once, and left alone when nothing '
        'changes', () {
      final all = swapped.viewAll(pair.waypoints);
      expect(identical(swapped.viewAll(pair.waypoints), all), isTrue);
      expect(all.length, pair.waypoints.length);
      expect(all.first.primaryTankName, 'Port');
      expect(identical(all[5], swapped.view(pair.waypoints[5])), isTrue);
      final single = buildDummyDive();
      expect(
        identical(swapped.viewAll(single.waypoints), single.waypoints),
        isTrue,
      );
      expect(
        identical(
          SidemountTanks(TankConfig()).viewAll(pair.waypoints),
          pair.waypoints,
        ),
        isTrue,
      );
    });

    test('an overlay with one tank is drawn as before', () {
      final single = layout('single_tank');
      expect(
        drawn(renderer()..sidemount = swapped, single),
        drawn(renderer(), single),
      );
    });
  });
}
