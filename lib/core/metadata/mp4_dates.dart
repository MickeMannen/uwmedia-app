/// The dates of an MP4 or MOV file read and written in pure Dart (spec §3,
/// "Suggested portable piece"), for the platforms without exiftool and to
/// spare a process where only the dates are wanted.
///
/// Read: the creation and modification dates of the movie header (`mvhd`),
/// the track headers (`tkhd`) and the media headers (`mdhd`), and the
/// QuickTime keys `com.apple.quicktime.creationdate`, `make`, `model` and
/// `software` of the movie's `meta` box, and the timezone a Sony camera
/// keeps in a `uuid` box of its own (`QuickTime:TimeZone`), under the
/// names and in the text exiftool gives them (`QuickTime:CreateDate` …),
/// so that `media_dates.dart` reads them like exiftool's own answer.
///
/// Write: the same tags. The header dates have a fixed size and are
/// changed where they are; a key that is new, or longer or shorter than
/// before, changes the size of the `moov` box, and what that needs depends
/// on where the box is (see [Mp4Rewrite]).
///
/// Not read: Sony's XML box (`XML:*` tags), the `©day`-style user data,
/// XMP, and anything in a fragmented file's `moof` boxes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// Bytes read by position, so that a film is never loaded whole. A file on
/// disk gets its implementation where `dart:io` is allowed.
abstract interface class ByteSource {
  /// The number of bytes.
  int get length;

  /// [count] bytes from [offset].
  Uint8List read(int offset, int count);
}

/// A [ByteSource] over bytes in memory.
class MemoryBytes implements ByteSource {
  MemoryBytes(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) =>
      Uint8List.sublistView(bytes, offset, offset + count);
}

/// A file that is not an MP4 the port can read or change.
class Mp4Exception implements Exception {
  const Mp4Exception(this.message);

  final String message;

  @override
  String toString() => 'Mp4Exception: $message';
}

/// One box of the file: its type, where it starts, the size of its header
/// (8 bytes, or 16 with a 64-bit size) and its whole size.
typedef Mp4Box = ({String type, int offset, int header, int size});

/// The date text of a header date that was never set.
const zeroDate = '0000:00:00 00:00:00';

// Seconds from 1904-01-01, the format's epoch, to 1970-01-01.
const _epochGap = 2082844800;

// The last second of the year 9999, in seconds from 1970.
const _lastSecond = 253402300799;

const _creationDateKey = 'com.apple.quicktime.creationdate';
const _keyTags = {
  _creationDateKey: 'CreationDate',
  'com.apple.quicktime.make': 'Make',
  'com.apple.quicktime.model': 'Model',
  'com.apple.quicktime.software': 'Software',
};
const _headerTags = {
  'CreateDate': ('mvhd', 0),
  'ModifyDate': ('mvhd', 1),
  'TrackCreateDate': ('tkhd', 0),
  'TrackModifyDate': ('tkhd', 1),
  'MediaCreateDate': ('mdhd', 0),
  'MediaModifyDate': ('mdhd', 1),
};

// The `uuid` box a Sony camera keeps its own metadata in ("USMT" and
// twelve more bytes).
const _sonyUsmt = [
  0x55, 0x53, 0x4d, 0x54, 0x21, 0xd2, 0x4f, 0xce, //
  0xbb, 0x88, 0x69, 0x5c, 0xfa, 0xc9, 0xc7, 0x40,
];

String _type(Uint8List data, int at) =>
    latin1.decode(Uint8List.sublistView(data, at, at + 4));

ByteData _view(Uint8List data) => ByteData.sublistView(data, 0, data.length);

/// The boxes in [data] from [start] to [end].
List<Mp4Box> _boxes(Uint8List data, int start, int end) {
  final view = _view(data);
  final out = <Mp4Box>[];
  var at = start;
  while (at + 8 <= end) {
    var size = view.getUint32(at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > end) {
        throw const Mp4Exception('A box is cut off');
      }
      size = view.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = end - at;
    }
    // A 64-bit size past what a Dart int holds reads as negative.
    if (size < header || size > end - at) {
      throw const Mp4Exception('A box does not fit in its parent');
    }
    out.add((
      type: _type(data, at + 4),
      offset: at,
      header: header,
      size: size,
    ));
    at += size;
  }
  return out;
}

Mp4Box? _child(Uint8List data, Mp4Box parent, String type, {int skip = 0}) {
  for (final box in _boxes(
    data,
    parent.offset + parent.header + skip,
    parent.offset + parent.size,
  )) {
    if (box.type == type) {
      return box;
    }
  }
  return null;
}

/// What exiftool prints for a header date: seconds from 1904, or from 1970
/// when the number is too small to be from 1904 (some software writes
/// that); zero is "never set".
String _headerDateText(int seconds) {
  final unix = seconds >= _epochGap ? seconds - _epochGap : seconds;
  // Zero, and a 64-bit value that is no date of this calendar.
  if (unix <= 0 || unix > _lastSecond) {
    return zeroDate;
  }
  return pyStrftime(
    DateTime.fromMillisecondsSinceEpoch(unix * 1000, isUtc: true),
    tagDateFormat,
  );
}

int _headerDateValue(String text) {
  if (text == zeroDate) {
    return 0;
  }
  final time = pyStrptime(text, tagDateFormat);
  if (time == null) {
    throw FormatException('Not a date like 2026:05:20 22:58:22', text);
  }
  final unix = time.millisecondsSinceEpoch ~/ 1000;
  if (unix <= 0) {
    throw FormatException('A date before 1970 cannot be written', text);
  }
  return unix + _epochGap;
}

final _storedDate = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2}:\d{2}(?:\.\d+)?)(?:(Z)|([+-]\d{2}):?(\d{2}))?$',
);
final _tagDate = RegExp(
  r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}:\d{2}:\d{2}(?:\.\d+)?)(?:(Z)|([+-]\d{2}):?(\d{2}))?$',
);

String _zone(RegExpMatch m, String between) =>
    m[5] ?? (m[6] == null ? '' : '${m[6]}$between${m[7]}');

/// `2025-10-19T10:21:31+0800`, as the key holds it, in exiftool's form
/// `2025:10:19 10:21:31+08:00`. Other text is given as it is.
String _creationDateText(String stored) {
  final m = _storedDate.firstMatch(stored);
  return m == null ? stored : '${m[1]}:${m[2]}:${m[3]} ${m[4]}${_zone(m, ':')}';
}

String _creationDateStored(String text) {
  final m = _tagDate.firstMatch(text);
  if (m == null) {
    throw FormatException('Not a date like 2026:05:21 06:58:22+08:00', text);
  }
  if (pyStrptime(text.substring(0, 19), tagDateFormat) == null) {
    throw FormatException('No such date or time', text);
  }
  return '${m[1]}-${m[2]}-${m[3]}T${m[4]}${_zone(m, '')}';
}

Uint8List _box(String type, List<Uint8List> parts) {
  final size = parts.fold(8, (sum, part) => sum + part.length);
  final out = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, size)).buffer.asUint8List())
    ..add(latin1.encode(type));
  parts.forEach(out.add);
  return out.toBytes();
}

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

/// A part of the file a rewrite makes: bytes kept from the source, or new
/// bytes.
sealed class Mp4Segment {
  int get length;
}

/// [length] bytes of the source from [offset].
class Mp4Copy implements Mp4Segment {
  const Mp4Copy(this.offset, this.length);

  final int offset;

  @override
  final int length;
}

/// New bytes.
class Mp4Data implements Mp4Segment {
  const Mp4Data(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;
}

/// A changed file as a run of segments, and how it can be put on disk.
class Mp4Rewrite {
  const Mp4Rewrite(this.segments, this.ignored);

  /// The whole new file, in order.
  final List<Mp4Segment> segments;

  /// The tags that were asked for and are not written: the ones that are
  /// not QuickTime's (`EXIF:…` on a video) and `Timezone`/`TimeZone`, which
  /// exiftool does not write either (spec §10.23).
  final List<String> ignored;

  /// The size of the new file.
  int get length => segments.fold(0, (sum, s) => sum + s.length);

  /// Whether every kept part stays where it is, so that the file can be
  /// changed where it lies: write [patches] and set the file's length to
  /// [length]. Otherwise the picture data moves and the file has to be
  /// written anew from [segments].
  bool get keepsOffsets {
    var at = 0;
    for (final segment in segments) {
      if (segment is Mp4Copy && segment.offset != at) {
        return false;
      }
      at += segment.length;
    }
    return true;
  }

  /// The new bytes and where each run goes.
  List<(int offset, Uint8List bytes)> get patches {
    final out = <(int, Uint8List)>[];
    var at = 0;
    for (final segment in segments) {
      if (segment is Mp4Data) {
        out.add((at, segment.bytes));
      }
      at += segment.length;
    }
    return out;
  }

  /// The new file in memory. For small files and tests; a film is written
  /// segment by segment.
  Uint8List apply(ByteSource source) {
    final out = BytesBuilder(copy: false);
    for (final segment in segments) {
      switch (segment) {
        case Mp4Copy(:final offset, :final length):
          out.add(source.read(offset, length));
        case Mp4Data(:final bytes):
          out.add(bytes);
      }
    }
    return out.toBytes();
  }
}

/// The parts of an MP4 or MOV file that carry its dates.
// The largest `meta` box of a file's own that is read for a camera's XML
// (a Sony's is some ten kilobytes).
const _largestXmlMeta = 4 << 20;

/// The tags [Mp4Movie.tags] reads to say which camera a video is from,
/// and never writes.
const mp4CameraTags = {
  'XML:DeviceManufacturer',
  'XML:DeviceModelName',
  'QuickTime:Encoder',
  'QuickTime:Category',
};

class Mp4Movie {
  Mp4Movie._(this.source, this.boxes, this._moovBox, this._moov);

  /// Reads the top-level boxes of [source] and its `moov` box. Throws an
  /// [Mp4Exception] when it is not such a file.
  factory Mp4Movie.read(ByteSource source) {
    final boxes = <Mp4Box>[];
    var at = 0;
    while (at + 8 <= source.length) {
      final head = source.read(at, at + 16 <= source.length ? 16 : 8);
      final view = _view(head);
      var size = view.getUint32(0);
      var header = 8;
      if (size == 1 && head.length == 16) {
        size = view.getUint64(8);
        header = 16;
      } else if (size == 0) {
        size = source.length - at;
      }
      if (size < header || size > source.length - at) {
        if (boxes.any((box) => box.type == 'moov')) {
          // Damage or other data after the part with the dates (a cut-off
          // mdat, a camera's trailer): it is copied as it is.
          break;
        }
        throw const Mp4Exception('Not an MP4 file, or one that is cut off');
      }
      boxes.add((type: _type(head, 4), offset: at, header: header, size: size));
      at += size;
    }
    final moov = boxes.where((box) => box.type == 'moov').firstOrNull;
    if (moov == null) {
      throw const Mp4Exception('No moov box: not an MP4 or MOV file');
    }
    return Mp4Movie._(source, boxes, moov, source.read(moov.offset, moov.size));
  }

  final ByteSource source;

  /// The boxes of the file, in order.
  final List<Mp4Box> boxes;

  final Mp4Box _moovBox;

  // The moov box, header included; the offsets of the boxes in it count
  // from its start.
  final Uint8List _moov;

  Mp4Box get _root =>
      (type: 'moov', offset: 0, header: _moovBox.header, size: _moov.length);

  List<Mp4Box> _in(Mp4Box parent, {int skip = 0}) => _boxes(
    _moov,
    parent.offset + parent.header + skip,
    parent.offset + parent.size,
  );

  List<Mp4Box> get _tracks => [
    for (final box in _in(_root))
      if (box.type == 'trak') box,
  ];

  // The header boxes a date tag lives in: all tracks' for a track tag.
  List<Mp4Box> _headers(String type) {
    Mp4Box? of(Mp4Box track) => type == 'tkhd'
        ? _child(_moov, track, 'tkhd')
        : switch (_child(_moov, track, 'mdia')) {
            final Mp4Box mdia => _child(_moov, mdia, 'mdhd'),
            null => null,
          };
    return type == 'mvhd'
        ? [?_child(_moov, _root, 'mvhd')]
        : [for (final track in _tracks) ?of(track)];
  }

  // Where the two dates of a header box are, and how wide.
  (int at, int width) _dateField(Mp4Box header, int which) {
    final start = header.offset + header.header;
    if (start + 4 > header.offset + header.size) {
      throw const Mp4Exception('A header box is cut off');
    }
    final wide = _moov[start] == 1;
    final width = wide ? 8 : 4;
    if (start + 4 + 2 * width > header.offset + header.size) {
      throw const Mp4Exception('A header box is cut off');
    }
    return (start + 4 + which * width, width);
  }

  int _dateAt(Mp4Box header, int which) {
    final (at, width) = _dateField(header, which);
    final view = _view(_moov);
    return width == 8 ? view.getUint64(at) : view.getUint32(at);
  }

  // The movie's own meta box when its handler is QuickTime's key list, and
  // the bytes its header takes before its boxes (a QuickTime meta box has
  // none, an ISO one four).
  (Mp4Box, int skip, Mp4Box? parent)? get _keysMeta {
    // exiftool writes it into moov, ffmpeg into moov's udta box.
    final udta = _child(_moov, _root, 'udta');
    for (final parent in [null, ?udta]) {
      for (final box in _in(parent ?? _root)) {
        if (box.type != 'meta') {
          continue;
        }
        final start = box.offset + box.header;
        final skip =
            start + 8 <= box.offset + box.size &&
                _type(_moov, start + 4) == 'hdlr'
            ? 0
            : 4;
        final handler = _child(_moov, box, 'hdlr', skip: skip);
        if (handler != null &&
            handler.size >= handler.header + 12 &&
            _type(_moov, handler.offset + handler.header + 8) == 'mdta') {
          return (box, skip, parent);
        }
      }
    }
    return null;
  }

  List<String> _keyNames(Mp4Box keys) {
    final view = _view(_moov);
    final end = keys.offset + keys.size;
    var at = keys.offset + keys.header + 8;
    final names = <String>[];
    while (at + 8 <= end) {
      final size = view.getUint32(at);
      if (size < 8 || at + size > end) {
        break;
      }
      names.add(
        utf8.decode(
          Uint8List.sublistView(_moov, at + 8, at + size),
          allowMalformed: true,
        ),
      );
      at += size;
    }
    return names;
  }

  /// The text values of the movie's QuickTime keys, by key name
  /// (`com.apple.quicktime.creationdate` …), as they are stored.
  Map<String, String> get keys {
    try {
      return _readKeys();
    } on Mp4Exception {
      // A damaged user data box: no keys to read (and none are written).
      return const {};
    }
  }

  Map<String, String> _readKeys() {
    final found = _keysMeta;
    if (found == null) {
      return const {};
    }
    final (meta, skip, _) = found;
    final keyBox = _child(_moov, meta, 'keys', skip: skip);
    final list = _child(_moov, meta, 'ilst', skip: skip);
    if (keyBox == null || list == null) {
      return const {};
    }
    final names = _keyNames(keyBox);
    final view = _view(_moov);
    final out = <String, String>{};
    for (final item in _in(list)) {
      final index = view.getUint32(item.offset + 4);
      final data = _child(_moov, item, 'data');
      if (index < 1 || index > names.length || data == null) {
        continue;
      }
      final start = data.offset + data.header;
      // Type 1 is UTF-8 text; the four bytes after it are a locale.
      if (data.size < data.header + 8 || view.getUint32(start) != 1) {
        continue;
      }
      out.putIfAbsent(
        names[index - 1],
        () => utf8.decode(
          Uint8List.sublistView(_moov, start + 8, data.offset + data.size),
          allowMalformed: true,
        ),
      );
    }
    return out;
  }

  // The timezone of a Sony camera's clock in minutes east of UTC: entry
  // 0x000b of the `MTDT` table in the camera's `uuid` box ([_sonyUsmt]),
  // which lies in moov or its udta box. Each entry is its size (2 bytes),
  // its type (4), a language and an encoding (2 each), then the value.
  int? get _sonyTimeZone {
    final view = _view(_moov);
    try {
      final udta = _child(_moov, _root, 'udta');
      for (final parent in [_root, ?udta]) {
        for (final box in _in(parent)) {
          final start = box.offset + box.header;
          final end = box.offset + box.size;
          if (box.type != 'uuid' || start + 16 > end) {
            continue;
          }
          var same = true;
          for (var i = 0; i < 16 && same; i++) {
            same = _moov[start + i] == _sonyUsmt[i];
          }
          if (!same) {
            continue;
          }
          for (final table in _boxes(_moov, start + 16, end)) {
            if (table.type != 'MTDT') {
              continue;
            }
            final last = table.offset + table.size;
            var at = table.offset + table.header;
            if (at + 2 > last) {
              continue;
            }
            final count = view.getUint16(at);
            at += 2;
            for (var i = 0; i < count && at + 10 <= last; i++) {
              final size = view.getUint16(at);
              if (size < 10 || at + size > last) {
                break;
              }
              if (view.getUint32(at + 2) == 0x0b && size >= 12) {
                return view.getInt16(at + 10);
              }
              at += size;
            }
          }
        }
      }
    } on Mp4Exception {
      // A damaged box: no timezone to read.
    }
    return null;
  }

  /// The date tags, and make, model and software, as exiftool names and
  /// writes them. With several tracks the track dates are the first
  /// track's and the media dates the last one's, which is what exiftool
  /// answers.
  MediaTags get tags {
    final out = <String, Object?>{};
    _headerTags.forEach((tag, where) {
      final (type, which) = where;
      final headers = _headers(type);
      if (headers.isNotEmpty) {
        final header = type == 'mdhd' ? headers.last : headers.first;
        out['QuickTime:$tag'] = _headerDateText(_dateAt(header, which));
      }
    });
    final stored = keys;
    _keyTags.forEach((key, tag) {
      final value = stored[key];
      if (value != null) {
        out['QuickTime:$tag'] = key == _creationDateKey
            ? _creationDateText(value)
            : value;
      }
    });
    final zone = _sonyTimeZone;
    if (zone != null) {
      out['QuickTime:TimeZone'] = tzIso(zone);
    }
    out.addAll(_cameraTags);
    return out;
  }

  // What says which camera it was, where the QuickTime keys do not (spec
  // §10.72), under exiftool's names: a Sony camera's XML block (a `meta`
  // box of the file's own), the `©too` item of the user data (a DJI's
  // name) and the `WM/Category` of its `Xtra` box. Read only.
  Map<String, String> get _cameraTags {
    final out = <String, String>{};
    try {
      for (final box in boxes) {
        if (box.type != 'meta' || box.size > _largestXmlMeta) {
          continue;
        }
        final text = latin1.decode(source.read(box.offset, box.size));
        final device = RegExp(r'<Device\b[^>]*>').firstMatch(text)?[0];
        if (device == null) {
          continue;
        }
        String? said(String name) =>
            RegExp('\\b$name="([^"]*)"').firstMatch(device)?[1];
        if (said('manufacturer') case final String make when make.isNotEmpty) {
          out['XML:DeviceManufacturer'] = make;
        }
        if (said('modelName') case final String model when model.isNotEmpty) {
          out['XML:DeviceModelName'] = model;
        }
      }
      final udta = _child(_moov, _root, 'udta');
      if (udta == null) {
        return out;
      }
      final view = _view(_moov);
      // udta / meta (a full box) / ilst / ©too / data: the text after the
      // data box's type and locale.
      final meta = _child(_moov, udta, 'meta');
      final list = meta == null ? null : _child(_moov, meta, 'ilst', skip: 4);
      final tool = list == null ? null : _child(_moov, list, '\u00a9too');
      final data = tool == null ? null : _child(_moov, tool, 'data');
      if (data != null && data.size > data.header + 8) {
        final text = utf8
            .decode(
              Uint8List.sublistView(
                _moov,
                data.offset + data.header + 8,
                data.offset + data.size,
              ),
              allowMalformed: true,
            )
            .trim();
        if (text.isNotEmpty) {
          out['QuickTime:Encoder'] = text;
        }
      }
      // Xtra: entries of their size, the name's length and the name, a
      // count of values, and each value's size, type (8: UTF-16) and
      // bytes.
      final xtra = _child(_moov, udta, 'Xtra');
      if (xtra != null) {
        final end = xtra.offset + xtra.size;
        var at = xtra.offset + xtra.header;
        while (at + 8 <= end) {
          final size = view.getUint32(at);
          final nameLength = view.getUint32(at + 4);
          if (size < 12 || at + size > end || at + 8 + nameLength + 4 > end) {
            break;
          }
          final name = latin1.decode(
            Uint8List.sublistView(_moov, at + 8, at + 8 + nameLength),
          );
          final value = at + 8 + nameLength + 4;
          if (name == 'WM/Category' && value + 6 <= at + size) {
            final valueSize = view.getUint32(value);
            if (view.getUint16(value + 4) == 8 &&
                valueSize >= 6 &&
                value + valueSize <= at + size) {
              final units = <int>[
                for (var i = value + 6; i + 1 < value + valueSize; i += 2)
                  view.getUint16(i, Endian.little),
              ];
              final text = String.fromCharCodes(
                units.takeWhile((unit) => unit != 0),
              );
              if (text.isNotEmpty) {
                out['QuickTime:Category'] = text;
              }
            }
          }
          at += size;
        }
      }
    } on Object {
      // A damaged box: what was read so far.
    }
    return out;
  }

  /// Where each track's chunks of picture and sound data start in the
  /// file, track by track.
  List<List<int>> get chunkOffsets => [
    for (final table in _chunkTables(_moov, _root)) _tableEntries(_moov, table),
  ];

  static List<Mp4Box> _chunkTables(Uint8List moov, Mp4Box root) {
    final out = <Mp4Box>[];
    for (final track in _boxes(moov, root.header, moov.length)) {
      if (track.type != 'trak') {
        continue;
      }
      Mp4Box? box = track;
      for (final type in ['mdia', 'minf', 'stbl']) {
        box = box == null ? null : _child(moov, box, type);
      }
      if (box == null) {
        continue;
      }
      for (final table in _boxes(
        moov,
        box.offset + box.header,
        box.offset + box.size,
      )) {
        if (table.type == 'saio') {
          // Offsets the port does not follow (encrypted media).
          throw const Mp4Exception('Encrypted media is not supported');
        }
        if (table.type == 'stco' || table.type == 'co64') {
          final payload = table.size - table.header;
          final width = table.type == 'co64' ? 8 : 4;
          if (payload < 8 ||
              _view(moov).getUint32(table.offset + table.header + 4) >
                  (payload - 8) ~/ width) {
            throw const Mp4Exception(
              'A chunk offset table is shorter than it says',
            );
          }
          out.add(table);
        }
      }
    }
    return out;
  }

  static List<int> _tableEntries(Uint8List moov, Mp4Box table) {
    final view = _view(moov);
    final start = table.offset + table.header;
    final count = view.getUint32(start + 4);
    final wide = table.type == 'co64';
    return [
      for (var i = 0; i < count; i++)
        wide
            ? view.getUint64(start + 8 + 8 * i)
            : view.getUint32(start + 8 + 4 * i),
    ];
  }

  /// The file with [tags] written: the six header dates
  /// (`QuickTime:CreateDate` … as `2026:05:20 22:58:22`, in UTC, or
  /// [zeroDate]) and `QuickTime:CreationDate` (local time with its offset,
  /// `2026:05:21 06:58:22+08:00`), `Make`, `Model` and `Software` as
  /// QuickTime keys. A track or media date goes to every track. Names may
  /// come with the group `QuickTime:` or `Keys:` or without one.
  ///
  /// Throws a [FormatException] for a date that cannot be read or stored,
  /// and an [Mp4Exception] when the change would move the picture data of
  /// a file whose offsets the port cannot follow (a fragmented or
  /// encrypted one).
  Mp4Rewrite write(Map<String, String> tags) {
    final moov = Uint8List.fromList(_moov);
    final view = _view(moov);
    final ignored = <String>[];
    final newKeys = <String, String>{};
    tags.forEach((name, value) {
      final colon = name.indexOf(':');
      final group = colon == -1 ? '' : name.substring(0, colon);
      final tag = name.substring(colon + 1);
      final where = _headerTags[tag];
      final key = _keyTags.entries.where((e) => e.value == tag).firstOrNull;
      if (where != null && (group.isEmpty || group == 'QuickTime')) {
        final (type, which) = where;
        final seconds = _headerDateValue(value);
        for (final header in _headers(type)) {
          final (at, width) = _dateField(header, which);
          if (width == 8) {
            view.setUint64(at, seconds);
          } else if (seconds > 0xFFFFFFFF) {
            throw FormatException('A date after 2040 does not fit', value);
          } else {
            view.setUint32(at, seconds);
          }
        }
      } else if (key != null &&
          (group.isEmpty || group == 'QuickTime' || group == 'Keys')) {
        newKeys[key.key] = key.key == _creationDateKey
            ? _creationDateStored(value)
            : value;
      } else {
        ignored.add(name);
      }
    });

    final stored = keys;
    newKeys.removeWhere((key, value) => stored[key] == value);
    if (newKeys.isEmpty) {
      return Mp4Rewrite(_around(moov), ignored);
    }
    return Mp4Rewrite(_resized(_withKeys(moov, newKeys)), ignored);
  }

  List<Mp4Segment> _around(Uint8List moov, [int? resumeAt]) {
    final end = resumeAt ?? _moovBox.offset + _moovBox.size;
    return [
      if (_moovBox.offset > 0) Mp4Copy(0, _moovBox.offset),
      Mp4Data(moov),
      if (end < source.length) Mp4Copy(end, source.length - end),
    ];
  }

  // The moov box with the keys set: its meta box made anew, or added.
  Uint8List _withKeys(Uint8List moov, Map<String, String> newKeys) {
    final found = _keysMeta;
    final names = <String>[];
    final keyEntries = <Uint8List>[]; // the keys as stored, namespace and all
    final items = <(int, Uint8List)>[]; // the ilst items, with key number
    final others = <Uint8List>[]; // the meta box's other boxes
    var prefix = Uint8List(0);
    Uint8List? handler;
    if (found != null) {
      final (meta, skip, _) = found;
      prefix = Uint8List.sublistView(
        moov,
        meta.offset + meta.header,
        meta.offset + meta.header + skip,
      );
      for (final box in _in(meta, skip: skip)) {
        final bytes = Uint8List.sublistView(
          moov,
          box.offset,
          box.offset + box.size,
        );
        if (box.type == 'hdlr') {
          handler = bytes;
        } else if (box.type == 'keys') {
          final end = box.offset + box.size;
          var at = box.offset + box.header + 8;
          while (at < end) {
            final size = at + 8 <= end ? _view(moov).getUint32(at) : 0;
            if (size < 8 || size > end - at) {
              throw const Mp4Exception('The key list of the movie is damaged');
            }
            keyEntries.add(Uint8List.sublistView(moov, at, at + size));
            at += size;
          }
          names.addAll(_keyNames(box));
        } else if (box.type == 'ilst') {
          for (final item in _in(box)) {
            items.add((
              _view(moov).getUint32(item.offset + 4),
              Uint8List.sublistView(moov, item.offset, item.offset + item.size),
            ));
          }
        } else {
          others.add(bytes);
        }
      }
    } else if (_in(_root).any((box) => box.type == 'meta')) {
      throw const Mp4Exception(
        'The movie has a meta box that is not a QuickTime key list',
      );
    }
    newKeys.forEach((key, value) {
      var number = names.indexOf(key) + 1;
      if (number == 0) {
        names.add(key);
        keyEntries.add(_box('mdta', [Uint8List.fromList(utf8.encode(key))]));
        number = names.length;
      }
      final text = Uint8List.fromList(utf8.encode(value));
      // "data": type 1 (UTF-8), no locale, the text.
      final data = _box('data', [_u32(1), _u32(0), text]);
      final item = Uint8List.fromList([
        ..._u32(8 + data.length),
        ..._u32(number),
        ...data,
      ]);
      // In the place of the key's first item; a key has one value.
      final at = items.indexWhere((e) => e.$1 == number);
      items.removeWhere((e) => e.$1 == number);
      items.insert(at == -1 ? items.length : at, (number, item));
    });
    final keyBox = _box('keys', [
      _u32(0),
      _u32(keyEntries.length),
      ...keyEntries,
    ]);
    final list = _box('ilst', [for (final (_, bytes) in items) bytes]);
    final meta = _box('meta', [
      prefix,
      // A handler as exiftool writes it: "mdta" and nothing else.
      handler ??
          _box('hdlr', [
            _u32(0),
            _u32(0),
            Uint8List.fromList(latin1.encode('mdta')),
            Uint8List(12),
          ]),
      keyBox,
      list,
      ...others,
    ]);

    final out = BytesBuilder();
    if (found == null) {
      out
        ..add(moov)
        ..add(meta);
    } else {
      final old = found.$1;
      out
        ..add(Uint8List.sublistView(moov, 0, old.offset))
        ..add(meta)
        ..add(Uint8List.sublistView(moov, old.offset + old.size));
    }
    final bytes = out.toBytes();
    final parent = found?.$3;
    if (parent != null) {
      // The udta box around it, which starts before it, changes size too.
      if (parent.header != 8) {
        throw const Mp4Exception('A udta box with a 64-bit size');
      }
      _view(bytes)
          .setUint32(parent.offset, parent.size + meta.length - found!.$1.size);
    }
    if (_moovBox.header == 16) {
      _view(bytes).setUint64(8, bytes.length);
    } else if (_view(bytes).getUint32(0) != 0) {
      _view(bytes).setUint32(0, bytes.length);
    }
    return bytes;
  }

  // A moov box of another size in the file: at the end it just ends
  // elsewhere; before the picture data, a free box after it takes the
  // difference when there is one that can, and otherwise the data moves
  // and every track's chunk offsets with it.
  List<Mp4Segment> _resized(Uint8List moov) {
    final end = _moovBox.offset + _moovBox.size;
    final delta = moov.length - _moov.length;
    if (delta == 0 || end == source.length) {
      return _around(moov);
    }
    final next = boxes.where((box) => box.offset == end).firstOrNull;
    if (next != null && next.header == 8) {
      final left = next.size - delta;
      if ((next.type == 'free' || next.type == 'skip') &&
          (left == 0 || left >= 8)) {
        return _around(
          Uint8List.fromList([
            ...moov,
            if (left >= 8) ..._box(next.type, [Uint8List(left - 8)]),
          ]),
          end + next.size,
        );
      }
    }
    if (delta <= -8) {
      return _around(
        Uint8List.fromList([
          ...moov,
          ..._box('free', [Uint8List(-delta - 8)]),
        ]),
      );
    }

    if (boxes.any((box) => box.type == 'moof')) {
      throw const Mp4Exception(
        'A fragmented file cannot take a key of another length',
      );
    }
    final view = _view(moov);
    final root = (
      type: 'moov',
      offset: 0,
      header: _moovBox.header,
      size: moov.length,
    );
    for (final table in _chunkTables(moov, root)) {
      final start = table.offset + table.header;
      final count = view.getUint32(start + 4);
      for (var i = 0; i < count; i++) {
        if (table.type == 'co64') {
          final at = start + 8 + 8 * i;
          final offset = view.getUint64(at);
          if (offset >= end) {
            view.setUint64(at, offset + delta);
          }
        } else {
          final at = start + 8 + 4 * i;
          final offset = view.getUint32(at);
          if (offset >= end) {
            if (offset + delta > 0xFFFFFFFF) {
              throw const Mp4Exception('The file is too large to shift');
            }
            view.setUint32(at, offset + delta);
          }
        }
      }
    }
    return _around(moov);
  }
}

/// The date tags of the MP4 or MOV file in [source], as [Mp4Movie.tags].
MediaTags readMp4Tags(ByteSource source) => Mp4Movie.read(source).tags;

/// Whether [time], a naive UTC time, can be a header date (1970 to 2040 in
/// the usual 32-bit header).
bool fitsMp4Header(DateTime time) {
  assert(time.isUtc, naiveTimeMessage);
  final unix = time.millisecondsSinceEpoch ~/ 1000;
  return unix > 0 && unix + _epochGap <= 0xFFFFFFFF;
}
