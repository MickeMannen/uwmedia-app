/// The app's three config files on disk: `settings.json`, `config.yaml`
/// (the tank names) and `color.yaml` (the user's colour profiles), in the
/// config folder of `app_paths.dart` (Python `utils/app_settings.py`,
/// `utils/config.py`, `utils/color_profiles.py`: the reading and writing;
/// what the texts mean is in `app_settings.dart`, `tank_config.dart` and
/// `color_profiles.dart`).
///
/// A file is written in one step: the new text goes to a file beside it,
/// which then takes its place, so that a crash or a full disk leaves the
/// old file (the Python app writes over the file in place, spec §10.28).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/config/app_settings.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';

export 'package:uwmedia_app/core/config/app_settings.dart' show StartFolder;

const settingsFilename = 'settings.json';
const configYamlName = 'config.yaml';
const colorYamlName = 'color.yaml';

/// The settings key of the folder the user keeps `color.yaml` in, when
/// not the config folder.
const colorProfilesDirKey = 'color_profiles_dir';

/// Reads and writes the config files in the folder [configDir] gives
/// (`userConfigDir` in the app, a temporary folder in a test).
class ConfigStore {
  ConfigStore(this.configDir, {this.startFolders = const {}});

  final Directory Function() configDir;

  /// The user's Pictures and Downloads folders, where the dialogs of
  /// [StartFolder] start the first time (`start_folders.dart`); none in a
  /// test or on a phone, where they start in the home folder.
  final Map<StartFolder, String> startFolders;

  String? _read(String path) {
    try {
      final file = File(path);
      return file.existsSync() ? file.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      // Not text.
      return null;
    }
  }

  void _write(String path, String text) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final fresh = File('$path.new')..writeAsStringSync(text, flush: true);
    fresh.renameSync(path);
  }

  String get settingsPath => p.join(configDir().path, settingsFilename);

  /// The settings over the defaults; the defaults alone when there is no
  /// file or it cannot be read.
  Map<String, dynamic> settings() => loadSettings(_read(settingsPath));

  /// Throws a [FileSystemException] when the file cannot be written.
  void saveSettings(Map<String, dynamic> data) =>
      _write(settingsPath, settingsText(data));

  /// The settings with [changes] laid over them, saved.
  Map<String, dynamic> updateSettings(Map<String, dynamic> changes) {
    final data = {...settings(), ...changes};
    saveSettings(data);
    return data;
  }

  /// Remembers the value of one form field.
  void setField(String key, Object? value) =>
      saveSettings(withField(settings(), key, value));

  Map<String, dynamic> fields() => settingsFields(settings());

  /// Adds [value] to the settings list at [key], unless it is in it.
  Map<String, dynamic> addUnique(String key, String value) {
    final data = withUnique(settings(), key, value);
    saveSettings(data);
    return data;
  }

  /// The folder a file dialog behind the form field [key] starts in: the
  /// one last remembered when it is still there, else the [start] folder,
  /// else [home].
  String dialogDirFor(
    String key, {
    required String home,
    StartFolder start = StartFolder.home,
  }) => dialogDir(
    settings(),
    key,
    home: home,
    isFolder: (path) => Directory(path).existsSync(),
    start: startFolders[start],
  );

  void rememberDialogDir(String key, String folder) => setField(key, folder);

  String get configYamlPath => p.join(configDir().path, configYamlName);

  /// The tank names; an empty file's worth when there is none.
  ConfigFile tankConfig() => ConfigFile.parse(_read(configYamlPath));

  /// Writes `config.yaml` (the text of a [ConfigFile] after a change).
  void saveConfigYaml(String text) => _write(configYamlPath, text);

  /// The user's `color.yaml`: in the folder the settings name, else in
  /// the config folder.
  String get colorYamlPath {
    final override = settings()[colorProfilesDirKey];
    return p.join(
      override is String && override.isNotEmpty ? override : configDir().path,
      colorYamlName,
    );
  }

  /// The colour profiles: the bundled ones ([bundledText], the asset
  /// `assets/color.yaml`) with the user's own over them.
  Map<String, Map<String, Object?>> colorProfiles(String? bundledText) =>
      mergedColorProfiles(bundledText, _read(colorYamlPath));

  /// Puts [values] into the user's `color.yaml` as the profile [name],
  /// leaving every other profile in that file as it is. The bundled file
  /// is never touched: a profile saved as "default" is the user's own,
  /// which comes before the bundled one.
  void saveUserProfile(String name, Map<String, Object?> values) {
    final path = colorYamlPath;
    _write(path, withUserProfile(_read(path), name, values));
  }
}
