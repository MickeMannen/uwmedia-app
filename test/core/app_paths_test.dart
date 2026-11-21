// The per-user folders of lib/core/app_paths.dart (spec §13): the cases of
// the Python app's tests/test_resource_paths.py. Config, data and cache
// per system, the one-time copy from the old single folder
// ("org.christersson.uwmedia", and "UWMedia" before it) and the working
// folders under the cache folder. Everything is under a temporary folder,
// so nothing touches the real Application Support, %APPDATA% or
// ~/.local/share tree.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/app_paths.dart';

import '../helpers/tools.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_paths_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String at(String a, [String? b, String? c, String? d]) =>
      p.join(tmp.path, a, b, c, d);

  // Windows and Linux: config, data and cache are three folders; the old
  // single folder lay under the data folder's parent.
  AppPaths split() => AppPaths((
    config: at('config', 'uwmedia'),
    data: at('data', 'uwmedia'),
    cache: at('cache', 'uwmedia'),
    legacyBase: at('data'),
  ));

  // macOS: config and data are one folder, beside the old ones.
  AppPaths shared() => AppPaths((
    config: at('Application Support', appId),
    data: at('Application Support', appId),
    cache: at('Caches', appId),
    legacyBase: at('Application Support'),
  ));

  void fillLegacy(String legacy) {
    Directory(p.join(legacy, 'templates')).createSync(recursive: true);
    Directory(p.join(legacy, 'layouts')).createSync();
    File(p.join(legacy, 'settings.json')).writeAsStringSync('{"a": 1}');
    File(p.join(legacy, 'color.yaml')).writeAsStringSync('profiles: {}');
    File(p.join(legacy, 'templates', 't.json')).writeAsStringSync('{}');
  }

  bool isFile(String a, [String? b, String? c]) =>
      File(p.join(a, b, c)).existsSync();

  group('where the folders are', () {
    test('macOS', () {
      final dirs = desktopAppDirs(DesktopOs.macos, {'HOME': '/Users/x'});
      expect(dirs, (
        config: '/Users/x/Library/Application Support/org.christersson.uwmedia',
        data: '/Users/x/Library/Application Support/org.christersson.uwmedia',
        cache: '/Users/x/Library/Caches/org.christersson.uwmedia',
        legacyBase: '/Users/x/Library/Application Support',
      ));
    });

    test('Windows', () {
      final dirs = desktopAppDirs(DesktopOs.windows, {
        'USERPROFILE': r'C:\Users\x',
        'APPDATA': r'C:\Users\x\AppData\Roaming',
        'LOCALAPPDATA': r'D:\Local',
      });
      expect(dirs, (
        config: r'C:\Users\x\AppData\Roaming\Christersson\UWMedia',
        data: r'D:\Local\Christersson\UWMedia',
        cache: r'D:\Local\Christersson\UWMedia\Cache',
        legacyBase: r'C:\Users\x\AppData\Roaming',
      ));
      // Without the two variables: under the profile.
      expect(
        desktopAppDirs(DesktopOs.windows, {'USERPROFILE': r'C:\Users\x'}),
        (
          config: r'C:\Users\x\AppData\Roaming\Christersson\UWMedia',
          data: r'C:\Users\x\AppData\Local\Christersson\UWMedia',
          cache: r'C:\Users\x\AppData\Local\Christersson\UWMedia\Cache',
          legacyBase: r'C:\Users\x\AppData\Roaming',
        ),
      );
    });

    test('Linux follows XDG', () {
      final dirs = desktopAppDirs(DesktopOs.linux, {
        'HOME': '/home/x',
        'XDG_CONFIG_HOME': '/t/xc',
        'XDG_DATA_HOME': '/t/xd',
        'XDG_CACHE_HOME': '/t/xk',
      });
      expect(dirs, (
        config: '/t/xc/uwmedia',
        data: '/t/xd/uwmedia',
        cache: '/t/xk/uwmedia',
        legacyBase: '/t/xd',
      ));
    });

    test('Linux without XDG uses the home folder', () {
      // An empty variable counts as not set.
      final dirs = desktopAppDirs(DesktopOs.linux, {
        'HOME': '/home/x',
        'XDG_DATA_HOME': ' ',
      });
      expect(dirs, (
        config: '/home/x/.config/uwmedia',
        data: '/home/x/.local/share/uwmedia',
        cache: '/home/x/.cache/uwmedia',
        legacyBase: '/home/x/.local/share',
      ));
    });

    test('the environment overrides win', () {
      for (final os in DesktopOs.values) {
        final home = os == DesktopOs.windows ? 'USERPROFILE' : 'HOME';
        final dirs = desktopAppDirs(os, {
          home: os == DesktopOs.windows ? r'C:\Users\x' : '/home/x',
          envConfigDir: ' /t/c ',
          envDataDir: '~/d',
          envCacheDir: '~',
        });
        expect(dirs.config, '/t/c');
        expect(
          dirs.data,
          os == DesktopOs.windows ? r'C:\Users\x\d' : '/home/x/d',
        );
        expect(dirs.cache, os == DesktopOs.windows ? r'C:\Users\x' : '/home/x');
      }
      // With all three set, no home folder is needed.
      expect(
        desktopAppDirs(DesktopOs.linux, {
          envConfigDir: '/c',
          envDataDir: '/d',
          envCacheDir: '/k',
          'XDG_DATA_HOME': '/xd',
        }).data,
        '/d',
      );
      expect(() => desktopAppDirs(DesktopOs.macos, {}), throwsStateError);
    });
  });

  test('the split layout creates three folders', () {
    final paths = split();
    expect(paths.userConfigDir().path, at('config', 'uwmedia'));
    expect(paths.userDataDir().path, at('data', 'uwmedia'));
    expect(paths.userCacheDir().path, at('cache', 'uwmedia'));
    for (final dir in [
      paths.userConfigDir(),
      paths.userDataDir(),
      paths.userCacheDir(),
    ]) {
      expect(dir.existsSync(), isTrue);
    }
  });

  test('the split migration sorts the config files from the data', () {
    final legacy = at('data', appId);
    fillLegacy(legacy);
    final paths = split();
    final config = paths.userConfigDir().path;
    final data = paths.userDataDir().path;

    expect(
      File(p.join(config, 'settings.json')).readAsStringSync(),
      '{"a": 1}',
    );
    expect(isFile(config, 'color.yaml'), isTrue);
    expect(Directory(p.join(config, 'templates')).existsSync(), isFalse);
    expect(isFile(data, 'templates', 't.json'), isTrue);
    expect(Directory(p.join(data, 'layouts')).existsSync(), isTrue);
    expect(isFile(data, 'settings.json'), isFalse);
    // The old folder is left as it was.
    expect(isFile(legacy, 'settings.json'), isTrue);
    expect(isFile(legacy, 'templates', 't.json'), isTrue);
  });

  test('the older "UWMedia" folder is the fallback source', () {
    fillLegacy(at('data', 'UWMedia'));
    final paths = split();
    expect(
      File(p.join(paths.userConfigDir().path, 'settings.json'))
          .readAsStringSync(),
      '{"a": 1}',
    );
    expect(isFile(paths.userDataDir().path, 'templates', 't.json'), isTrue);
  });

  test('the shared layout migrates everything from the "UWMedia" folder', () {
    final old = at('Application Support', 'UWMedia');
    fillLegacy(old);
    final paths = shared();
    final path = paths.userConfigDir().path;
    expect(path, paths.userDataDir().path);
    expect(path, at('Application Support', appId));
    expect(File(p.join(path, 'settings.json')).readAsStringSync(), '{"a": 1}');
    expect(isFile(path, 'templates', 't.json'), isTrue);
    // Once the new folder exists, later changes to the old one are not
    // looked at.
    File(p.join(old, 'settings.json')).writeAsStringSync('{"a": 2}');
    paths.userDataDir();
    expect(File(p.join(path, 'settings.json')).readAsStringSync(), '{"a": 1}');
  });

  test('a folder that is there is not written over', () {
    final old = at('Application Support', 'UWMedia');
    Directory(old).createSync(recursive: true);
    File(p.join(old, 'settings.json')).writeAsStringSync('old');
    Directory(at('Application Support', appId)).createSync();
    final paths = shared()..userConfigDir();
    expect(isFile(paths.dirs.config, 'settings.json'), isFalse);
  });

  test('a copy that fails leaves an empty new folder', () {
    final legacy = at('data', appId);
    fillLegacy(legacy);
    // A file where the data folder's parent has to be: nothing can be
    // created there. The config folder, elsewhere, is still made.
    final blocked = AppPaths((
      config: at('config', 'uwmedia'),
      data: at('blocked', 'uwmedia'),
      cache: at('cache', 'uwmedia'),
      legacyBase: at('data'),
    ));
    File(at('blocked')).writeAsStringSync('in the way');
    expect(blocked.userDataDir, throwsA(isA<FileSystemException>()));
    expect(isFile(blocked.userConfigDir().path, 'settings.json'), isTrue);

    // A legacy entry that cannot be read (where a file can be locked).
    if (canLockFiles) {
      final locked = p.join(legacy, 'templates', 't.json');
      Process.runSync('chmod', ['000', locked]);
      addTearDown(() => Process.runSync('chmod', ['600', locked]));
      final data = split().userDataDir();
      expect(data.existsSync(), isTrue);
      expect(data.listSync(), isEmpty);
    }
  });

  test('working folders are under the cache folder, old ones are pruned', () {
    final paths = split();
    final fresh = paths.appTempDir('uwmedia_test_');
    expect(fresh.existsSync(), isTrue);
    expect(fresh.parent.path, p.join(paths.userCacheDir().path, tempDirName));
    expect(p.basename(fresh.path), startsWith('uwmedia_test_'));
    final stale = paths.appTempDir('uwmedia_stale_');
    expect(paths.pruneTempDirs(), 0);
    // Three days on, both are old; with a file changed since, only one.
    final later = DateTime.now().add(const Duration(days: 3));
    expect(paths.pruneTempDirs(maxAge: const Duration(days: 4), now: later), 0);
    Directory(fresh.path).deleteSync();
    expect(paths.pruneTempDirs(now: later), 1);
    expect(stale.existsSync(), isFalse);
    // No temp folder at all yet.
    expect(shared().pruneTempDirs(), 0);
  });

  test('the folders of the run', () async {
    final paths = split();
    await initAppPaths(paths: paths);
    expect(appPaths, same(paths));
    expect(userConfigDir().path, paths.dirs.config);
    expect(userDataDir().path, paths.dirs.data);
    expect(userCacheDir().path, paths.dirs.cache);
    final work = appTempDir();
    expect(p.basename(work.path), startsWith('uwmedia_'));
    expect(work.parent.path, p.join(paths.dirs.cache, tempDirName));
  });
}
