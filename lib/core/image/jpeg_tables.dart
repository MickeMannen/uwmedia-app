/// What the app reads out of a JPEG file to write another like it: the
/// quantisation tables (how coarsely the picture is stored) and how the
/// colour is subsampled. A corrected photo is saved with its source's, so
/// that it comes out at the source's quality (Python: Pillow's
/// `img.quantization` and `JpegImagePlugin.get_sampling`).
library;

import 'dart:typed_data';

/// The chroma subsampling of a JPEG as Pillow numbers it.
enum JpegSampling {
  /// 4:4:4, colour at full resolution.
  s444(0, 1, 1),

  /// 4:2:2, colour halved across.
  s422(1, 2, 1),

  /// 4:2:0, colour halved both ways (the default of a JPEG writer).
  s420(2, 2, 2);

  const JpegSampling(this.pillow, this.h, this.v);

  /// Pillow's number for it.
  final int pillow;

  /// The luma's sampling factors against the chroma's 1x1.
  final int h;
  final int v;
}

/// The tables and subsampling of a JPEG file.
typedef JpegTables = ({
  /// Quantisation tables by their number in the file, each 64 values in
  /// the file's (zigzag) order.
  Map<int, List<int>> quantization,

  /// `null` for anything but a three-component picture in one of the
  /// three common subsamplings (grey, CMYK, 4:1:1 …): a writer then takes
  /// its default.
  JpegSampling? sampling,
});

/// The quantisation tables and subsampling of the JPEG in [bytes]; `null`
/// when it is not a JPEG that can be read that far.
JpegTables? readJpegTables(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return null;
  }
  final tables = <int, List<int>>{};
  List<(int, int)>? layers;
  var at = 2;
  while (at + 4 <= bytes.length) {
    if (bytes[at] != 0xFF) {
      return null;
    }
    final marker = bytes[at + 1];
    if (marker == 0xFF) {
      at++; // fill byte
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) {
      break; // end of image, or the picture data begins
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      at += 2; // markers without a length
      continue;
    }
    final length = bytes[at + 2] << 8 | bytes[at + 3];
    final end = at + 2 + length;
    if (length < 2 || end > bytes.length) {
      return null;
    }
    var p = at + 4;
    if (marker == 0xDB) {
      while (p < end) {
        final wide = bytes[p] >> 4 != 0;
        final id = bytes[p] & 0x0F;
        p++;
        final size = wide ? 128 : 64;
        if (p + size > end) {
          return null;
        }
        tables[id] = [
          for (var i = 0; i < 64; i++)
            wide ? bytes[p + 2 * i] << 8 | bytes[p + 2 * i + 1] : bytes[p + i],
        ];
        p += size;
      }
    } else if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      // A frame header: precision, height, width, then the components.
      if (p + 6 > end) {
        return null;
      }
      final count = bytes[p + 5];
      if (p + 6 + 3 * count > end) {
        return null;
      }
      layers = [
        for (var i = 0; i < count; i++)
          (bytes[p + 7 + 3 * i] >> 4, bytes[p + 7 + 3 * i] & 0x0F),
      ];
    }
    at = end;
  }
  if (tables.isEmpty && layers == null) {
    return null;
  }
  JpegSampling? sampling;
  if (layers != null && layers.length == 3) {
    final chromaFull = layers[1] == (1, 1) && layers[2] == (1, 1);
    sampling = !chromaFull
        ? null
        : JpegSampling.values
              .where((s) => (s.h, s.v) == layers![0])
              .firstOrNull;
  }
  return (quantization: tables, sampling: sampling);
}

/// The tables a writer uses out of a file's [quantization], as Pillow
/// takes them: those numbered 0, 1, 2 … without a gap, four at most;
/// `null` when table 0 is missing.
List<List<int>>? usableQuantTables(Map<int, List<int>> quantization) {
  final tables = [
    for (var id = 0; id < quantization.length; id++)
      if (quantization[id] case final List<int> table) table,
  ];
  return tables.isEmpty || tables.length > 4 ? null : tables;
}
