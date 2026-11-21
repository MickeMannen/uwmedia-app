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
/// [ConfigFile] is `config.yaml` as text; where the file lies and reading
/// and writing it belong to the settings storage.
library;

import 'package:uwmedia_app/core/config/yaml_text.dart';

class TankConfig {
  /// [tanks] is serial to name, in tank order; [sizes] serial to the
  /// tank's water volume in litres.
  TankConfig([
    Map<String, String> tanks = const {},
    Map<String, double> sizes = const {},
  ]) : tanks = Map.unmodifiable(tanks),
       sizes = Map.unmodifiable(sizes);

  /// Serial to name, in tank order.
  final Map<String, String> tanks;

  /// Serial to the tank's water volume in litres, for the tanks that have
  /// one.
  final Map<String, double> sizes;

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
    return TankConfig(next, sizes);
  }

  /// The mapping with one tank named or renamed, keeping its place.
  TankConfig withTankName(String serial, String name) =>
      TankConfig({...tanks, serial: name}, sizes);

  /// The mapping with one tank's size set, or cleared with `null`.
  TankConfig withTankSize(String serial, double? litres) => TankConfig(
    tanks,
    litres == null
        ? (Map.of(sizes)..remove(serial))
        : {...sizes, serial: litres},
  );

  /// The mapping without one tank, its size included.
  TankConfig withoutTank(String serial) =>
      TankConfig(Map.of(tanks)..remove(serial), Map.of(sizes)..remove(serial));
}

/// A tank size the app accepts, in litres.
bool validTankSize(double litres) => litres > 0 && litres <= 100;

/// The file name of the tank names.
const configYamlName = 'config.yaml';

/// `config.yaml`: the tank mapping under `tanks`, the sizes under
/// `tank_sizes` (the port's), and whatever else the file holds, which is
/// kept.
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
    );
  }

  /// The file's text with the mapping and the sizes replaced by [tanks]
  /// (no `tank_sizes` section when there are none); the rest of the file
  /// stays, comments aside.
  String withTanks(TankConfig tanks) => writeYaml({
    for (final MapEntry(:key, :value) in data.entries)
      if (key != 'tank_sizes') key: value,
    'tanks': tanks.tanks,
    if (tanks.sizes.isNotEmpty) 'tank_sizes': tanks.sizes,
  });
}
