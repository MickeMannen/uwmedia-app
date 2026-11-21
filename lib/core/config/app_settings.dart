/// The app's settings as text (Python `utils/app_settings.py`,
/// `settings.json`): what is kept, the defaults, and each change as a new
/// text. Where the file lies and reading and writing it belong to the
/// settings storage.
library;

import 'dart:convert';

const settingsFilename = 'settings.json';

/// The settings an empty file stands for.
Map<String, dynamic> defaultSettings() => {
  // null: the default place in the data or config folder
  'layouts_dir': null,
  'templates_dir': null,
  'color_profiles_dir': null,
  // null: found on the PATH or where it is usually installed
  'ffmpeg_path': null,
  'exiftool_path': null,
  'filename_formats': <dynamic>[],
  'render_log_filename_formats': <dynamic>[],
  // "metric" (m, bar, °C) or "imperial" (ft, psi, °F) for everything the
  // app shows; the data stays SI
  'units': 'metric',
  // The last value of every remembered form field, by the field's name.
  'fields': <String, dynamic>{},
};

/// The settings of a file's text over the defaults; the defaults alone
/// when there is no file or it cannot be read.
Map<String, dynamic> loadSettings(String? text) {
  final data = defaultSettings();
  if (text != null) {
    try {
      final stored = jsonDecode(text);
      if (stored is Map<String, dynamic>) {
        data.addAll(stored);
      }
    } on FormatException {
      // A broken file counts as none.
    }
  }
  return data;
}

/// The settings as the file's text.
String settingsText(Map<String, dynamic> data) =>
    const JsonEncoder.withIndent('  ').convert(data);

Map<String, dynamic> _fields(Map<String, dynamic> data) {
  final fields = data['fields'];
  return fields is Map<String, dynamic> ? fields : const {};
}

/// The remembered form fields.
Map<String, dynamic> settingsFields(Map<String, dynamic> data) => _fields(data);

/// The settings with one form field's value remembered.
Map<String, dynamic> withField(
  Map<String, dynamic> data,
  String key,
  Object? value,
) => {
  ...data,
  'fields': {..._fields(data), key: value},
};

/// The settings with [value] added to the list at [key], unless it is in
/// it already.
Map<String, dynamic> withUnique(
  Map<String, dynamic> data,
  String key,
  String value,
) {
  final items = [...?(data[key] as List<dynamic>?)];
  return {
    ...data,
    key: items.contains(value) ? items : [...items, value],
  };
}

/// Where a file dialog starts before anything was picked in it (owner,
/// 2026-11-20): photos and videos in the user's Pictures folder, dive logs
/// in Downloads, where an export lands, the rest in the home folder.
enum StartFolder { home, pictures, downloads }

/// The folder a file dialog starts in: the one last remembered under the
/// form field [key] when [isFolder] says it is still there, else [start]
/// when it is there, else [home]; never the process's working folder,
/// which is `/` for an app started from the Finder.
String dialogDir(
  Map<String, dynamic> data,
  String key, {
  required String home,
  required bool Function(String path) isFolder,
  String? start,
}) {
  final saved = _fields(data)[key];
  if (saved is String && saved.isNotEmpty && isFolder(saved)) {
    return saved;
  }
  return start != null && start.isNotEmpty && isFolder(start) ? start : home;
}
