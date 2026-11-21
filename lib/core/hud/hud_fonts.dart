/// The fonts a template can name, ported from `utils/fonts.py` of the
/// Python app (spec §5.6), and what the renderer needs to know of a font:
/// the ink box and the advance of a text, as Pillow gives them.
///
/// The families are the bundled ones. "Arial", the default and what a
/// template without `font_family` is drawn in, is Liberation Sans on every
/// platform, so a render is the same everywhere (the Python app takes the
/// platform's own Arial where there is one; spec §5.6).
library;

const String defaultFontFamily = 'Arial';
const String fontWeightRegular = 'regular';
const String fontWeightBold = 'bold';

/// Family to the font file per weight, under `assets/fonts/`. The family
/// names are the ones in the font files themselves.
const Map<String, Map<String, String>> fontRegistry = {
  defaultFontFamily: {
    fontWeightRegular: 'LiberationSans-Regular.ttf',
    fontWeightBold: 'LiberationSans-Bold.ttf',
  },
  'DSEG7 Classic': {
    fontWeightRegular: 'DSEG7Classic-Regular.ttf',
    fontWeightBold: 'DSEG7Classic-Bold.ttf',
  },
  'DejaVu Sans': {
    fontWeightRegular: 'DejaVuSans.ttf',
    fontWeightBold: 'DejaVuSans-Bold.ttf',
  },
  'Liberation Sans': {
    fontWeightRegular: 'LiberationSans-Regular.ttf',
    fontWeightBold: 'LiberationSans-Bold.ttf',
  },
  'Roboto': {
    fontWeightRegular: 'Roboto-Regular.ttf',
    fontWeightBold: 'Roboto-Bold.ttf',
  },
  'Roboto Condensed': {
    fontWeightRegular: 'RobotoCondensed-Regular.ttf',
    fontWeightBold: 'RobotoCondensed-Bold.ttf',
  },
  'Roboto Mono': {
    fontWeightRegular: 'RobotoMono-Regular.ttf',
    fontWeightBold: 'RobotoMono-Bold.ttf',
  },
};

/// The families a template can choose from, Arial first.
List<String> listFontFamilies() => fontRegistry.keys.toList();

/// The font file of a template's `font_family` / `font_weight`: an unknown
/// family is Arial, an unknown or missing weight regular.
String fontFile(Object? family, Object? weight) {
  var w = weight is String && weight.isNotEmpty
      ? weight.toLowerCase()
      : fontWeightRegular;
  if (w != fontWeightRegular && w != fontWeightBold) {
    w = fontWeightRegular;
  }
  final entry =
      fontRegistry[family is String && family.isNotEmpty
          ? family
          : defaultFontFamily] ??
      fontRegistry[defaultFontFamily]!;
  return entry[w] ?? entry[fontWeightRegular]!;
}

/// A font at one size, measured as Pillow measures it.
abstract class HudFont {
  /// The file under `assets/fonts/`.
  String get file;

  /// The size in pixels (the em).
  int get size;

  /// Pillow `getbbox`: the ink of [text] as (left, top, right, bottom) from
  /// the drawing position, which is the top of the line at the pen start.
  (int left, int top, int right, int bottom) getbbox(String text);

  /// Pillow `getlength`: how far [text] moves the pen.
  double getlength(String text);

  /// Pillow `getmetrics()[0]`: the line top to the baseline, in whole
  /// pixels.
  int get ascent;

  /// Whether the font has a glyph of its own for [char] (Python
  /// `_font_lacks_glyph` is the opposite): a badge draws an arrow Roboto
  /// Condensed lacks in Roboto.
  bool hasGlyph(String char);
}

/// Where the renderer gets its fonts.
abstract class HudFonts {
  HudFont font(int size, String file);
}

extension HudFontsLookup on HudFonts {
  /// Python `get_font(size, family, weight)`.
  HudFont get(int size, [Object? family, Object? weight]) =>
      font(size, fontFile(family, weight));
}
