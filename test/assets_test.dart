// pubspec.yaml must name every asset folder (Flutter bundles the files of
// a listed folder, not of its subfolders) and every bundled font.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';

void main() {
  // A Windows checkout may have CRLF line ends, and lists its folders with
  // backslashes.
  final pubspec = File('pubspec.yaml')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('every template folder with files is listed under assets', () {
    final folders = {
      for (final file in Directory(
        'assets/overlays/templates',
      ).listSync(recursive: true).whereType<File>())
        file.parent.path.replaceAll(r'\', '/'),
    };
    final missing = [
      for (final folder in folders)
        if (!pubspec.contains('    - $folder/\n')) folder,
    ];
    expect(missing, isEmpty);
    final listed = RegExp(
      r'^    - (assets/overlays/templates/\S*)/$',
      multiLine: true,
    ).allMatches(pubspec).map((m) => m.group(1));
    expect(
      [
        for (final folder in listed)
          if (!folders.contains(folder)) folder,
      ],
      isEmpty,
      reason: 'listed but gone',
    );
  });

  test('every font of the registry is declared, one family per file', () {
    for (final family in fontRegistry.values) {
      for (final file in family.values) {
        final name = file.replaceAll('.ttf', '');
        expect(
          pubspec,
          contains(
            '    - family: $name\n      fonts:\n'
            '        - asset: assets/fonts/$file\n',
          ),
        );
      }
    }
  });

  test('the fonts are bundled as data too, with their ink tables', () {
    expect(pubspec, contains('    - assets/fonts/\n'));
    expect(File('assets/fonts/ink_tables.bin').existsSync(), isTrue);
  });

  test('every bundled font has its licence text', () {
    for (final licence in const [
      'DEJAVU_FONT_LICENSE.txt',
      'DSEG_FONT_LICENSE.txt',
      'LIBERATION_FONT_LICENSE.txt',
      'ROBOTO_CONDENSED_FONT_LICENSE.txt',
      'ROBOTO_FONT_LICENSE.txt',
      'ROBOTO_MONO_FONT_LICENSE.txt',
    ]) {
      expect(File('assets/licenses/$licence').existsSync(), isTrue);
    }
  });
}
