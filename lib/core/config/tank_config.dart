/// The tank sensor names and their order, ported from the mapping in
/// `utils/config.py` of the Python app (spec §4.1): transmitter serial to
/// the name the diver gave the tank. The order of the mapping is the tank
/// order: the first listed tank is an overlay's primary tank, the second
/// its secondary.
///
/// The port adds each tank's size, for VSAC on dives whose log has
/// pressures but no size and no VSAC (spec §10.54). Python keeps the
/// `tank_sizes` section when it saves the file and does not read it.
///
/// The port also adds, for a sidemount overlay (spec §10.104): a second
/// name per sensor (`tank_sidemount_names`) and the side it is worn on
/// (`tank_sides`), and for a size given in cubic feet the pressure it is
/// rated at (`tank_working_bar`).
///
/// [ConfigFile] is `config.yaml` as text; where the file lies and reading
/// and writing it belong to the settings storage.
library;

import 'package:uwmedia_app/core/config/yaml_text.dart';
import 'package:uwmedia_app/core/units/units.dart';

/// The side a sidemount tank is worn on.
enum TankSide {
  left,
  right;

  /// As `config.yaml` has it; `null` for anything else.
  static TankSide? parse(String value) => switch (value.trim().toLowerCase()) {
    'left' => left,
    'right' => right,
    _ => null,
  };
}

class TankConfig {
  /// [tanks] is serial to name, in tank order; [sizes] serial to the
  /// tank's water volume in litres.
  TankConfig([
    Map<String, String> tanks = const {},
    Map<String, double> sizes = const {},
    Map<String, String> sidemountNames = const {},
    Map<String, TankSide> sides = const {},
    Map<String, double> workingBar = const {},
  ]) : tanks = Map.unmodifiable(tanks),
       sizes = Map.unmodifiable(sizes),
       sidemountNames = Map.unmodifiable(sidemountNames),
       sides = Map.unmodifiable(sides),
       workingBar = Map.unmodifiable(workingBar);

  /// Serial to name, in tank order.
  final Map<String, String> tanks;

  /// Serial to the tank's water volume in litres, for the tanks that have
  /// one.
  final Map<String, double> sizes;

  /// Serial to the name the tank has on a sidemount overlay, for the tanks
  /// that have another one there (spec §10.104).
  final Map<String, String> sidemountNames;

  /// Serial to the side the tank is worn on in sidemount.
  final Map<String, TankSide> sides;

  /// Serial to the pressure in bar the tank is rated at: what a size in
  /// cubic feet is counted at ([cubicFeetOf]). The size kept is litres.
  final Map<String, double> workingBar;

  /// The sidemount name by tank key ([mapTankName]); two serials with one
  /// name: the first one's.
  Map<String, String> get sidemountNamesByKey {
    final byKey = <String, String>{};
    for (final MapEntry(key: serial, value: name) in sidemountNames.entries) {
      byKey.putIfAbsent(mapTankName(serial), () => name);
    }
    return byKey;
  }

  /// The side by tank key ([mapTankName]); two serials with one name: the
  /// first one's.
  Map<String, TankSide> get sidesByKey {
    final byKey = <String, TankSide>{};
    for (final MapEntry(key: serial, value: side) in sides.entries) {
      byKey.putIfAbsent(mapTankName(serial), () => side);
    }
    return byKey;
  }

  /// The sizes by tank key, the name [mapTankName] gives the serial: what
  /// a dive's `tankVolumesL` holds. Two serials with one name: the first
  /// one's size.
  Map<String, double> get sizesByKey {
    final byKey = <String, double>{};
    for (final MapEntry(key: serial, value: litres) in sizes.entries) {
      byKey.putIfAbsent(mapTankName(serial), () => litres);
    }
    return byKey;
  }

  /// The name of the tank with this serial, or the serial itself when it
  /// has none.
  String mapTankName(String serial) => tanks[serial] ?? serial;

  /// Tank keys (as [mapTankName] names them) in the mapping's order. Two
  /// serials with one name share the first one's place; keys the mapping
  /// does not list come after, in the order given.
  List<String> orderTanks(Iterable<String> keys) {
    final rank = <String, int>{};
    for (final name in tanks.values) {
      rank.putIfAbsent(name, () => rank.length);
    }
    final indexed = keys.indexed.toList()
      ..sort((a, b) {
        final byRank = (rank[a.$2] ?? rank.length).compareTo(
          rank[b.$2] ?? rank.length,
        );
        // Python's sorted() is stable; List.sort is not promised to be.
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });
    return [for (final (_, key) in indexed) key];
  }

  /// The mapping with the serials it does not know yet added as
  /// `Tank <serial>`, in sorted order, after the tanks already named.
  TankConfig withSerials(Iterable<String> serials) {
    final next = Map<String, String>.of(tanks);
    for (final serial in serials.toList()..sort()) {
      next.putIfAbsent(serial, () => 'Tank $serial');
    }
    return TankConfig(next, sizes, sidemountNames, sides, workingBar);
  }

  /// The mapping with one tank named or renamed, keeping its place.
  TankConfig withTankName(String serial, String name) => TankConfig(
    {...tanks, serial: name},
    sizes,
    sidemountNames,
    sides,
    workingBar,
  );

  /// The mapping with one tank's size set, or cleared with `null`.
  TankConfig withTankSize(String serial, double? litres) => TankConfig(
    tanks,
    litres == null
        ? (Map.of(sizes)..remove(serial))
        : {...sizes, serial: litres},
    sidemountNames,
    sides,
    workingBar,
  );

  /// The mapping without one tank, its size included.
  TankConfig withoutTank(String serial) => TankConfig(
    Map.of(tanks)..remove(serial),
    Map.of(sizes)..remove(serial),
    Map.of(sidemountNames)..remove(serial),
    Map.of(sides)..remove(serial),
    Map.of(workingBar)..remove(serial),
  );
}

/// A tank size the app accepts, in litres.
bool validTankSize(double litres) => litres > 0 && litres <= 100;

/// The pressure a size in cubic feet is counted at when none is given:
/// 3000 psi, an AL80's.
const double defaultWorkingBar = 3000 / psiPerBar;

/// A rated pressure the app accepts, in bar.
bool validWorkingBar(double bar) => bar >= 50 && bar <= 400;

/// A tank's size in cubic feet: the gas its [litres] of water volume hold
/// at [workingBar], as the app counts gas (pressure times size, spec
/// §10.54). An AL80 of 77.4 cu ft at 3000 psi is 10.6 l by this.
double cubicFeetOf(double litres, double workingBar) =>
    litres * workingBar * cuftPerL;

/// The water volume in litres of a tank of [cubicFeet] at [workingBar].
double litresOfCubicFeet(double cubicFeet, double workingBar) =>
    cubicFeet / cuftPerL / workingBar;

/// The file name of the tank names.
const configYamlName = 'config.yaml';

/// `config.yaml`: the tank mapping under `tanks`, the port's own sections
/// (`tank_sizes`, `tank_sidemount_names`, `tank_sides`,
/// `tank_working_bar`), and whatever else the file holds, which is kept.
class ConfigFile {
  /// From the file's text; `null` when there is no file. A file that
  /// cannot be read, or holds something else than a map, counts as empty
  /// (Python fails on the latter).
  ConfigFile.parse(String? text)
    : data = readYamlMap(text),
      unreadable = yamlUnreadable(text);

  /// The file is there but cannot be read (see [yamlUnreadable]): what it
  /// holds is lost when it is saved over.
  final bool unreadable;

  /// The file's top-level map, as [readYaml] gives it.
  final Map<String, Object?> data;

  /// The tank mapping. Serials and names are text even when the file has
  /// them without quotes (`3456789: Left`), and then exactly the text of
  /// the file: a serial `0123` keeps its zero, which Python reads as a
  /// number and loses. A size that is not a number in range is left out.
  TankConfig get tanks {
    final section = data['tanks'];
    final sizes = data['tank_sizes'];
    final names = data['tank_sidemount_names'];
    final sides = data['tank_sides'];
    final working = data['tank_working_bar'];
    return TankConfig(
      {
        if (section is Map<String, Object?>)
          for (final MapEntry(:key, :value) in section.entries)
            if (value is String || value is YamlPlain)
              // Python's str(None).
              key: value is YamlPlain && value.value == null
                  ? 'None'
                  : '$value',
      },
      {
        if (sizes is Map<String, Object?>)
          for (final MapEntry(:key, :value) in sizes.entries)
            if (yamlValue(value) case final num litres
                when validTankSize(litres.toDouble()))
              key: litres.toDouble(),
      },
      {
        if (names is Map<String, Object?>)
          for (final MapEntry(:key, :value) in names.entries)
            if ((value is String || value is YamlPlain) &&
                yamlValue(value) != null &&
                '$value'.trim().isNotEmpty)
              key: '$value'.trim(),
      },
      {
        if (sides is Map<String, Object?>)
          for (final MapEntry(:key, :value) in sides.entries)
            key: ?TankSide.parse('$value'),
      },
      {
        if (working is Map<String, Object?>)
          for (final MapEntry(:key, :value) in working.entries)
            if (yamlValue(value) case final num bar
                when validWorkingBar(bar.toDouble()))
              key: bar.toDouble(),
      },
    );
  }

  /// The file's text with the mapping and the port's sections replaced by
  /// [tanks] (a section with nothing in it is left out); the rest of the
  /// file stays, comments aside.
  String withTanks(TankConfig tanks) => writeYaml({
    for (final MapEntry(:key, :value) in data.entries)
      if (!_ownSections.contains(key)) key: value,
    'tanks': tanks.tanks,
    if (tanks.sizes.isNotEmpty) 'tank_sizes': tanks.sizes,
    if (tanks.sidemountNames.isNotEmpty)
      'tank_sidemount_names': tanks.sidemountNames,
    if (tanks.sides.isNotEmpty)
      'tank_sides': {
        for (final MapEntry(:key, :value) in tanks.sides.entries)
          key: value.name,
      },
    if (tanks.workingBar.isNotEmpty) 'tank_working_bar': tanks.workingBar,
  });

  static const _ownSections = {
    'tank_sizes',
    'tank_sidemount_names',
    'tank_sides',
    'tank_working_bar',
  };
}
