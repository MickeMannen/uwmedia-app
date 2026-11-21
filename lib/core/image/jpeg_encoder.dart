/// A baseline JPEG writer that takes its quantisation tables and chroma
/// subsampling from the caller, so that a photo the app has changed can
/// be saved the way its source was (Python saves through Pillow with
/// `qtables=`, `subsampling=` and `optimize=True`).
///
/// It follows libjpeg's own integer arithmetic step by step (the colour
/// conversion, the edge padding, the downsampling, the accurate integer
/// DCT, the rounding of the division by the table, the Huffman tables made
/// for the picture), which is what Pillow writes with, so that the files
/// are the same.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/image/jpeg_tables.dart';

/// Where each value of a table or block in the file's (zigzag) order lies
/// in the 8x8 block read row by row.
const List<int> jpegZigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

/// The tables of quality 100: every step 1.
final List<List<int>> jpegFinestTables = [
  List.filled(64, 1),
  List.filled(64, 1),
];

int _fix(double x) => (x * 65536 + 0.5).truncate();

// One component's samples, padded to whole blocks.
class _Plane {
  _Plane(this.width, this.height) : data = Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List data;
}

// The accurate integer forward DCT of libjpeg (jfdctint.c), in place on
// 64 level-shifted samples; the results are 8 times the true ones.
void _fdct(Int32List d) {
  const c0298 = 2446, c0390 = 3196, c0541 = 4433, c0765 = 6270;
  const c0899 = 7373, c1175 = 9633, c1501 = 12299, c1847 = 15137;
  const c1961 = 16069, c2053 = 16819, c2562 = 20995, c3072 = 25172;
  for (var i = 0; i < 64; i += 8) {
    final t0 = d[i] + d[i + 7], t7 = d[i] - d[i + 7];
    final t1 = d[i + 1] + d[i + 6], t6 = d[i + 1] - d[i + 6];
    final t2 = d[i + 2] + d[i + 5], t5 = d[i + 2] - d[i + 5];
    final t3 = d[i + 3] + d[i + 4], t4 = d[i + 3] - d[i + 4];
    final t10 = t0 + t3, t13 = t0 - t3, t11 = t1 + t2, t12 = t1 - t2;
    d[i] = (t10 + t11) << 2;
    d[i + 4] = (t10 - t11) << 2;
    var z1 = (t12 + t13) * c0541;
    d[i + 2] = (z1 + t13 * c0765 + 1024) >> 11;
    d[i + 6] = (z1 - t12 * c1847 + 1024) >> 11;
    z1 = t4 + t7;
    var z2 = t5 + t6;
    var z3 = t4 + t6;
    var z4 = t5 + t7;
    final z5 = (z3 + z4) * c1175;
    final a4 = t4 * c0298, a5 = t5 * c2053, a6 = t6 * c3072, a7 = t7 * c1501;
    z1 *= -c0899;
    z2 *= -c2562;
    z3 = z3 * -c1961 + z5;
    z4 = z4 * -c0390 + z5;
    d[i + 7] = (a4 + z1 + z3 + 1024) >> 11;
    d[i + 5] = (a5 + z2 + z4 + 1024) >> 11;
    d[i + 3] = (a6 + z2 + z3 + 1024) >> 11;
    d[i + 1] = (a7 + z1 + z4 + 1024) >> 11;
  }
  for (var i = 0; i < 8; i++) {
    final t0 = d[i] + d[i + 56], t7 = d[i] - d[i + 56];
    final t1 = d[i + 8] + d[i + 48], t6 = d[i + 8] - d[i + 48];
    final t2 = d[i + 16] + d[i + 40], t5 = d[i + 16] - d[i + 40];
    final t3 = d[i + 24] + d[i + 32], t4 = d[i + 24] - d[i + 32];
    final t10 = t0 + t3, t13 = t0 - t3, t11 = t1 + t2, t12 = t1 - t2;
    d[i] = (t10 + t11 + 2) >> 2;
    d[i + 32] = (t10 - t11 + 2) >> 2;
    var z1 = (t12 + t13) * c0541;
    d[i + 16] = (z1 + t13 * c0765 + 16384) >> 15;
    d[i + 48] = (z1 - t12 * c1847 + 16384) >> 15;
    z1 = t4 + t7;
    var z2 = t5 + t6;
    var z3 = t4 + t6;
    var z4 = t5 + t7;
    final z5 = (z3 + z4) * c1175;
    final a4 = t4 * c0298, a5 = t5 * c2053, a6 = t6 * c3072, a7 = t7 * c1501;
    z1 *= -c0899;
    z2 *= -c2562;
    z3 = z3 * -c1961 + z5;
    z4 = z4 * -c0390 + z5;
    d[i + 56] = (a4 + z1 + z3 + 16384) >> 15;
    d[i + 40] = (a5 + z2 + z4 + 16384) >> 15;
    d[i + 24] = (a6 + z2 + z3 + 16384) >> 15;
    d[i + 8] = (a7 + z1 + z4 + 16384) >> 15;
  }
}

// The code lengths of a Huffman table made for the counted symbols, as
// libjpeg makes it (jchuff.c, the procedure of the JPEG standard's
// section K.2): how many codes there are of each length 1..16, and the
// symbols in the order of their codes.
(List<int> bits, List<int> symbols) _optimalTable(List<int> counts) {
  final freq = List<int>.of(counts)..add(1); // 256: keeps all-ones unused
  final codesize = List.filled(257, 0);
  final others = List.filled(257, -1);
  while (true) {
    var c1 = -1;
    var v = 1000000000;
    for (var i = 0; i <= 256; i++) {
      if (freq[i] != 0 && freq[i] <= v) {
        v = freq[i];
        c1 = i;
      }
    }
    var c2 = -1;
    v = 1000000000;
    for (var i = 0; i <= 256; i++) {
      if (freq[i] != 0 && freq[i] <= v && i != c1) {
        v = freq[i];
        c2 = i;
      }
    }
    if (c2 < 0) {
      break;
    }
    freq[c1] += freq[c2];
    freq[c2] = 0;
    codesize[c1]++;
    while (others[c1] >= 0) {
      c1 = others[c1];
      codesize[c1]++;
    }
    others[c1] = c2;
    codesize[c2]++;
    while (others[c2] >= 0) {
      c2 = others[c2];
      codesize[c2]++;
    }
  }
  final bits = List.filled(34, 0);
  for (var i = 0; i <= 256; i++) {
    if (codesize[i] != 0) {
      bits[codesize[i]]++;
    }
  }
  // No code longer than 16 bits.
  for (var i = 32; i > 16; i--) {
    while (bits[i] > 0) {
      var j = i - 2;
      while (bits[j] == 0) {
        j--;
      }
      bits[i] -= 2;
      bits[i - 1]++;
      bits[j + 1] += 2;
      bits[j]--;
    }
  }
  // The pseudo-symbol's code, the longest, is given up.
  var longest = 16;
  while (bits[longest] == 0) {
    longest--;
  }
  bits[longest]--;
  final symbols = <int>[];
  for (var size = 1; size <= 32; size++) {
    for (var s = 0; s < 256; s++) {
      if (codesize[s] == size) {
        symbols.add(s);
      }
    }
  }
  return (bits.sublist(1, 17), symbols);
}

// Code and length per symbol of a table.
(Int32List codes, Uint8List sizes) _codesOf(List<int> bits, List<int> symbols) {
  final codes = Int32List(256);
  final sizes = Uint8List(256);
  var code = 0;
  var k = 0;
  for (var length = 1; length <= 16; length++) {
    for (var i = 0; i < bits[length - 1]; i++) {
      codes[symbols[k]] = code;
      sizes[symbols[k]] = length;
      code++;
      k++;
    }
    code <<= 1;
  }
  return (codes, sizes);
}

int _magnitudeBits(int value) {
  var v = value < 0 ? -value : value;
  var n = 0;
  while (v != 0) {
    n++;
    v >>= 1;
  }
  return n;
}

class _BitWriter {
  final BytesBuilder out = BytesBuilder(copy: false);
  int _buffer = 0;
  int _count = 0;

  void put(int code, int size) {
    _buffer = (_buffer << size) | (code & ((1 << size) - 1));
    _count += size;
    while (_count >= 8) {
      final byte = (_buffer >> (_count - 8)) & 0xFF;
      out.addByte(byte);
      if (byte == 0xFF) {
        out.addByte(0);
      }
      _count -= 8;
    }
    _buffer &= (1 << _count) - 1;
  }

  void finish() {
    if (_count > 0) {
      put(0x7F, 7); // filled up with ones
      _count = 0;
      _buffer = 0;
    }
  }
}

/// [rgb] ([width] x [height], three bytes a pixel) as a JPEG file.
///
/// [quantTables] are one to four tables of 64 steps in zigzag order (a
/// file's own, [usableQuantTables]); the luma takes the first, the chroma
/// the second when there is one, and with three or more the two chroma
/// components the second and the third. A step of 0 counts as 1; steps
/// over 255 make the file one only newer readers take ("extended", as
/// libjpeg writes it). [sampling] defaults to 4:2:0.
Uint8List encodeJpeg(
  Uint8List rgb,
  int width,
  int height, {
  required List<List<int>> quantTables,
  JpegSampling? sampling,
}) {
  if (width < 1 || height < 1 || width > 65535 || height > 65535) {
    throw ArgumentError('A JPEG is 1 to 65535 pixels a side');
  }
  if (rgb.length != width * height * 3) {
    throw ArgumentError('Three bytes a pixel');
  }
  if (quantTables.isEmpty ||
      quantTables.length > 4 ||
      quantTables.any((t) => t.length != 64)) {
    throw ArgumentError('One to four tables of 64 steps');
  }
  final tables = [
    for (final table in quantTables.take(3))
      [for (final step in table) step < 1 ? 1 : (step > 32767 ? 32767 : step)],
  ];
  final wide = tables.any((t) => t.any((step) => step > 255));
  final chroma = sampling ?? JpegSampling.s420;
  final hMax = chroma.h;
  final vMax = chroma.v;
  // Table numbers of Y, Cb and Cr.
  final tq = [
    0,
    tables.length > 1 ? 1 : 0,
    tables.length > 2 ? 2 : (tables.length > 1 ? 1 : 0),
  ];

  // --- colour conversion, on the picture padded to whole MCUs -----------
  final mcuW = 8 * hMax;
  final mcuH = 8 * vMax;
  final mcusX = (width + mcuW - 1) ~/ mcuW;
  final mcusY = (height + mcuH - 1) ~/ mcuH;
  final fullW = mcusX * mcuW;
  // Rows are padded only to a whole group for the downsampling; below
  // that the last row of each component, as it then is, repeats.
  final fullH = (height + vMax - 1) ~/ vMax * vMax;
  final y = _Plane(fullW, fullH);
  final cbFull = _Plane(fullW, fullH);
  final crFull = _Plane(fullW, fullH);
  final r299 = _fix(0.29900), g587 = _fix(0.58700), b114 = _fix(0.11400);
  final r168 = _fix(0.16874), g331 = _fix(0.33126), half = _fix(0.50000);
  final g418 = _fix(0.41869), b081 = _fix(0.08131);
  const oneHalf = 1 << 15;
  const offset = 128 << 16;
  for (var row = 0; row < fullH; row++) {
    final src = (row < height ? row : height - 1) * width * 3;
    final dst = row * fullW;
    for (var col = 0; col < fullW; col++) {
      final s = src + (col < width ? col : width - 1) * 3;
      final r = rgb[s], g = rgb[s + 1], b = rgb[s + 2];
      y.data[dst + col] = (r299 * r + g587 * g + b114 * b + oneHalf) >> 16;
      cbFull.data[dst + col] =
          (-r168 * r - g331 * g + half * b + offset + oneHalf - 1) >> 16;
      crFull.data[dst + col] =
          (half * r - g418 * g - b081 * b + offset + oneHalf - 1) >> 16;
    }
  }

  // --- the chroma at its own resolution -----------------------------------
  _Plane downsampled(_Plane full) {
    if (hMax == 1 && vMax == 1) {
      return full;
    }
    final out = _Plane(full.width ~/ hMax, full.height ~/ vMax);
    for (var row = 0; row < out.height; row++) {
      final o = row * out.width;
      if (vMax == 1) {
        final i = row * full.width;
        var bias = 0;
        for (var col = 0; col < out.width; col++) {
          out.data[o + col] =
              (full.data[i + 2 * col] + full.data[i + 2 * col + 1] + bias) >> 1;
          bias ^= 1;
        }
      } else {
        final i0 = 2 * row * full.width;
        final i1 = i0 + full.width;
        var bias = 1;
        for (var col = 0; col < out.width; col++) {
          out.data[o + col] =
              (full.data[i0 + 2 * col] +
                  full.data[i0 + 2 * col + 1] +
                  full.data[i1 + 2 * col] +
                  full.data[i1 + 2 * col + 1] +
                  bias) >>
              2;
          bias ^= 3;
        }
      }
    }
    return out;
  }

  final planes = [y, downsampled(cbFull), downsampled(crFull)];
  final hs = [hMax, 1, 1];
  final vs = [vMax, 1, 1];
  // The blocks a component really has; the rest of an MCU at the right
  // and bottom edge are dummies.
  int ceilDiv(int a, int b) => (a + b - 1) ~/ b;
  final blocksW = [
    for (var c = 0; c < 3; c++) ceilDiv(width * hs[c], 8 * hMax),
  ];
  final blocksH = [
    for (var c = 0; c < 3; c++) ceilDiv(height * vs[c], 8 * vMax),
  ];

  // --- the coefficients, MCU by MCU ----------------------------------------
  final blocksPerMcu = hMax * vMax + 2;
  final coefficients = Int16List(mcusX * mcusY * blocksPerMcu * 64);
  final blockComponent = [for (var i = 0; i < hMax * vMax; i++) 0, 1, 2];
  final divisors = [
    for (final table in tables)
      Int32List.fromList([
        // The DCT's results are 8 times too big; the table is in zigzag
        // order, the block in rows.
        for (var i = 0; i < 64; i++) table[jpegZigzag.indexOf(i)] << 3,
      ]),
  ];
  final work = Int32List(64);
  var at = 0;
  for (var my = 0; my < mcusY; my++) {
    for (var mx = 0; mx < mcusX; mx++) {
      var blockInMcu = 0;
      for (var c = 0; c < 3; c++) {
        final plane = planes[c];
        final divisor = divisors[tq[c]];
        for (var by = 0; by < vs[c]; by++) {
          for (var bx = 0; bx < hs[c]; bx++) {
            final blockX = mx * hs[c] + bx;
            final blockY = my * vs[c] + by;
            if (blockX < blocksW[c] && blockY < blocksH[c]) {
              var k = 0;
              for (var row = 0; row < 8; row++) {
                final line = blockY * 8 + row;
                final i =
                    (line < plane.height ? line : plane.height - 1) *
                        plane.width +
                    blockX * 8;
                for (var col = 0; col < 8; col++) {
                  work[k++] = plane.data[i + col] - 128;
                }
              }
              _fdct(work);
              for (var i = 0; i < 64; i++) {
                final q = divisor[i];
                var v = work[i];
                if (v < 0) {
                  v = -((-v + (q >> 1)) ~/ q);
                } else {
                  v = (v + (q >> 1)) ~/ q;
                }
                coefficients[at + i] = v;
              }
            } else if (blockInMcu > 0 || at >= 64) {
              // A dummy block: flat, at the level of the block before it.
              coefficients[at] = coefficients[at - 64];
            }
            at += 64;
            blockInMcu++;
          }
        }
      }
    }
  }

  // --- Huffman tables made for these coefficients -----------------------
  // Tables 0 for the luma, 1 for the chroma.
  final dcCounts = [List.filled(256, 0), List.filled(256, 0)];
  final acCounts = [List.filled(256, 0), List.filled(256, 0)];
  void scan(
    void Function(int table, bool dc, int symbol, int bits, int size) emit,
  ) {
    final lastDc = [0, 0, 0];
    var p = 0;
    final blocks = mcusX * mcusY * blocksPerMcu;
    for (var b = 0; b < blocks; b++) {
      final c = blockComponent[b % blocksPerMcu];
      final table = c == 0 ? 0 : 1;
      final diff = coefficients[p] - lastDc[c];
      lastDc[c] = coefficients[p];
      final size = _magnitudeBits(diff);
      emit(table, true, size, diff < 0 ? diff - 1 : diff, size);
      var run = 0;
      for (var k = 1; k < 64; k++) {
        final v = coefficients[p + jpegZigzag[k]];
        if (v == 0) {
          run++;
          continue;
        }
        while (run > 15) {
          emit(table, false, 0xF0, 0, 0);
          run -= 16;
        }
        final bits = _magnitudeBits(v);
        emit(table, false, (run << 4) | bits, v < 0 ? v - 1 : v, bits);
        run = 0;
      }
      if (run > 0) {
        emit(table, false, 0, 0, 0);
      }
      p += 64;
    }
  }

  scan(
    (table, dc, symbol, _, _) => (dc ? dcCounts : acCounts)[table][symbol]++,
  );
  final dcTables = [for (final counts in dcCounts) _optimalTable(counts)];
  final acTables = [for (final counts in acCounts) _optimalTable(counts)];

  // --- the file ---------------------------------------------------------
  final out = BytesBuilder(copy: false);
  void marker(int code, List<int> payload) {
    final length = payload.length + 2;
    out
      ..add([0xFF, code, length >> 8, length & 0xFF])
      ..add(payload);
  }

  out.add([0xFF, 0xD8]);
  // JFIF 1.01, no pixel density, no thumbnail.
  marker(0xE0, [0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
  for (final (id, table) in tables.indexed) {
    final big = table.any((step) => step > 255);
    marker(0xDB, [
      (big ? 0x10 : 0) | id,
      for (final step in table) ...(big ? [step >> 8, step & 0xFF] : [step]),
    ]);
  }
  marker(wide ? 0xC1 : 0xC0, [
    8,
    height >> 8,
    height & 0xFF,
    width >> 8,
    width & 0xFF,
    3,
    for (var c = 0; c < 3; c++) ...[c + 1, hs[c] << 4 | vs[c], tq[c]],
  ]);
  for (var table = 0; table < 2; table++) {
    marker(0xC4, [table, ...dcTables[table].$1, ...dcTables[table].$2]);
    marker(0xC4, [0x10 | table, ...acTables[table].$1, ...acTables[table].$2]);
  }
  marker(0xDA, [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]);

  final dcCodes = [for (final t in dcTables) _codesOf(t.$1, t.$2)];
  final acCodes = [for (final t in acTables) _codesOf(t.$1, t.$2)];
  final writer = _BitWriter();
  scan((table, dc, symbol, bits, size) {
    final (codes, sizes) = (dc ? dcCodes : acCodes)[table];
    writer.put(codes[symbol], sizes[symbol]);
    if (size > 0) {
      writer.put(bits, size);
    }
  });
  writer.finish();
  out
    ..add(writer.out.takeBytes())
    ..add([0xFF, 0xD9]);
  return out.takeBytes();
}
