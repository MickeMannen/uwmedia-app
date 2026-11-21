/// Paths as the pages show them (Python `utils/display_paths.py`). Only
/// for display: what the app works with is always the path itself.
library;

/// `/Users/<name>/…` as `~/…` (`C:\Users\<name>\…` as `~\…`). [home]
/// is the user's home folder, `null` when the platform has none to name
/// (the path is shown as it is).
String? contractHomePath(String? path, String? home) {
  if (path == null || path.isEmpty || home == null || home.isEmpty) {
    return path;
  }
  if (path == home) {
    return '~';
  }
  // On Windows also under a backslash, which Python missed (spec §10.86).
  final windows = home.contains(r'\');
  return path.startsWith('$home/') || (windows && path.startsWith('$home\\'))
      ? '~${path.substring(home.length)}'
      : path;
}
