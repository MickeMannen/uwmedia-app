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

/// How a path inside one of the app's own folders is named on a page.
const ownFolderName = "UWMedia's own folder";

/// [path] as a Settings row shows it: one inside the app's own folders
/// ([own]: its config and data folders) by [ownFolderName] and what is
/// under it ("UWMedia's own folder › layouts"), as those folders' paths
/// are long and, in the Mac App Store's container, nowhere a user goes
/// (spec §10.113); any other path with the home folder as `~`.
String shownLocation(String path, Iterable<String> own, String? home) {
  String clean(String value) => value.replaceAll(r'\', '/');
  final at = clean(path);
  for (final folder in own) {
    final root = clean(folder);
    if (root.isEmpty) {
      continue;
    }
    if (at == root) {
      return ownFolderName;
    }
    if (at.startsWith('$root/')) {
      final rest = at.substring(root.length + 1).split('/');
      return [ownFolderName, ...rest].join(' › ');
    }
  }
  return contractHomePath(path, home) ?? path;
}
