// The pure Dart font reader against Pillow: the measurements the Python
// renderer asked for in the renderer fixture, and those of
// font_measures.json (some seventy texts in every bundled font at seventeen
// sizes), both made by the Python app's own Pillow.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';

import '../../helpers/renderer_reference.dart';

/// The fonts that carry their own hinting. The others (Roboto, DSEG7
/// Classic) go through FreeType's automatic hinting, which also moves the
/// ink sideways.
const _hinted = {
  'LiberationSans-Regular.ttf',
  'LiberationSans-Bold.ttf',
  'RobotoCondensed-Regular.ttf',
  'RobotoCondensed-Bold.ttf',
  'DejaVuSans.ttf',
  'DejaVuSans-Bold.ttf',
  'RobotoMono-Regular.ttf',
  'RobotoMono-Bold.ttf',
};

/// Whether every character of [text] is one of the ink tables' (ASCII,
/// Latin-1 without the soft hyphen, a few signs).
bool _inTables(String text) => text.runes.every(
  (r) =>
      (r >= 0x20 && r < 0x7f) ||
      (r >= 0xa0 && r <= 0xff && r != 0xad) ||
      const {
        0x2013,
        0x2014,
        0x2018,
        0x2019,
        0x201c,
        0x201d,
        0x2022,
        0x2026,
        0x2191,
        0x2193,
        0x2713,
      }.contains(r),
);

void main() {
  final fonts = TtfFonts(
    (file) => File('assets/fonts/$file').readAsBytesSync(),
    inkTables: InkTables.parse(
      File('assets/fonts/ink_tables.bin').readAsBytesSync(),
    ),
  );
  // (font file, size, text, Pillow's box or null, Pillow's length or null)
  final measures = <(String, int, String, List<dynamic>?, num?)>[];
  void add(Map<String, dynamic> perFont) {
    for (final MapEntry(key: key, value: texts) in perFont.entries) {
      final [file, size] = key.split('@');
      for (final MapEntry(key: text, value: m)
          in (texts as Map<String, dynamic>).entries) {
        final [box, length] = m as List<dynamic>;
        measures.add((
          file,
          int.parse(size),
          text,
          box as List<dynamic>?,
          length as num?,
        ));
      }
    }
  }

  final reference = RendererReference.load();
  add(reference.data['measures'] as Map<String, dynamic>);
  add(
    (jsonDecode(
          File('test/fixtures/python_reference/renderer/font_measures.json')
              .readAsStringSync(),
        ) as Map<String, dynamic>)['measures']
        as Map<String, dynamic>,
  );

  test('the registry names the families as the font files do', () {
    for (final MapEntry(key: family, value: files) in fontRegistry.entries) {
      if (family == defaultFontFamily) {
        continue;
      }
      for (final MapEntry(key: weight, value: file) in files.entries) {
        final (name, style) = fonts.face(file).names;
        expect(name, family, reason: file);
        expect(
          style.toLowerCase().contains('bold'),
          weight == fontWeightBold,
          reason: '$file: $style',
        );
      }
    }
  });

  test(
    'getmetrics and the glyph check are Pillow\'s (Python 0.8.1 badges)',
    () {
      // A badge's small unit sits on the ascent (getmetrics()[0]); an arrow
      // the badge's font lacks is drawn in Roboto (_font_lacks_glyph).
      final metrics = reference.data['metrics'] as Map<String, dynamic>;
      for (final MapEntry(key: key, value: m) in metrics.entries) {
        final [file, size] = key.split('@');
        expect(
          fonts.font(int.parse(size), file).ascent,
          (m as List<dynamic>)[0],
          reason: key,
        );
      }
      final glyphs = reference.data['glyphs'] as Map<String, dynamic>;
      var checked = 0;
      for (final MapEntry(key: file, value: chars) in glyphs.entries) {
        for (final MapEntry(key: char, value: lacks)
            in (chars as Map<String, dynamic>).entries) {
          checked++;
          expect(
            fonts.font(40, file).hasGlyph(char),
            lacks != true,
            reason: '$char in $file',
          );
        }
      }
      expect(metrics, isNotEmpty);
      expect(checked, greaterThan(0));
      // Roboto Condensed lacks the arrows, Roboto has them.
      for (final arrow in const ['↑', '↓']) {
        expect(
          fonts.font(40, 'RobotoCondensed-Regular.ttf').hasGlyph(arrow),
          isFalse,
        );
        expect(fonts.font(40, 'Roboto-Regular.ttf').hasGlyph(arrow), isTrue);
      }
    },
  );

  test('getlength is Pillow\'s for every text, font and size', () {
    var checked = 0;
    for (final (file, size, text, _, length) in measures) {
      if (length == null) {
        continue;
      }
      checked++;
      expect(
        fonts.font(size, file).getlength(text),
        closeTo(length, 1e-9),
        reason: '"$text" in $file at $size px',
      );
    }
    expect(checked, greaterThan(15000));
  });

  test('getbbox is Pillow\'s where the ink tables reach, in the fonts with '
      'their own hinting', () {
    var checked = 0;
    for (final (file, size, text, box, _) in measures) {
      // A ligature is a glyph of its own, outside the tables.
      if (box == null ||
          !_hinted.contains(file) ||
          size > 320 ||
          !_inTables(text) ||
          text.contains('ff') ||
          text.contains('fi')) {
        continue;
      }
      checked++;
      final got = fonts.font(size, file).getbbox(text);
      expect(
        [got.$1, got.$2, got.$3, got.$4],
        box,
        reason: '"$text" in $file at $size px',
      );
    }
    expect(checked, greaterThan(12000));
  });

  test('elsewhere getbbox is within a pixel or two of Pillow\'s', () {
    var checked = 0;
    var different = 0;
    for (final (file, size, text, box, _) in measures) {
      if (box == null) {
        continue;
      }
      checked++;
      final got = fonts.font(size, file).getbbox(text);
      final g = [got.$1, got.$2, got.$3, got.$4];
      var worst = 0;
      for (var i = 0; i < 4; i++) {
        final d = (g[i] - (box[i] as int)).abs();
        worst = d > worst ? d : worst;
      }
      if (worst != 0) {
        different++;
      }
      // A character outside the tables has no more than its unhinted
      // outline to go by; the hinting moves an accent further than a
      // letter's edge.
      expect(
        worst,
        lessThanOrEqualTo(_inTables(text) ? 2 : 2 + size ~/ 16),
        reason: '"$text" in $file at $size px: $g, Pillow $box',
      );
    }
    // Less than one box in thirty is off at all.
    expect(different / checked, lessThan(1 / 30));
  });

  test('without the ink tables a top or a bottom is the rounded outline', () {
    final plain = TtfFonts(
      (file) => File('assets/fonts/$file').readAsBytesSync(),
    );
    final font = plain.font(43, 'LiberationSans-Regular.ttf');
    expect(font.ascent, 39);
    expect(font.getbbox('0'), (0, 9, 24, 39));
    expect(font.getbbox(''), (0, 0, 0, 0));
    expect(font.getlength('AV'), 54.1875);
    expect(font.getlength('A') + font.getlength('V'), 57.375);
  });
}
