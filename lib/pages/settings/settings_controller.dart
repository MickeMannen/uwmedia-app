/// The phones' Settings page (spec §0, roadmap section D): what the desktop keeps
/// on its Advanced page and its Color page's switches, in one place: the
/// unit system, the default colour profile, the output names, hardware
/// encoding, and the tank sensor names with their order. The values are
/// the same settings fields the desktop pages use.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/naming/filename_formats.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/pages/color/color_controller.dart'
    show colorProfileField, filenameFormatField, hwAccelSwitchField;
import 'package:uwmedia_app/pages/shared/tank_names.dart';

class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.config,
    required this.home,
    required this.bundledColorYaml,
    required this.onUnitsChanged,
  }) {
    tanks.addListener(notifyListeners);
  }

  final ConfigStore config;
  final String home;

  /// The app's own `color.yaml` (the bundled profiles).
  final String? bundledColorYaml;

  /// Told when the unit system changes, for the open pages to follow.
  final VoidCallback onUnitsChanged;

  late final TankNamesEditor tanks = TankNamesEditor(config: config);

  String statusText = '';
  bool _disposed = false;

  void _set(String key, Object? value) {
    try {
      config.setField(key, value);
      statusText = '';
    } on FileSystemException catch (e) {
      statusText = 'Could not save the setting: ${e.message}';
    }
    notifyListeners();
  }

  UnitSystem get units => normalizeUnits(config.settings()['units']);

  set units(UnitSystem value) {
    if (value == units) {
      return;
    }
    try {
      config.updateSettings({'units': value.key});
      statusText = '';
    } on FileSystemException catch (e) {
      statusText = 'Could not save the setting: ${e.message}';
      notifyListeners();
      return;
    }
    notifyListeners();
    onUnitsChanged();
  }

  /// The colour profiles, the bundled ones first.
  List<String> get profiles =>
      config.colorProfiles(bundledColorYaml).keys.toList();

  /// The profile the Color page starts with: the one saved, else the
  /// first.
  String get profile {
    final saved = config.fields()[colorProfileField];
    final names = profiles;
    return names.contains(saved) ? saved as String : names.first;
  }

  set profile(String name) {
    if (profiles.contains(name)) {
      _set(colorProfileField, name);
    }
  }

  /// The output name presets, by label.
  List<String> get filenameFormats => [
    for (final (label, _) in filenameFormatPresets) label,
  ];

  /// The preset in use (an earlier version's label read as today's).
  String get filenameFormat {
    var saved = config.fields()[filenameFormatField];
    saved = legacyPresetLabels[saved] ?? saved;
    return filenameFormats.contains(saved)
        ? saved as String
        : filenameFormats.first;
  }

  set filenameFormat(String label) {
    if (filenameFormats.contains(label)) {
      _set(filenameFormatField, label);
    }
  }

  /// Hardware encoding, on unless it was switched off.
  bool get hwAccel {
    final saved = config.fields()[hwAccelSwitchField];
    return saved is! bool || saved;
  }

  set hwAccel(bool value) => _set(hwAccelSwitchField, value);

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    tanks.dispose();
    super.dispose();
  }
}
