// The config files on disk (lib/core/config/config_store.dart), in a
// temporary folder: the cases of the Python app's settings, tank-name and
// colour-profile functions that read and write (tests/test_config.py and
// the backends' use of utils/app_settings.py).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/app_settings.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';

void main() {
  late Directory tmp;
  late ConfigStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_config_');
    // The folder is made when it is first asked for, as userConfigDir().
    store = ConfigStore(
      () => Directory(p.join(tmp.path, 'config'))..createSync(recursive: true),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String read(String name) =>
      File(p.join(tmp.path, 'config', name)).readAsStringSync();

  test('settings: the defaults without a file, and what was saved', () {
    expect(store.settings(), defaultSettings());
    final data = store.updateSettings({'ffmpeg_path': '/opt/ffmpeg'});
    expect(data['ffmpeg_path'], '/opt/ffmpeg');
    expect(store.settings(), data);
    expect(read('settings.json'), settingsText(data));
    // Nothing is left beside the file.
    expect(
      Directory(p.join(tmp.path, 'config'))
          .listSync()
          .map((e) => p.basename(e.path)),
      ['settings.json'],
    );
  });

  test('settings: a broken file counts as none, and is replaced', () {
    File(store.settingsPath).writeAsStringSync('{not json');
    expect(store.settings(), defaultSettings());
    File(store.settingsPath).writeAsBytesSync([0xff, 0xfe, 0x00]);
    expect(store.settings(), defaultSettings());
    store.setField('color_source', '/media');
    expect(store.fields(), {'color_source': '/media'});
  });

  test('form fields, lists and the dialog folder', () {
    store
      ..setField('a', 1)
      ..setField('b', 'two')
      ..setField('a', 3);
    expect(store.fields(), {'a': 3, 'b': 'two'});
    expect(store.addUnique('filename_formats', '%Y')['filename_formats'], [
      '%Y',
    ]);
    store.addUnique('filename_formats', '%Y');
    expect(store.addUnique('filename_formats', '%m')['filename_formats'], [
      '%Y',
      '%m',
    ]);

    expect(store.dialogDirFor('logs_dir', home: '/home/x'), '/home/x');
    store.rememberDialogDir('logs_dir', tmp.path);
    expect(store.dialogDirFor('logs_dir', home: '/home/x'), tmp.path);
    store.rememberDialogDir('logs_dir', p.join(tmp.path, 'gone'));
    expect(store.dialogDirFor('logs_dir', home: '/home/x'), '/home/x');
  });

  test('the tank names', () {
    expect(store.tankConfig().tanks.tanks, isEmpty);
    final file = store.tankConfig();
    store.saveConfigYaml(
      file.withTanks(TankConfig({'12345': 'Left', '67890': 'Right'})),
    );
    expect(read('config.yaml'), "tanks:\n  '12345': Left\n  '67890': Right\n");
    expect(store.tankConfig().tanks.tanks, {'12345': 'Left', '67890': 'Right'});
  });

  test('colour profiles: the bundled ones as shipped, the user\'s '
      'beside them (spec §10.103)', () {
    const bundled = 'default:\n  cifval: 1.0\ndeep:\n  cifval: 2.0\n';
    expect(store.colorProfiles(bundled).keys, ['default', 'deep']);
    store.saveUserProfile('mine', {'cifval': 3.5});
    store.saveUserProfile('default', {'cifval': 9.0});
    expect(
      read('color.yaml'),
      'mine:\n  cifval: 3.5\ndefault:\n  cifval: 9.0\n',
    );
    final merged = store.colorProfiles(bundled);
    expect(merged.keys, ['default', 'deep', 'mine']);
    // A user profile with a bundled one's name is left out.
    expect(merged['default'], {'cifval': 1.0});
    expect(merged['mine'], {'cifval': 3.5});
    expect(merged['deep'], {'cifval': 2.0});
  });

  test('colour profiles in a folder of the user\'s choice', () {
    final own = p.join(tmp.path, 'profiles', 'here');
    store.updateSettings({colorProfilesDirKey: own});
    expect(store.colorYamlPath, p.join(own, 'color.yaml'));
    store.saveUserProfile('mine', {'cifval': 3.5});
    expect(File(p.join(own, 'color.yaml')).existsSync(), isTrue);
    expect(
      File(p.join(tmp.path, 'config', 'color.yaml')).existsSync(),
      isFalse,
    );
    expect(store.colorProfiles(null).keys, ['mine']);
  });

  test('a file that cannot be written says so and keeps the old one', () {
    store.setField('a', 1);
    // A folder where the new file has to go.
    Directory('${store.settingsPath}.new').createSync();
    expect(() => store.setField('a', 2), throwsA(isA<FileSystemException>()));
    expect(store.fields(), {'a': 1});
  });
}
