/// Where the app keeps what it writes (spec §13; Python
/// `utils/resource_paths.py`). Every writable path in the app comes from
/// here: [userConfigDir], [userDataDir], [userCacheDir] and [appTempDir].
/// Nothing is ever written into the install location.
///
/// On the desktop the folders are the Python app's own, so that both apps
/// read the same settings, tank names, colour profiles and templates:
///
/// |         | config | data | cache |
/// |---------|--------|------|-------|
/// | macOS   | `~/Library/Application Support/org.christersson.uwmedia/` | the same | `~/Library/Caches/org.christersson.uwmedia/` |
/// | Windows | `%APPDATA%\Christersson\UWMedia\` | `%LOCALAPPDATA%\Christersson\UWMedia\` | `%LOCALAPPDATA%\Christersson\UWMedia\Cache\` |
/// | Linux   | `$XDG_CONFIG_HOME/uwmedia/` | `$XDG_DATA_HOME/uwmedia/` | `$XDG_CACHE_HOME/uwmedia/` |
///
/// config: `settings.json`, `config.yaml`, `color.yaml`. data: `templates/`,
/// `layouts/`. cache: the working folders a run creates ([appTempDir]).
/// They are worked out from the environment the way the Python app's
/// `platformdirs` does, not asked of `path_provider`, whose desktop folders
/// follow the runner's own names and keep config and data in one place.
/// On a phone or tablet the folders are the app's sandbox, from
/// `path_provider`.
///
/// Earlier versions of the Python app kept everything in one folder
/// ("org.christersson.uwmedia", and "UWMedia" before that) under
/// Application Support, `%APPDATA%` or `$XDG_DATA_HOME`. The first time a
/// folder is created its contents are copied (not moved) from the first
/// of those that exists; the old folder is left as it was, so that an
/// older install keeps working.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const appId = 'org.christersson.uwmedia';
const appName = 'UWMedia';
const appAuthor = 'Christersson';
const appSlug = 'uwmedia';

/// The names the single folder of earlier versions had.
const legacyDataDirNames = [appId, 'UWMedia'];

/// The files that belong in the config folder; everything else is data.
const configFilenames = ['settings.json', 'config.yaml', 'color.yaml'];
const tempDirName = 'tmp';
const tempMaxAge = Duration(hours: 24);

/// Environment overrides: a portable or sandboxed install, and tests,
/// which point them at a temporary folder.
const envConfigDir = 'UWMEDIA_CONFIG_DIR';
const envDataDir = 'UWMEDIA_DATA_DIR';
const envCacheDir = 'UWMEDIA_CACHE_DIR';

/// The desktop systems, each with its own folder rules.
enum DesktopOs { macos, windows, linux }

/// The three folders, and where the single folder of earlier versions
/// lay (`null` where there never was one).
typedef AppDirs = ({
  String config,
  String data,
  String cache,
  String? legacyBase,
});

String? _set(Map<String, String> env, String name) {
  final value = env[name];
  return value == null || value.trim().isEmpty ? null : value;
}

/// The desktop folders for [os] from the environment [env], as the Python
/// app's `platformdirs` resolves them. Throws a [StateError] when the
/// environment names no home folder to start from.
AppDirs desktopAppDirs(DesktopOs os, Map<String, String> env) {
  final context = os == DesktopOs.windows ? p.windows : p.posix;
  final homeValue = os == DesktopOs.windows
      ? _set(env, 'USERPROFILE')
      : _set(env, 'HOME');
  String home() =>
      homeValue ?? (throw StateError('No home folder in the environment'));
  String override(String name, String Function() fallback) {
    final value = _set(env, name)?.trim();
    if (value == null) {
      return fallback();
    }
    // Python's expanduser.
    return value == '~'
        ? home()
        : (value.startsWith('~/') || value.startsWith(r'~\')
              ? context.join(home(), value.substring(2))
              : value);
  }

  switch (os) {
    case DesktopOs.macos:
      String library(String folder) =>
          context.join(home(), 'Library', folder, appId);
      return (
        config: override(envConfigDir, () => library('Application Support')),
        data: override(envDataDir, () => library('Application Support')),
        cache: override(envCacheDir, () => library('Caches')),
        legacyBase: context.join(home(), 'Library', 'Application Support'),
      );
    case DesktopOs.windows:
      String roaming() =>
          _set(env, 'APPDATA') ?? context.join(home(), 'AppData', 'Roaming');
      String local() =>
          _set(env, 'LOCALAPPDATA') ?? context.join(home(), 'AppData', 'Local');
      return (
        config: override(
          envConfigDir,
          () => context.join(roaming(), appAuthor, appName),
        ),
        data: override(
          envDataDir,
          () => context.join(local(), appAuthor, appName),
        ),
        cache: override(
          envCacheDir,
          () => context.join(local(), appAuthor, appName, 'Cache'),
        ),
        legacyBase: roaming(),
      );
    case DesktopOs.linux:
      String xdg(String name, List<String> fallback) =>
          _set(env, name) ?? context.joinAll([home(), ...fallback]);
      return (
        config: override(
          envConfigDir,
          () => context.join(xdg('XDG_CONFIG_HOME', ['.config']), appSlug),
        ),
        data: override(
          envDataDir,
          () =>
              context.join(xdg('XDG_DATA_HOME', ['.local', 'share']), appSlug),
        ),
        cache: override(
          envCacheDir,
          () => context.join(xdg('XDG_CACHE_HOME', ['.cache']), appSlug),
        ),
        legacyBase: xdg('XDG_DATA_HOME', ['.local', 'share']),
      );
  }
}

/// The app's folders on disk. One is made by [initAppPaths] at startup;
/// tests make their own on a temporary folder.
class AppPaths {
  AppPaths(this.dirs);

  final AppDirs dirs;

  bool _isConfigEntry(FileSystemEntity entry) =>
      entry is File && configFilenames.contains(p.basename(entry.path));

  List<Directory> _legacyDirs(String target) {
    final base = dirs.legacyBase;
    return [
      if (base != null)
        for (final name in legacyDataDirNames)
          if (!p.equals(p.join(base, name), target))
            Directory(p.join(base, name)),
    ];
  }

  void _copyTree(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final entry in from.listSync()) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        _copyTree(entry, Directory(p.join(to.path, name)));
      } else if (entry is File) {
        entry.copySync(p.join(to.path, name));
      }
    }
  }

  // Copies the entries [select] accepts; a copy that fails is taken back
  // to no folder at all rather than left half done.
  void _copyEntries(
    Directory legacy,
    Directory target,
    bool Function(FileSystemEntity)? select,
  ) {
    try {
      target.createSync(recursive: true);
      final entries = legacy.listSync()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        if (select != null && !select(entry)) {
          continue;
        }
        final to = p.join(target.path, p.basename(entry.path));
        if (entry is Directory) {
          _copyTree(entry, Directory(to));
        } else if (entry is File) {
          entry.copySync(to);
        }
      }
    } on FileSystemException {
      if (target.existsSync()) {
        target.deleteSync(recursive: true);
      }
    }
  }

  // Creates [path], first copying what [select] accepts from the first
  // legacy folder that exists.
  Directory _ensureDir(String path, bool Function(FileSystemEntity)? select) {
    final target = Directory(path);
    if (!target.existsSync()) {
      for (final legacy in _legacyDirs(path)) {
        if (legacy.existsSync()) {
          _copyEntries(legacy, target, select);
          break;
        }
      }
    }
    return target..createSync(recursive: true);
  }

  /// `settings.json`, `config.yaml` and `color.yaml`.
  Directory userConfigDir() => _ensureDir(
    dirs.config,
    // Where config and data are one folder (macOS, a phone), everything
    // comes over together.
    p.equals(dirs.config, dirs.data) ? null : _isConfigEntry,
  );

  /// `templates/`, `layouts/` and any other user data.
  Directory userDataDir() => _ensureDir(
    dirs.data,
    p.equals(dirs.config, dirs.data) ? null : (e) => !_isConfigEntry(e),
  );

  Directory userCacheDir() =>
      Directory(dirs.cache)..createSync(recursive: true);

  /// A fresh working folder under the cache folder (rendered overlays,
  /// LUTs, the files of one run) instead of the system's temp folder. A
  /// caller that finishes cleanly removes it; [pruneTempDirs] sweeps the
  /// rest.
  Directory appTempDir([String prefix = 'uwmedia_']) {
    final base = Directory(p.join(userCacheDir().path, tempDirName))
      ..createSync(recursive: true);
    return base.createTempSync(prefix);
  }

  /// Removes the [appTempDir] folders last changed more than [maxAge]
  /// before [now] (the time it is; a test passes its own); called at
  /// startup. Gives how many were removed.
  int pruneTempDirs({Duration maxAge = tempMaxAge, DateTime? now}) {
    final base = Directory(p.join(dirs.cache, tempDirName));
    if (!base.existsSync()) {
      return 0;
    }
    // The wall clock against file times: instants, not naive timestamps.
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    var removed = 0;
    for (final entry in base.listSync(followLinks: false)) {
      try {
        if (entry.statSync().modified.isBefore(cutoff)) {
          entry.deleteSync(recursive: true);
          removed++;
        }
      } on FileSystemException {
        continue;
      }
    }
    return removed;
  }
}

AppPaths? _paths;

/// Checkout mode (spec §10.84), asked for when the app is built:
/// `--dart-define=UWMEDIA_CHECKOUT=true`.
const checkoutAsked = bool.fromEnvironment('UWMEDIA_CHECKOUT');
const _releaseBuild = bool.fromEnvironment('dart.vm.product');

/// The bundled templates' folder in the source checkout this build runs
/// from, when the Overlay Designer is to save straight into it (checkout
/// mode, the Python app's dev mode): asked for at build time, never in a
/// release build, and only when the program lies inside a checkout (a
/// folder above it with `pubspec.yaml`, `.git` and the templates). `null`
/// otherwise, which is every installed app. The one writable path outside
/// the app's own folders.
String? checkoutTemplatesDir({
  bool asked = checkoutAsked && !_releaseBuild,
  String? executable,
}) {
  if (!asked) {
    return null;
  }
  var dir = File(executable ?? Platform.resolvedExecutable).absolute.parent;
  while (true) {
    final templates = p.join(dir.path, 'assets', 'overlays', 'templates');
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        FileSystemEntity.typeSync(p.join(dir.path, '.git')) !=
            FileSystemEntityType.notFound &&
        Directory(templates).existsSync()) {
      return templates;
    }
    if (dir.parent.path == dir.path) {
      return null;
    }
    dir = dir.parent;
  }
}

/// The folders of this run; [initAppPaths] has to have been called.
AppPaths get appPaths =>
    _paths ?? (throw StateError('initAppPaths() has not been called'));

/// Works out the app's folders: from the environment on the desktop, from
/// the system on a phone or tablet. To be awaited once at startup, before
/// anything is read or written. [paths] sets them outright (tests).
Future<AppPaths> initAppPaths({AppPaths? paths}) async {
  if (paths != null) {
    return _paths = paths;
  }
  final os = Platform.isMacOS
      ? DesktopOs.macos
      : Platform.isWindows
      ? DesktopOs.windows
      : Platform.isLinux
      ? DesktopOs.linux
      : null;
  if (os != null) {
    return _paths = AppPaths(desktopAppDirs(os, Platform.environment));
  }
  // The app's sandbox: one folder for config and data.
  final support = (await getApplicationSupportDirectory()).path;
  final cache = (await getApplicationCacheDirectory()).path;
  return _paths = AppPaths((
    config: support,
    data: support,
    cache: cache,
    legacyBase: null,
  ));
}

/// See [AppPaths.userConfigDir].
Directory userConfigDir() => appPaths.userConfigDir();

/// See [AppPaths.userDataDir].
Directory userDataDir() => appPaths.userDataDir();

/// See [AppPaths.userCacheDir].
Directory userCacheDir() => appPaths.userCacheDir();

/// See [AppPaths.appTempDir].
Directory appTempDir([String prefix = 'uwmedia_']) =>
    appPaths.appTempDir(prefix);
