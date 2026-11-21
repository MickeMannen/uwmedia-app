/// Text measuring from the bundled TrueType fonts themselves, in pure Dart:
/// the ink box and the advance of a text as the Python app's Pillow gives
/// them (`getbbox`, `getlength`), for the renderer's [HudFont].
///
/// Pillow lays text out with HarfBuzz and takes the ink from FreeType. This
/// reader does the part of both that the overlay texts need:
///
/// - the advance of a glyph from `hmtx`, scaled and rounded to 1/64 px as
///   HarfBuzz does with an unhinted FreeType face;
/// - pair kerning from the `GPOS` table's `kern` feature (pair adjustment
///   lookups, both formats, also behind an extension lookup);
/// - the left and the right of a glyph's ink from its box in `glyf`,
///   scaled and moved out to whole pixels;
/// - the top and the bottom of the ink from [InkTables], when given: how
///   far each character reaches above and below the baseline at each size
///   once FreeType has run the font's hinting, which this reader does not
///   do. The tables are made from Pillow itself
///   (`tool/python_reference/font_ink_tables.py`, kept in
///   `assets/fonts/ink_tables.bin`) and cover ASCII, Latin-1 and a few
///   signs up to 320 px. Outside them the scaled box is rounded to the
///   nearest pixel, which can be a pixel off.
///
/// - the ligatures of the `GSUB` table's `liga`, `clig` and `rlig`
///   features ("fi" in Roboto and DejaVu Sans is one glyph).
///
/// Not done: the other substitutions of `GSUB`, mark positioning, and the
/// sideways part of FreeType's automatic hinting, which moves the left and
/// right of the ink by a pixel now and then in the fonts that carry no
/// hinting of their own (Roboto, DSEG7 Classic). The measure of all this
/// is in `test/core/hud/ttf_font_test.dart`.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/hud/hud_fonts.dart';

/// A parsed font file.
class TtfFace {
  TtfFace(Uint8List bytes)
    : _data = ByteData.sublistView(bytes),
      _bytes = bytes {
    final count = _data.getUint16(4);
    for (var i = 0; i < count; i++) {
      final at = 12 + 16 * i;
      _tables[String.fromCharCodes(bytes, at, at + 4)] = _data.getUint32(
        at + 8,
      );
    }
    final head = _table('head');
    headFlags = _data.getUint16(head + 16);
    unitsPerEm = _data.getUint16(head + 18);
    _longLoca = _data.getInt16(head + 50) != 0;
    final hhea = _table('hhea');
    ascender = _data.getInt16(hhea + 4);
    descender = _data.getInt16(hhea + 6);
    _numberOfHMetrics = _data.getUint16(hhea + 34);
    numGlyphs = _data.getUint16(_table('maxp') + 4);
    _hmtx = _table('hmtx');
    _loca = _tables['loca'];
    _glyf = _tables['glyf'];
    _readCmap();
    _readKerning();
    _readLigatures();
  }

  final ByteData _data;
  final Uint8List _bytes;
  final Map<String, int> _tables = {};

  late final int unitsPerEm;
  late final int headFlags;

  /// The `hhea` ascender and descender, in font units.
  late final int ascender;
  late final int descender;
  late final int numGlyphs;
  late final bool _longLoca;
  late final int _numberOfHMetrics;
  late final int _hmtx;
  late final int? _loca;
  late final int? _glyf;

  final Map<int, int> _cmap = {};

  /// Pair adjustment subtables of the `kern` feature, in lookup order.
  final List<_PairLookup> _kern = [];

  int _table(String tag) {
    final offset = _tables[tag];
    if (offset == null) {
      throw FormatException('Font without a $tag table');
    }
    return offset;
  }

  /// The font's family and style names (name IDs 1 and 2).
  (String family, String style) get names {
    final name = _table('name');
    final count = _data.getUint16(name + 2);
    final strings = name + _data.getUint16(name + 4);
    String? family;
    String? style;
    for (var i = 0; i < count; i++) {
      final at = name + 6 + 12 * i;
      final platform = _data.getUint16(at);
      final id = _data.getUint16(at + 6);
      if ((id != 1 && id != 2) || (platform != 3 && platform != 0)) {
        continue;
      }
      final start = strings + _data.getUint16(at + 10);
      final length = _data.getUint16(at + 8);
      final text = String.fromCharCodes([
        for (var k = 0; k + 1 < length; k += 2) _data.getUint16(start + k),
      ]);
      if (id == 1) {
        family ??= text;
      } else {
        style ??= text;
      }
    }
    return (family ?? '', style ?? '');
  }

  void _readCmap() {
    final cmap = _table('cmap');
    final count = _data.getUint16(cmap + 2);
    int? format4;
    int? format12;
    for (var i = 0; i < count; i++) {
      final at = cmap + 4 + 8 * i;
      final platform = _data.getUint16(at);
      final encoding = _data.getUint16(at + 2);
      final sub = cmap + _data.getUint32(at + 4);
      final format = _data.getUint16(sub);
      if (format == 12 && (platform == 3 || platform == 0)) {
        format12 ??= sub;
      } else if (format == 4 &&
          ((platform == 3 && encoding == 1) || platform == 0)) {
        format4 ??= sub;
      }
    }
    if (format4 != null) {
      final segCount = _data.getUint16(format4 + 6) ~/ 2;
      final ends = format4 + 14;
      final starts = ends + 2 * segCount + 2;
      final deltas = starts + 2 * segCount;
      final ranges = deltas + 2 * segCount;
      for (var s = 0; s < segCount; s++) {
        final end = _data.getUint16(ends + 2 * s);
        final start = _data.getUint16(starts + 2 * s);
        final delta = _data.getInt16(deltas + 2 * s);
        final range = _data.getUint16(ranges + 2 * s);
        for (var c = start; c <= end && c != 0xffff; c++) {
          var glyph = 0;
          if (range == 0) {
            glyph = (c + delta) & 0xffff;
          } else {
            final at = ranges + 2 * s + range + 2 * (c - start);
            glyph = _data.getUint16(at);
            if (glyph != 0) {
              glyph = (glyph + delta) & 0xffff;
            }
          }
          if (glyph != 0) {
            _cmap[c] = glyph;
          }
        }
      }
    }
    if (format12 != null) {
      final groups = _data.getUint32(format12 + 12);
      for (var g = 0; g < groups; g++) {
        final at = format12 + 16 + 12 * g;
        final start = _data.getUint32(at);
        final end = _data.getUint32(at + 4);
        final glyph = _data.getUint32(at + 8);
        for (var c = start; c <= end; c++) {
          _cmap[c] = glyph + (c - start);
        }
      }
    }
  }

  /// The glyph of a character; 0 (the "missing" glyph) for one the font
  /// does not have.
  int glyphIndex(int codePoint) => _cmap[codePoint] ?? 0;

  /// A glyph's advance width in font units.
  int advanceWidth(int glyph) {
    final index = glyph < _numberOfHMetrics ? glyph : _numberOfHMetrics - 1;
    return _data.getUint16(_hmtx + 4 * index);
  }

  /// A glyph's box (xMin, yMin, xMax, yMax) in font units; `null` for a
  /// glyph without an outline (a space).
  (int, int, int, int)? glyphBox(int glyph) {
    final loca = _loca;
    final glyf = _glyf;
    if (loca == null || glyf == null || glyph >= numGlyphs) {
      return null;
    }
    final start = _longLoca
        ? _data.getUint32(loca + 4 * glyph)
        : 2 * _data.getUint16(loca + 2 * glyph);
    final end = _longLoca
        ? _data.getUint32(loca + 4 * glyph + 4)
        : 2 * _data.getUint16(loca + 2 * glyph + 2);
    if (end <= start) {
      return null;
    }
    final at = glyf + start;
    return (
      _data.getInt16(at + 2),
      _data.getInt16(at + 4),
      _data.getInt16(at + 6),
      _data.getInt16(at + 8),
    );
  }

  // --- layout tables: GPOS pair kerning, GSUB ligatures ---

  /// The subtables of type [wanted] (also behind extension type
  /// [extension]) of the lookups that the features [tags] of the default
  /// language of the Latin script (else of DFLT) name, per lookup, in
  /// lookup order.
  List<List<int>> _lookupSubtables(
    String table,
    Set<String> tags,
    int wanted,
    int extension,
  ) {
    final start = _tables[table];
    if (start == null) {
      return const [];
    }
    final scripts = start + _data.getUint16(start + 4);
    final features = start + _data.getUint16(start + 6);
    final lookups = start + _data.getUint16(start + 8);

    int? langSys;
    final scriptCount = _data.getUint16(scripts);
    for (final script in const ['latn', 'DFLT']) {
      for (var i = 0; i < scriptCount && langSys == null; i++) {
        final at = scripts + 2 + 6 * i;
        if (String.fromCharCodes(_bytes, at, at + 4) == script) {
          final offset = scripts + _data.getUint16(at + 4);
          final defaultLang = _data.getUint16(offset);
          if (defaultLang != 0) {
            langSys = offset + defaultLang;
          }
        }
      }
    }
    if (langSys == null) {
      return const [];
    }
    final lookupIndices = <int>{};
    final featureCount = _data.getUint16(langSys + 4);
    for (var i = 0; i < featureCount; i++) {
      final index = _data.getUint16(langSys + 6 + 2 * i);
      final record = features + 2 + 6 * index;
      if (!tags.contains(String.fromCharCodes(_bytes, record, record + 4))) {
        continue;
      }
      final feature = features + _data.getUint16(record + 4);
      final count = _data.getUint16(feature + 2);
      for (var k = 0; k < count; k++) {
        lookupIndices.add(_data.getUint16(feature + 4 + 2 * k));
      }
    }
    final out = <List<int>>[];
    for (final index in lookupIndices.toList()..sort()) {
      final lookup = lookups + _data.getUint16(lookups + 2 + 2 * index);
      final type = _data.getUint16(lookup);
      final count = _data.getUint16(lookup + 4);
      final subtables = <int>[];
      for (var s = 0; s < count; s++) {
        var sub = lookup + _data.getUint16(lookup + 6 + 2 * s);
        var subType = type;
        if (subType == extension && _data.getUint16(sub) == 1) {
          // An extension: the real subtable is elsewhere.
          subType = _data.getUint16(sub + 2);
          sub += _data.getUint32(sub + 4);
        }
        if (subType == wanted) {
          subtables.add(sub);
        }
      }
      if (subtables.isNotEmpty) {
        out.add(subtables);
      }
    }
    return out;
  }

  void _readKerning() {
    for (final subtables in _lookupSubtables('GPOS', const {'kern'}, 2, 9)) {
      _kern.add(_PairLookup(subtables));
    }
  }

  /// Ligature substitution subtables, per lookup.
  final List<List<int>> _ligatures = [];

  void _readLigatures() {
    _ligatures.addAll(
      _lookupSubtables('GSUB', const {'liga', 'clig', 'rlig'}, 4, 7),
    );
  }

  /// [glyphs] with the font's ligatures put in; [sources] says for each
  /// glyph of the result which of [glyphs] it started at, or -1 for a
  /// ligature.
  (List<int>, List<int>) ligated(List<int> glyphs) {
    var run = glyphs;
    var sources = [for (var i = 0; i < glyphs.length; i++) i];
    for (final subtables in _ligatures) {
      final out = <int>[];
      final outSources = <int>[];
      var i = 0;
      while (i < run.length) {
        var taken = 0;
        var ligature = 0;
        for (final sub in subtables) {
          final index = _coverageIndex(sub + _data.getUint16(sub + 2), run[i]);
          if (index == null) {
            continue;
          }
          final set = sub + _data.getUint16(sub + 6 + 2 * index);
          final count = _data.getUint16(set);
          for (var l = 0; l < count && taken == 0; l++) {
            final lig = set + _data.getUint16(set + 2 + 2 * l);
            final components = _data.getUint16(lig + 2);
            if (i + components > run.length) {
              continue;
            }
            var matches = true;
            for (var c = 1; c < components && matches; c++) {
              matches = _data.getUint16(lig + 4 + 2 * (c - 1)) == run[i + c];
            }
            if (matches) {
              taken = components;
              ligature = _data.getUint16(lig);
            }
          }
          if (taken != 0) {
            break;
          }
        }
        if (taken == 0) {
          out.add(run[i]);
          outSources.add(sources[i]);
          i++;
        } else {
          out.add(ligature);
          outSources.add(taken == 1 ? sources[i] : -1);
          i += taken;
        }
      }
      run = out;
      sources = outSources;
    }
    return (run, sources);
  }

  int? _coverageIndex(int coverage, int glyph) {
    final format = _data.getUint16(coverage);
    final count = _data.getUint16(coverage + 2);
    var low = 0;
    var high = count - 1;
    if (format == 1) {
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        final g = _data.getUint16(coverage + 4 + 2 * mid);
        if (g == glyph) {
          return mid;
        }
        if (g < glyph) {
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      return null;
    }
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final at = coverage + 4 + 6 * mid;
      final start = _data.getUint16(at);
      final end = _data.getUint16(at + 2);
      if (glyph < start) {
        high = mid - 1;
      } else if (glyph > end) {
        low = mid + 1;
      } else {
        return _data.getUint16(at + 4) + glyph - start;
      }
    }
    return null;
  }

  int _classOf(int classDef, int glyph) {
    final format = _data.getUint16(classDef);
    if (format == 1) {
      final start = _data.getUint16(classDef + 2);
      final count = _data.getUint16(classDef + 4);
      return glyph >= start && glyph < start + count
          ? _data.getUint16(classDef + 6 + 2 * (glyph - start))
          : 0;
    }
    final count = _data.getUint16(classDef + 2);
    var low = 0;
    var high = count - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final at = classDef + 4 + 6 * mid;
      if (glyph < _data.getUint16(at)) {
        high = mid - 1;
      } else if (glyph > _data.getUint16(at + 2)) {
        low = mid + 1;
      } else {
        return _data.getUint16(at + 4);
      }
    }
    return 0;
  }

  static int _valueSize(int format) {
    var size = 0;
    for (var bit = 0; bit < 8; bit++) {
      if (format & (1 << bit) != 0) {
        size += 2;
      }
    }
    return size;
  }

  /// (x placement, x advance) of a value record, in font units.
  (int, int) _value(int at, int format) {
    var placement = 0;
    var advance = 0;
    var offset = at;
    if (format & 1 != 0) {
      placement = _data.getInt16(offset);
      offset += 2;
    }
    if (format & 2 != 0) {
      offset += 2;
    }
    if (format & 4 != 0) {
      advance = _data.getInt16(offset);
    }
    return (placement, advance);
  }

  /// The pair adjustment of one subtable for [first] followed by [second]:
  /// ((placement, advance) of the first, of the second, whether the second
  /// glyph is used up), or `null` when the subtable does not cover it.
  ((int, int), (int, int), bool)? _pair(int sub, int first, int second) {
    final format = _data.getUint16(sub);
    final index = _coverageIndex(sub + _data.getUint16(sub + 2), first);
    if (index == null) {
      return null;
    }
    final format1 = _data.getUint16(sub + 4);
    final format2 = _data.getUint16(sub + 6);
    final size1 = _valueSize(format1);
    final size2 = _valueSize(format2);
    if (format == 1) {
      final set = sub + _data.getUint16(sub + 10 + 2 * index);
      final count = _data.getUint16(set);
      final recordSize = 2 + size1 + size2;
      var low = 0;
      var high = count - 1;
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        final at = set + 2 + recordSize * mid;
        final g = _data.getUint16(at);
        if (g == second) {
          return (
            _value(at + 2, format1),
            _value(at + 2 + size1, format2),
            format2 != 0,
          );
        }
        if (g < second) {
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      return null;
    }
    if (format == 2) {
      final class1 = _classOf(sub + _data.getUint16(sub + 8), first);
      final class2 = _classOf(sub + _data.getUint16(sub + 10), second);
      final count1 = _data.getUint16(sub + 12);
      final count2 = _data.getUint16(sub + 14);
      if (class1 >= count1 || class2 >= count2) {
        return null;
      }
      final at = sub + 16 + (class1 * count2 + class2) * (size1 + size2);
      return (_value(at, format1), _value(at + size1, format2), format2 != 0);
    }
    return null;
  }

  /// The kerning of a glyph run: per glyph, what the `kern` feature adds to
  /// its (x placement, x advance), in font units.
  List<(int, int)> kerning(List<int> glyphs) {
    final out = List<(int, int)>.filled(glyphs.length, (0, 0));
    for (final lookup in _kern) {
      var i = 0;
      while (i + 1 < glyphs.length) {
        ((int, int), (int, int), bool)? found;
        for (final sub in lookup.subtables) {
          found = _pair(sub, glyphs[i], glyphs[i + 1]);
          if (found != null) {
            break;
          }
        }
        if (found == null) {
          i++;
          continue;
        }
        final (a, b, usesSecond) = found;
        out[i] = (out[i].$1 + a.$1, out[i].$2 + a.$2);
        out[i + 1] = (out[i + 1].$1 + b.$1, out[i + 1].$2 + b.$2);
        i += usesSecond ? 2 : 1;
      }
    }
    return out;
  }
}

class _PairLookup {
  _PairLookup(this.subtables);

  final List<int> subtables;
}

/// How far the ink of single characters reaches above and below the
/// baseline in whole pixels, per font file and size, as Pillow gives it
/// with the fonts' hinting; see the library comment.
class InkTables {
  InkTables._(this._fonts);

  /// The tables in `assets/fonts/ink_tables.bin`.
  factory InkTables.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes, 0, 5) != 'UWHI2') {
      throw const FormatException('Not an ink table file');
    }
    final fonts = <String, _InkTable>{};
    final count = data.getUint16(5);
    var at = 7;
    for (var f = 0; f < count; f++) {
      final nameLength = bytes[at];
      final name = String.fromCharCodes(bytes, at + 1, at + 1 + nameLength);
      at += 1 + nameLength;
      final maxSize = data.getUint16(at);
      final chars = data.getUint16(at + 2);
      final rowCount = data.getUint16(at + 4);
      at += 6;
      final rowsOf = <int, (int, int)>{};
      for (var c = 0; c < chars; c++) {
        rowsOf[data.getUint32(at)] = (
          data.getUint16(at + 4),
          data.getUint16(at + 6),
        );
        at += 8;
      }
      final packed = data.getUint32(at);
      at += 4;
      final rows = Uint8List(rowCount * maxSize);
      var out = 0;
      for (var i = at; i < at + packed; i += 2) {
        rows.fillRange(out, out + bytes[i], bytes[i + 1]);
        out += bytes[i];
      }
      at += packed;
      fonts[name] = _InkTable(maxSize, rowsOf, rows);
    }
    return InkTables._(fonts);
  }

  final Map<String, _InkTable> _fonts;
}

class _InkTable {
  _InkTable(this.maxSize, this.rowsOf, this.rows);

  final int maxSize;

  /// Character to the rows of its "above" and its "below".
  final Map<int, (int, int)> rowsOf;

  /// Per row and size: the difference from the unhinted estimate, plus 128.
  final Uint8List rows;

  /// (above, below) differences of [codePoint] at [size], or `null`.
  (int, int)? differences(int codePoint, int size) {
    final pair = rowsOf[codePoint];
    if (pair == null || size < 1 || size > maxSize) {
      return null;
    }
    return (
      rows[pair.$1 * maxSize + size - 1] - 128,
      rows[pair.$2 * maxSize + size - 1] - 128,
    );
  }
}

/// One font file at one size, measured as Pillow measures it.
class TtfFont implements HudFont {
  TtfFont(this.face, this.file, this.size, [InkTables? inkTables])
    : _xScale = _divFix(size * 64, face.unitsPerEm),
      _ink = inkTables?._fonts[file] {
    // HarfBuzz's scale of the face, and its multiplier per font unit.
    final hbScale = (_xScale * face.unitsPerEm + 0x8000) >> 16;
    _hbMult = (hbScale << 16) ~/ face.unitsPerEm;
    // The ascender in whole pixels, rounded up.
    ascent = (_mulFix(face.ascender, _xScale) + 63) >> 6;
  }

  final TtfFace face;
  @override
  final String file;
  @override
  final int size;

  /// FreeType's 16.16 scale from font units to 26.6 pixels.
  final int _xScale;
  final _InkTable? _ink;
  late final int _hbMult;

  /// The line top to the baseline, in whole pixels: what Pillow draws and
  /// measures a text from.
  @override
  late final int ascent;

  /// A character the font has no glyph for is drawn as its .notdef box
  /// (Python tells it by comparing the two masks).
  @override
  bool hasGlyph(String char) =>
      char.isNotEmpty && face.glyphIndex(char.runes.first) != 0;

  static int _divFix(int a, int b) => ((a << 16) + (b >> 1)) ~/ b;

  /// FreeType `FT_MulFix`: a * b / 65536, rounded, the sign kept apart.
  static int _mulFix(int a, int b) {
    final negative = a < 0;
    final value = ((negative ? -a : a) * b + 0x8000) >> 16;
    return negative ? -value : value;
  }

  /// A font-unit advance in 26.6 pixels, as HarfBuzz takes it from an
  /// unhinted FreeType face (16.16, then rounded to 1/64).
  int _advance(int units) {
    final fixed = (units * _xScale + 32) ~/ 64;
    return (fixed + (1 << 9)) >> 10;
  }

  /// A GPOS value in 26.6 pixels, as HarfBuzz scales it.
  int _hbScale(int units) => (units * _hbMult + 0x8000) >> 16;

  /// Per character: (code point, glyph, x offset, x advance), the last two
  /// in 26.6 pixels.
  List<(int, int, int, int)> _shape(String text) {
    final runes = text.runes.toList();
    final (glyphs, sources) = face.ligated([
      for (final rune in runes)
        // HarfBuzz draws a no-break space the font lacks as a space.
        rune == 0xa0 && face.glyphIndex(rune) == 0
            ? face.glyphIndex(0x20)
            : face.glyphIndex(rune),
    ]);
    final kerning = face.kerning(glyphs);
    return [
      for (var i = 0; i < glyphs.length; i++)
        (
          // A ligature is no character of the ink tables.
          sources[i] < 0 ? -1 : runes[sources[i]],
          glyphs[i],
          _hbScale(kerning[i].$1),
          _advance(face.advanceWidth(glyphs[i])) + _hbScale(kerning[i].$2),
        ),
    ];
  }

  /// Pillow's `PIXEL`: 26.6 to whole pixels, a half up.
  static int _pixel(int value) => (value + 32) >> 6;

  @override
  double getlength(String text) {
    var total = 0;
    for (final (_, _, _, advance) in _shape(text)) {
      total += advance;
    }
    return total / 64.0;
  }

  @override
  (int, int, int, int) getbbox(String text) {
    if (text.isEmpty) {
      return (0, 0, 0, 0);
    }
    var position = 0;
    var xMin = 0;
    var xMax = 0;
    var above = 0;
    var below = 0;
    for (final (rune, glyph, offset, advance) in _shape(text)) {
      final px = _pixel(position + offset);
      position += advance;
      final advanced = _pixel(position);
      if (advanced > xMax) {
        xMax = advanced;
      }
      final box = face.glyphBox(glyph);
      // The unhinted reach above and below the baseline, and what the
      // hinting changes of it.
      var up = 0;
      var down = 0;
      if (box != null) {
        final left = (_mulFix(box.$1, _xScale) >> 6) + px;
        final right = ((_mulFix(box.$3, _xScale) + 63) >> 6) + px;
        if (right > xMax) {
          xMax = right;
        }
        if (left < xMin) {
          xMin = left;
        }
        up = _pixel(_mulFix(box.$4, _xScale));
        down = _pixel(_mulFix(-box.$2, _xScale));
      }
      final hinted = _ink?.differences(rune, size);
      up = (up < 0 ? 0 : up) + (hinted?.$1 ?? 0);
      down = (down < 0 ? 0 : down) + (hinted?.$2 ?? 0);
      if (up > above) {
        above = up;
      }
      if (down > below) {
        below = down;
      }
    }
    return (xMin, ascent - above, xMax, ascent + below);
  }
}

/// The bundled fonts, read as they are asked for. [load] gives a font
/// file's bytes by its name under `assets/fonts/`; [inkTables] are the
/// hinted ink heights (without them a top or a bottom can be a pixel off
/// Pillow's).
class TtfFonts implements HudFonts {
  TtfFonts(this.load, {this.inkTables});

  final Uint8List Function(String file) load;
  final InkTables? inkTables;
  final Map<String, TtfFace> _faces = {};
  final Map<(String, int), TtfFont> _fonts = {};

  TtfFace face(String file) =>
      _faces.putIfAbsent(file, () => TtfFace(load(file)));

  @override
  TtfFont font(int size, String file) => _fonts.putIfAbsent((
    file,
    size,
  ), () => TtfFont(face(file), file, size, inkTables));
}
