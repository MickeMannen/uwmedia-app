/// A JPEG's date and offset tags read and written in pure Dart (owner,
/// 2026-11-13: the phones' photo date writer, no native plugin; spec §11).
///
/// Only the EXIF block (the APP1 segment) changes; the image data is
/// copied as it is. A tag that is there with a value of the same length
/// (the dates always are) is overwritten in place. A tag that is missing
/// goes into a copy of the EXIF directory written at the end of the block,
/// with the directory's other entries as they were: every value outside
/// that directory (the maker notes, the thumbnail) stays where it was, so
/// the offsets pointing at them stay right. A photo without EXIF gets a
/// block of its own after the JFIF header.
///
/// The tags by their exiftool names: `EXIF:ModifyDate` (in IFD0, written
/// only when it is there), `EXIF:DateTimeOriginal`, `EXIF:CreateDate`,
/// `EXIF:OffsetTime`, `EXIF:OffsetTimeOriginal` and
/// `EXIF:OffsetTimeDigitized`.
library;

import 'dart:convert';
import 'dart:typed_data';

const _exifIfdPointer = 0x8769;
const _ascii = 2;
const _long = 4;
const _undefined = 7;

/// ExifVersion, which a new EXIF directory must carry: "0232".
const _exifVersion = 0x9000;

/// The tags this module reads and writes, by exiftool name: (IFD, tag).
const Map<String, (int, int)> jpegDateTags = {
  'EXIF:ModifyDate': (0, 0x0132),
  'EXIF:DateTimeOriginal': (1, 0x9003),
  'EXIF:CreateDate': (1, 0x9004),
  'EXIF:OffsetTime': (1, 0x9010),
  'EXIF:OffsetTimeOriginal': (1, 0x9011),
  'EXIF:OffsetTimeDigitized': (1, 0x9012),
};

/// The camera's maker and model, by exiftool name: the tag in the first
/// directory. Read with the dates, never written.
const Map<String, int> jpegCameraTags = {
  'EXIF:Make': 0x010F,
  'EXIF:Model': 0x0110,
};

// One segment of a JPEG before the image data: its marker and where its
// payload (after the two length bytes) lies.
typedef _Segment = ({int marker, int start, int payload, int end});

List<_Segment> _segments(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) {
    throw const FormatException('Not a JPEG');
  }
  final out = <_Segment>[];
  var i = 2;
  while (i + 4 <= jpeg.length) {
    if (jpeg[i] != 0xFF) {
      throw FormatException('No marker at $i');
    }
    final marker = jpeg[i + 1];
    if (marker == 0xFF) {
      // Fill bytes before a marker.
      i++;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) {
      // The image data (or the end): nothing more to read.
      break;
    }
    final length = jpeg[i + 2] << 8 | jpeg[i + 3];
    final end = i + 2 + length;
    if (length < 2 || end > jpeg.length) {
      throw FormatException('A segment runs past the end at $i');
    }
    out.add((marker: marker, start: i, payload: i + 4, end: end));
    i = end;
  }
  return out;
}

const _exifHeader = [0x45, 0x78, 0x69, 0x66, 0, 0]; // "Exif\0\0"

_Segment? _exifSegment(Uint8List jpeg, List<_Segment> segments) {
  for (final s in segments) {
    if (s.marker == 0xE1 && s.end - s.payload >= 14) {
      var match = true;
      for (var k = 0; k < 6; k++) {
        if (jpeg[s.payload + k] != _exifHeader[k]) {
          match = false;
          break;
        }
      }
      if (match) {
        return s;
      }
    }
  }
  return null;
}

/// A TIFF block (the EXIF data after "Exif\0\0"), read and grown.
class _Tiff {
  _Tiff(Uint8List bytes) : _bytes = BytesBuilder()..add(bytes) {
    _refresh();
    if (!(_at(0) == 0x49 && _at(1) == 0x49) &&
        !(_at(0) == 0x4D && _at(1) == 0x4D)) {
      throw const FormatException('Not a TIFF header');
    }
  }

  BytesBuilder _bytes;
  late Uint8List _view;
  late ByteData _data;

  void _refresh() {
    _view = _bytes.toBytes();
    _data = ByteData.sublistView(_view);
  }

  int _at(int i) => _view[i];
  Endian get _endian => _at(0) == 0x49 ? Endian.little : Endian.big;
  int u16(int at) => _data.getUint16(at, _endian);
  int u32(int at) => _data.getUint32(at, _endian);
  int get length => _view.length;
  Uint8List get bytes => _view;

  int get ifd0 => u32(4);

  void setU32(int at, int value) {
    final copy = Uint8List.fromList(_view);
    ByteData.sublistView(copy).setUint32(at, value, _endian);
    _bytes = BytesBuilder()..add(copy);
    _refresh();
  }

  void setBytes(int at, List<int> value) {
    final copy = Uint8List.fromList(_view)
      ..setRange(at, at + value.length, value);
    _bytes = BytesBuilder()..add(copy);
    _refresh();
  }

  /// [value] put at the end (on an even offset); its offset.
  int append(List<int> value) {
    if (_view.length.isOdd) {
      _bytes.addByte(0);
    }
    final at = _bytes.length;
    _bytes.add(value);
    _refresh();
    return at;
  }

  /// The entries of the directory at [offset]: tag → the entry's offset.
  Map<int, int> entries(int offset) {
    if (offset <= 0 || offset + 2 > length) {
      return {};
    }
    final count = u16(offset);
    if (offset + 2 + count * 12 + 4 > length) {
      throw const FormatException('A directory runs past the end');
    }
    return {
      for (var i = 0; i < count; i++)
        u16(offset + 2 + i * 12): offset + 2 + i * 12,
    };
  }

  /// The text of the ASCII entry at [entry], without its NUL.
  String? ascii(int entry) {
    if (u16(entry + 2) != _ascii) {
      return null;
    }
    final count = u32(entry + 4);
    final at = count <= 4 ? entry + 8 : u32(entry + 8);
    if (at + count > length) {
      return null;
    }
    var end = at + count;
    while (end > at && _view[end - 1] == 0) {
      end--;
    }
    return latin1.decode(_view.sublist(at, end));
  }

  /// Overwrites the ASCII entry at [entry] with [value] when it is that
  /// long already; false otherwise.
  bool overwrite(int entry, List<int> value) {
    if (u16(entry + 2) != _ascii || u32(entry + 4) != value.length) {
      return false;
    }
    setBytes(value.length <= 4 ? entry + 8 : u32(entry + 8), value);
    return true;
  }

  /// A copy of the directory at [offset] (none: an empty one) with
  /// [values] (ASCII, NUL included) set, written at the end; its offset.
  /// The other entries are copied as they are; the next-directory link is
  /// kept.
  int rewrite(
    int offset,
    Map<int, List<int>> values, {
    Map<int, int>? longs,
    Map<int, List<int>>? undefined,
  }) {
    final old = entries(offset);
    final rows = <int, List<int>>{};
    for (final MapEntry(key: tag, value: at) in old.entries) {
      rows[tag] = _view.sublist(at, at + 12);
    }
    final next = offset > 0 && old.isNotEmpty
        ? u32(offset + 2 + old.length * 12)
        : 0;
    Uint8List row(int tag, int type, int count, int value) {
      final b = ByteData(12);
      b
        ..setUint16(0, tag, _endian)
        ..setUint16(2, type, _endian)
        ..setUint32(4, count, _endian)
        ..setUint32(8, value, _endian);
      return b.buffer.asUint8List();
    }

    for (final MapEntry(key: tag, value: text) in values.entries) {
      if (text.length <= 4) {
        final r = row(tag, _ascii, text.length, 0);
        r.setRange(8, 8 + text.length, text);
        rows[tag] = r;
      } else {
        rows[tag] = row(tag, _ascii, text.length, append(text));
      }
    }
    for (final MapEntry(key: tag, value: v) in (longs ?? {}).entries) {
      rows[tag] = row(tag, _long, 1, v);
    }
    // Four bytes or fewer, kept in the entry itself.
    for (final MapEntry(key: tag, value: bytes) in (undefined ?? {}).entries) {
      final r = row(tag, _undefined, bytes.length, 0);
      r.setRange(8, 8 + bytes.length, bytes);
      rows[tag] = r;
    }
    final sorted = rows.keys.toList()..sort();
    final table = BytesBuilder();
    final count = ByteData(2)..setUint16(0, sorted.length, _endian);
    table.add(count.buffer.asUint8List());
    for (final tag in sorted) {
      table.add(rows[tag]!);
    }
    final link = ByteData(4)..setUint32(0, next, _endian);
    table.add(link.buffer.asUint8List());
    return append(table.toBytes());
  }
}

List<int> _asciiValue(String text) => [...latin1.encode(text), 0];

/// The date and offset tags of a TIFF block (EXIF without its "Exif\0\0"
/// header) that it has, by exiftool name.
Map<String, String> readTiffDates(Uint8List block) {
  final tiff = _Tiff(block);
  final ifd0 = tiff.entries(tiff.ifd0);
  final pointer = ifd0[_exifIfdPointer];
  final exif = pointer == null
      ? <int, int>{}
      : tiff.entries(tiff.u32(pointer + 8));
  final out = <String, String>{};
  jpegDateTags.forEach((name, where) {
    final entry = (where.$1 == 0 ? ifd0 : exif)[where.$2];
    final text = entry == null ? null : tiff.ascii(entry);
    if (text != null) {
      out[name] = text;
    }
  });
  // Which camera it was (read only; spec §10.72).
  jpegCameraTags.forEach((name, tag) {
    final entry = ifd0[tag];
    final text = entry == null ? null : tiff.ascii(entry)?.trim();
    if (text != null && text.isNotEmpty) {
      out[name] = text;
    }
  });
  return out;
}

/// The TIFF block [block] (`null`: none yet) with [tags] set (see
/// [jpegDateTags]): the same length when every tag was there with a value
/// as long, else longer, with every value outside the EXIF directory where
/// it was.
Uint8List writeTiffDates(Uint8List? block, Map<String, String> tags) {
  for (final name in tags.keys) {
    if (!jpegDateTags.containsKey(name)) {
      throw FormatException('Not a date tag this writer knows: $name');
    }
  }
  final tiff = _Tiff(
    block == null
        // A TIFF header and an empty IFD0 to build on.
        ? Uint8List.fromList([
            0x49,
            0x49,
            0x2A,
            0,
            8,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
          ])
        : Uint8List.fromList(block),
  );

  final ifd0 = tiff.entries(tiff.ifd0);
  final modify = tags['EXIF:ModifyDate'];
  if (modify != null && ifd0.containsKey(0x0132)) {
    final value = _asciiValue(modify);
    if (!tiff.overwrite(ifd0[0x0132]!, value)) {
      // Another length: IFD0 rewritten with it.
      final at = tiff.rewrite(tiff.ifd0, {0x0132: value});
      tiff.setU32(4, at);
    }
  }

  final wanted = <int, List<int>>{
    for (final MapEntry(:key, :value) in tags.entries)
      if (jpegDateTags[key]!.$1 == 1) jpegDateTags[key]!.$2: _asciiValue(value),
  };
  if (wanted.isNotEmpty) {
    var ifd0Now = tiff.entries(tiff.ifd0);
    final pointer = ifd0Now[_exifIfdPointer];
    final exifAt = pointer == null ? 0 : tiff.u32(pointer + 8);
    final exif = tiff.entries(exifAt);
    final missing = <int, List<int>>{};
    wanted.forEach((tag, value) {
      final entry = exif[tag];
      if (entry == null || !tiff.overwrite(entry, value)) {
        missing[tag] = value;
      }
    });
    if (missing.isNotEmpty) {
      // A directory made new gets the version every EXIF directory has.
      final moved = tiff.rewrite(
        exifAt,
        missing,
        undefined: exifAt == 0 ? {_exifVersion: '0232'.codeUnits} : null,
      );
      ifd0Now = tiff.entries(tiff.ifd0);
      final link = ifd0Now[_exifIfdPointer];
      if (link != null) {
        tiff.setU32(link + 8, moved);
      } else {
        final at = tiff.rewrite(
          tiff.ifd0,
          const {},
          longs: {_exifIfdPointer: moved},
        );
        tiff.setU32(4, at);
      }
    }
  }
  return tiff.bytes;
}

/// The date and offset tags of [jpeg] that it has, by exiftool name.
/// Throws a [FormatException] when it is no JPEG.
Map<String, String> readJpegDates(Uint8List jpeg) {
  final segment = _exifSegment(jpeg, _segments(jpeg));
  if (segment == null) {
    return {};
  }
  return readTiffDates(
    Uint8List.sublistView(jpeg, segment.payload + 6, segment.end),
  );
}

/// [jpeg] with [tags] (exiftool names, see [jpegDateTags]) set; the image
/// data as it was. `EXIF:ModifyDate` is only written when the photo has
/// it. Throws a [FormatException] for an unknown tag, a photo that is no
/// JPEG, or an EXIF block that would grow past a segment's 64 KB.
Uint8List writeJpegDates(Uint8List jpeg, Map<String, String> tags) {
  final segments = _segments(jpeg);
  final segment = _exifSegment(jpeg, segments);
  final tiff = writeTiffDates(
    segment == null
        ? null
        : Uint8List.sublistView(jpeg, segment.payload + 6, segment.end),
    tags,
  );
  final block = [..._exifHeader, ...tiff];
  if (block.length + 2 > 0xFFFF) {
    throw const FormatException('The EXIF block would pass 64 KB');
  }
  final app1 = [
    0xFF,
    0xE1,
    (block.length + 2) >> 8,
    (block.length + 2) & 0xFF,
    ...block,
  ];
  final out = BytesBuilder();
  if (segment != null) {
    out
      ..add(Uint8List.sublistView(jpeg, 0, segment.start))
      ..add(app1)
      ..add(Uint8List.sublistView(jpeg, segment.end));
  } else {
    // After SOI and a JFIF APP0 when there is one, as exiftool puts it.
    var at = 2;
    if (segments.isNotEmpty && segments.first.marker == 0xE0) {
      at = segments.first.end;
    }
    out
      ..add(Uint8List.sublistView(jpeg, 0, at))
      ..add(app1)
      ..add(Uint8List.sublistView(jpeg, at));
  }
  return out.toBytes();
}
