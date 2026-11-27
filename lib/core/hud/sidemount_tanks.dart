/// The tanks as a sidemount overlay shows them (spec §10.104): the tank
/// worn on the left first and the one on the right second, whatever the
/// tank order is, each under the name it has in sidemount.
///
/// A dive's tanks are keyed by the name the Tank Sensor Names window gives
/// the sensor, in the window's order (spec §4.1), which is what an overlay
/// with one tank shows. An overlay that shows a second tank is a sidemount
/// one ([showsSecondTank]); for it the renderer takes each waypoint through
/// [SidemountTanks.view].
library;

import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';

final Expando<bool> _secondTank = Expando<bool>();

/// The layout has an element of the second tank (`secondary_tank_pressure`,
/// `secondary_tank_name`, the tank icon on it): a sidemount overlay.
bool showsSecondTank(Map<String, dynamic> layout) {
  final known = _secondTank[layout];
  if (known != null) {
    return known;
  }
  final skin = layout['hud_skin'];
  final elements = skin is Map<String, dynamic>
      ? skin['linked_elements']
      : null;
  final found =
      elements is List<dynamic> &&
      elements.any(
        (e) =>
            e is Map<String, dynamic> &&
            '${e['field'] ?? ''}'.startsWith('secondary_tank'),
      );
  return _secondTank[layout] = found;
}

class SidemountTanks {
  /// From the saved sensor names: the sides and the sidemount names by
  /// tank key.
  SidemountTanks(TankConfig config)
    : sides = config.sidesByKey,
      names = config.sidemountNamesByKey;

  /// Tank key to the side it is worn on.
  final Map<String, TankSide> sides;

  /// Tank key to its name on a sidemount overlay.
  final Map<String, String> names;

  final Expando<Waypoint> _views = Expando<Waypoint>();
  final Expando<List<Waypoint>> _lists = Expando<List<Waypoint>>();

  /// Nothing is set: every waypoint is its own view.
  bool get isEmpty => sides.isEmpty && names.isEmpty;

  /// The tank keys in sidemount order: the first one marked left in the
  /// first place and the first one marked right in the second; a place
  /// with no tank marked for it takes the next unmarked one, and the rest
  /// follow as they were.
  List<String> order(Iterable<String> keys) {
    final all = keys.toList();
    String? marked(TankSide side) {
      for (final key in all) {
        if (sides[key] == side) {
          return key;
        }
      }
      return null;
    }

    final left = marked(TankSide.left);
    final right = marked(TankSide.right);
    if (left == null && right == null) {
      return all;
    }
    final rest = [
      for (final key in all)
        if (key != left && key != right) key,
    ];
    return [
      if (left != null) left else if (rest.isNotEmpty) rest.removeAt(0),
      ?right,
      ...rest,
    ];
  }

  /// A dive's [waypoints] as a sidemount overlay shows them, each its
  /// [view]: what the rules that look along the dive read (the notices,
  /// "Breathe from Left Tank (…)" among them). The list itself when
  /// nothing changes. A list's view is made once, so what the rules keep
  /// by the list stays kept.
  List<Waypoint> viewAll(List<Waypoint> waypoints) {
    if (isEmpty) {
      return waypoints;
    }
    final known = _lists[waypoints];
    if (known != null) {
      return known;
    }
    var same = true;
    final views = [
      for (final waypoint in waypoints)
        () {
          final seen = view(waypoint);
          same = same && identical(seen, waypoint);
          return seen;
        }(),
    ];
    return _lists[waypoints] = same ? waypoints : views;
  }

  /// [waypoint] as a sidemount overlay shows it: the tanks in [order], a
  /// tank with a sidemount name under that name. The waypoint itself when
  /// nothing changes. A waypoint's view is made once.
  Waypoint view(Waypoint waypoint) {
    if (isEmpty || waypoint.tanks.isEmpty) {
      return waypoint;
    }
    final known = _views[waypoint];
    if (known != null) {
      return known;
    }
    final keys = waypoint.tanks.keys.toList();
    final ordered = order(keys);
    var same = true;
    for (var i = 0; i < keys.length; i++) {
      if (keys[i] != ordered[i] || names.containsKey(keys[i])) {
        same = false;
        break;
      }
    }
    if (same) {
      return _views[waypoint] = waypoint;
    }
    return _views[waypoint] = waypoint.withTanks({
      for (final key in ordered)
        key: switch ((waypoint.tanks[key]!, names[key])) {
          (final tank, null) => tank,
          (final tank, final name?) => TankData(
            pressureBar: tank.pressureBar,
            o2Percent: tank.o2Percent,
            hePercent: tank.hePercent,
            name: name,
            mode: tank.mode,
            enabled: tank.enabled,
          ),
        },
    });
  }
}
