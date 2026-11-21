/// The pixel size of an image from the first bytes of its file, for the
/// skins of the overlay templates (PNG) and what a user may pick instead
/// (JPEG).
library;

import 'dart:typed_data';

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// The width and height of a PNG or JPEG image, or `null` when [bytes] is
/// neither or is cut off before its size. A PNG's size is in its first 24
/// bytes; a JPEG's is in the first frame header, after the application
/// segments.
(int width, int height)? imageSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length >= 24 &&
      Iterable<int>.generate(8).every((i) => bytes[i] == _pngSignature[i]) &&
      String.fromCharCodes(bytes, 12, 16) == 'IHDR') {
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    return width > 0 && height > 0 ? (width, height) : null;
  }
  if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    var at = 2;
    while (at + 4 <= bytes.length) {
      if (bytes[at] != 0xFF) {
        return null;
      }
      final marker = bytes[at + 1];
      if (marker == 0xFF) {
        at += 1; // padding
        continue;
      }
      // Start of frame, but for the tables that share the range.
      final frame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (frame) {
        if (at + 9 > bytes.length) {
          return null;
        }
        final height = data.getUint16(at + 5);
        final width = data.getUint16(at + 7);
        return width > 0 && height > 0 ? (width, height) : null;
      }
      if (marker == 0xD9 || marker == 0xDA) {
        return null;
      }
      // Markers without a length: restarts and the like.
      if (marker >= 0xD0 && marker <= 0xD7 || marker == 0x01) {
        at += 2;
        continue;
      }
      at += 2 + data.getUint16(at + 2);
    }
  }
  return null;
}
