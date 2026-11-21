/// The Advanced page's state (Python `backends/advanced_backend.py`): the
/// unit system, the folders the app keeps the user's layouts, templates
/// and colour profiles in, the paths of ffmpeg and exiftool, and the tank
/// sensor names with their order.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/pages/shared/tank_names.dart';

export 'package:uwmedia_app/pages/shared/tank_names.dart'
    show fitLogsDirField, fitTankSerials;

/// The folder settings the page sets, by kind.
const folderKinds = {
  'layouts': 'layouts_dir',
  'templates': 'templates_dir',
  'color': 'color_profiles_dir',
};

const toolDirField = 'advanced_tool_dialog_dir';

/// The dialog folder field of a folder kind.
String folderDialogField(String kind) => 'advanced_${kind}_dialog_dir';

class AdvancedController extends ChangeNotifier {
  AdvancedController({
    required this.config,
    required this.home,
    required this.dataDir,
    required this.finder,
    required this.onUnitsChanged,
  }) {
    refreshTools();
  }

  final ConfigStore config;
  final String home;
  final Directory Function() dataDir;
  final ToolFinder Function() finder;

  /// Told when the unit system changes, for the open pages to follow.
  final VoidCallback onUnitsChanged;

  String _ffmpeg = '';
  String _exiftool = '';
  String _status = '';

  String get statusText => _status;
  String get ffmpegPathText => _ffmpeg;
  String get exiftoolPathText => _exiftool;

  /// The dialogs' folders: the FIT logs' starts in Downloads.
  String dialogDir(String field) => config.dialogDirFor(
    field,
    home: home,
    start: field == fitLogsDirField ? StartFolder.downloads : StartFolder.home,
  );

  void rememberDialogDir(String field, String folder) {
    try {
      config.rememberDialogDir(field, folder);
    } on FileSystemException {
      // Only not kept.
    }
  }

  // Saves [changes]; false, with the reason in the status, when the
  // settings could not be written.
  bool _update(Map<String, dynamic> changes) {
    try {
      config.updateSettings(changes);
      _status = '';
      return true;
    } on FileSystemException catch (e) {
      _status = 'Could not save the settings: ${e.message}';
      return false;
    }
  }

  // -- the video engine ----------------------------------------------------

  /// Which engine writes the videos on a desktop that has two
  /// ([videoEngineKey]).
  String get videoEngine =>
      config.settings()[videoEngineKey] == videoEngineNative
      ? videoEngineNative
      : videoEngineFfmpeg;

  set videoEngine(String value) {
    if (value == videoEngine) {
      return;
    }
    _update({videoEngineKey: value});
  }

  // -- units ---------------------------------------------------------------

  UnitSystem get units => normalizeUnits(config.settings()['units']);

  set units(UnitSystem value) {
    if (value == units) {
      return;
    }
    _update({'units': value.key});
    notifyListeners();
    onUnitsChanged();
  }

  // -- folders ---------------------------------------------------------------

  String _setting(String key) {
    final value = config.settings()[key];
    return value is String && value.isNotEmpty ? value : '';
  }

  /// The user's layouts folder (Python `user_layouts_dir`).
  String get layoutsDirText {
    final set = _setting('layouts_dir');
    return set.isNotEmpty ? set : p.join(dataDir().path, 'layouts');
  }

  /// The user's templates folder (Python `user_templates_dir`).
  String get templatesDirText =>
      userTemplatesFolder(config.settings(), dataDir());

  /// The folder of the user's `color.yaml`.
  String get colorDirText => p.dirname(config.colorYamlPath);

  /// Where the tank names are kept.
  String get tankNamesPathText => config.configYamlPath;

  /// A folder of [kind] ([folderKinds]) picked in the dialog.
  void setFolder(String kind, String path) {
    rememberDialogDir(folderDialogField(kind), path);
    _update({folderKinds[kind]!: path});
    notifyListeners();
  }

  /// A folder of [kind] back to the default.
  void resetFolder(String kind) {
    _update({folderKinds[kind]!: null});
    notifyListeners();
  }

  // -- tools -------------------------------------------------------------------

  int _toolsGeneration = 0;

  /// The paths of ffmpeg and exiftool as found now; a later refresh wins.
  Future<void> refreshTools() async {
    final generation = ++_toolsGeneration;
    final tools = finder();
    final settings = config.settings();
    _ffmpeg =
        await tools.resolve(toolFfmpeg, settings, ffmpegPathKey) ?? 'Not found';
    _exiftool =
        await tools.resolve(toolExiftool, settings, exiftoolPathKey) ??
        'Not found';
    if (generation == _toolsGeneration) {
      notifyListeners();
    }
  }

  /// The executable picked for [tool] (`ffmpeg` or `exiftool`) if it
  /// runs: `null`, else what to tell the user.
  Future<String?> setTool(String tool, String path) async {
    rememberDialogDir(toolDirField, p.dirname(path));
    final tools = finder();
    final ffmpeg = tool == toolFfmpeg;
    final ok = ffmpeg
        ? await tools.isValidFfmpeg(path)
        : await tools.isValidExiftool(path);
    if (!ok) {
      return "Running '$path ${ffmpeg ? '-version' : '-ver'}' didn't "
          "succeed, so this doesn't look like a working "
          '${ffmpeg ? 'ffmpeg' : 'exiftool'} executable. Please choose a '
          'different file.';
    }
    if (!_update({ffmpeg ? ffmpegPathKey : exiftoolPathKey: path})) {
      notifyListeners();
      return _status;
    }
    await refreshTools();
    return null;
  }

  Future<void> resetTool(String tool) async {
    _update({tool == toolFfmpeg ? ffmpegPathKey : exiftoolPathKey: null});
    await refreshTools();
  }

  // -- the tank sensor names ---------------------------------------------------

  /// The names and their order (shared with the phones' Settings page).
  late final TankNamesEditor tanks = TankNamesEditor(config: config, home: home)
    ..addListener(notifyListeners);

  List<(String serial, String name)> get tankRows => tanks.rows;
  String get tankStatusText => tanks.statusText;
  bool get tankFileUnreadable => tanks.unreadable;
  void openTankNames() => tanks.open();
  void setTankName(String serial, String name) => tanks.setName(serial, name);
  void removeTank(String serial) => tanks.remove(serial);
  void moveTank(String serial, int step) => tanks.move(serial, step);
  bool addSerial(String text) => tanks.addSerial(text);
  Future<void> scanFolder(String folder) => tanks.scanFolder(folder);
  String? saveTankNames() => tanks.save();

  bool _disposed = false;

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
