/// A HEIC photo's date and offset tags read and written in pure Dart (the
/// iPhone's photos; owner's decision 2026-11-13, spec §11): the same tags
/// and the same TIFF writer as `jpeg_exif.dart`, in the file's `Exif` item.
///
/// The item is found through the `meta` box: its entry in `iinf` (type
/// `Exif`) and its place in `iloc`. Its data is a four-byte offset to the
/// TIFF header (usually past "Exif\0\0"), then the TIFF block. When the new
/// block is as long as the old (the dates always are) it is written where
/// it was. When it grows, the new item data goes into a `mdat` box of its
/// own at the end of the file and `iloc` points there; nothing else
/// moves, so every other offset in the file stays right. The image data is
/// never touched.
///
/// Not changed: the XMP packet some HEIC files carry (`XMP-xmp:CreateDate`
/// and the like), which keeps its old dates; the photo library and the
/// app read the EXIF ones first.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/metadata/jpeg_exif.dart';

typedef _Box = ({String type, int start, int header, int end});

String _type(Uint8List d, int at) =>
    String.fromCharCodes(d.sublist(at, at + 4));

List<_Box> _boxes(Uint8List d, ByteData v, int start, int end) {
  final out = <_Box>[];
  var at = start;
  while (at + 8 <= end) {
    var size = v.getUint32(at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > end) {
        throw const FormatException('A box runs past the end');
      }
      size = v.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = end - at;
    }
    if (size < header || at + size > end) {
      throw FormatException('A box runs past the end at $at');
    }
    out.add((
      type: _type(d, at + 4),
      start: at,
      header: header,
      end: at + size,
    ));
    at += size;
  }
  return out;
}

int _read(ByteData v, int at, int size) => switch (size) {
  0 => 0,
  4 => v.getUint32(at),
  8 => v.getUint64(at),
  _ => throw FormatException('An iloc field of $size bytes'),
};

void _put(ByteData v, int at, int size, int value) {
  switch (size) {
    case 4:
      if (value > 0xFFFFFFFF) {
        throw const FormatException('The Exif item cannot be placed that far');
      }
      v.setUint32(at, value);
    case 8:
      v.setUint64(at, value);
    default:
      throw const FormatException('The Exif item cannot be moved');
  }
}

/// Where the Exif item's data lies and where its `iloc` fields are.
typedef _ExifItem = ({
  int dataAt,
  int length,
  int offsetFieldAt,
  int offsetSize,
  int lengthFieldAt,
  int lengthSize,
  int baseOffset,
  int method,
});

_ExifItem? _exifItem(Uint8List d) {
  final v = ByteData.sublistView(d);
  if (d.length < 12 || _type(d, 4) != 'ftyp') {
    throw const FormatException('Not a HEIF file');
  }
  final top = _boxes(d, v, 0, d.length);
  final meta = top.where((b) => b.type == 'meta').firstOrNull;
  if (meta == null) {
    return null;
  }
  // A full box: version and flags before its children.
  final children = _boxes(d, v, meta.start + meta.header + 4, meta.end);
  final iinf = children.where((b) => b.type == 'iinf').firstOrNull;
  final iloc = children.where((b) => b.type == 'iloc').firstOrNull;
  final idat = children.where((b) => b.type == 'idat').firstOrNull;
  if (iinf == null || iloc == null) {
    return null;
  }

  int? exifId;
  final infVersion = d[iinf.start + iinf.header];
  final entriesAt = iinf.start + iinf.header + 4 + (infVersion == 0 ? 2 : 4);
  for (final infe in _boxes(d, v, entriesAt, iinf.end)) {
    if (infe.type != 'infe') {
      continue;
    }
    final version = d[infe.start + infe.header];
    if (version < 2) {
      continue;
    }
    var at = infe.start + infe.header + 4;
    final id = version == 2 ? v.getUint16(at) : v.getUint32(at);
    at += (version == 2 ? 2 : 4) + 2;
    if (_type(d, at) == 'Exif') {
      exifId = id;
      break;
    }
  }
  if (exifId == null) {
    return null;
  }

  final version = d[iloc.start + iloc.header];
  var at = iloc.start + iloc.header + 4;
  final offsetSize = d[at] >> 4;
  final lengthSize = d[at] & 0xF;
  final baseSize = d[at + 1] >> 4;
  final indexSize = version == 0 ? 0 : d[at + 1] & 0xF;
  at += 2;
  final count = version < 2 ? v.getUint16(at) : v.getUint32(at);
  at += version < 2 ? 2 : 4;
  for (var i = 0; i < count; i++) {
    final id = version < 2 ? v.getUint16(at) : v.getUint32(at);
    at += version < 2 ? 2 : 4;
    var method = 0;
    if (version > 0) {
      method = v.getUint16(at) & 0xF;
      at += 2;
    }
    at += 2; // data_reference_index
    final base = _read(v, at, baseSize);
    at += baseSize;
    final extents = v.getUint16(at);
    at += 2;
    if (id == exifId) {
      if (extents != 1) {
        throw const FormatException('An Exif item in pieces');
      }
      at += indexSize;
      final offsetAt = at;
      final offset = _read(v, at, offsetSize);
      at += offsetSize;
      final lengthAt = at;
      final length = _read(v, at, lengthSize);
      final int dataAt;
      if (method == 0) {
        dataAt = base + offset;
      } else if (method == 1 && idat != null) {
        dataAt = idat.start + idat.header + base + offset;
      } else {
        throw const FormatException('An Exif item this reader cannot reach');
      }
      if (dataAt + length > d.length || length < 4) {
        throw const FormatException('The Exif item runs past the end');
      }
      return (
        dataAt: dataAt,
        length: length,
        offsetFieldAt: offsetAt,
        offsetSize: offsetSize,
        lengthFieldAt: lengthAt,
        lengthSize: lengthSize,
        baseOffset: base,
        method: method,
      );
    }
    at += extents * (indexSize + offsetSize + lengthSize);
  }
  return null;
}

/// The date and offset tags of the HEIC photo [heic] that it has, by
/// exiftool name. Throws a [FormatException] when it is no HEIF file.
Map<String, String> readHeicDates(Uint8List heic) {
  final item = _exifItem(heic);
  if (item == null) {
    return {};
  }
  final data = Uint8List.sublistView(
    heic,
    item.dataAt,
    item.dataAt + item.length,
  );
  final skip = ByteData.sublistView(data).getUint32(0);
  return readTiffDates(Uint8List.sublistView(data, 4 + skip));
}

/// [heic] with [tags] set (see [jpegDateTags]); the image data as it was.
/// Throws a [FormatException] for a file without an Exif item (a HEIC
/// with no EXIF is not given one), an unknown tag, or an item that would
/// have to grow where it cannot.
Uint8List writeHeicDates(Uint8List heic, Map<String, String> tags) {
  final item = _exifItem(heic);
  if (item == null) {
    throw const FormatException('The photo has no Exif item');
  }
  final data = Uint8List.sublistView(
    heic,
    item.dataAt,
    item.dataAt + item.length,
  );
  final skip = ByteData.sublistView(data).getUint32(0);
  final head = Uint8List.sublistView(data, 0, 4 + skip);
  final tiff = writeTiffDates(Uint8List.sublistView(data, 4 + skip), tags);
  final payload = Uint8List(head.length + tiff.length)
    ..setRange(0, head.length, head)
    ..setRange(head.length, head.length + tiff.length, tiff);
  final out = Uint8List.fromList(heic);
  if (payload.length == item.length) {
    out.setRange(item.dataAt, item.dataAt + payload.length, payload);
    return out;
  }
  if (item.method != 0) {
    throw const FormatException('The Exif item would grow inside the meta box');
  }
  // A last box that runs "to the end of the file" (size 0) would take the
  // new box in: it gets its real size first.
  final top = _boxes(out, ByteData.sublistView(out), 0, out.length);
  final last = top.last;
  final lastView = ByteData.sublistView(out);
  if (lastView.getUint32(last.start) == 0) {
    final size = out.length - last.start;
    if (size > 0xFFFFFFFF) {
      throw const FormatException('The last box is too large to close');
    }
    lastView.setUint32(last.start, size);
  }
  // The new item data in a box of its own at the end.
  final box = ByteData(8)
    ..setUint32(0, 8 + payload.length)
    ..setUint32(4, 0x6D646174); // "mdat"
  final grown = BytesBuilder(copy: false)
    ..add(out)
    ..add(box.buffer.asUint8List())
    ..add(payload);
  final result = grown.toBytes();
  final v = ByteData.sublistView(result);
  final newAt = out.length + 8;
  _put(v, item.offsetFieldAt, item.offsetSize, newAt - item.baseOffset);
  _put(v, item.lengthFieldAt, item.lengthSize, payload.length);
  return result;
}
