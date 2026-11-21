/// A FIT file as its records: the definition and data messages as they
/// lie in the file, without decoding what the fields mean. The Log
/// Viewer's "Adjust time" and "Merge dives" (`fit_time.dart`,
/// `fit_merge.dart`; Python `parsers/fit_time.py`) rewrite a log at this
/// level, so that fields, developer data and messages no profile knows
/// stay as they were.
library;

import 'dart:typed_data';

/// The number of the timestamp field in every message.
const int fitTimestampField = 253;

/// What a `uint32` field holds when it is not set.
const int fitInvalidUint32 = 0xFFFFFFFF;

/// FIT date_time values below this are seconds since the device was
/// switched on, not dates.
const int fitMinDateTime = 0x10000000;

const List<int> _crcTable = [
  0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, //
  0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
];

/// The FIT checksum of [bytes].
int fitCrc(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    var temp = _crcTable[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ temp ^ _crcTable[byte & 0xF];
    temp = _crcTable[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ temp ^ _crcTable[(byte >> 4) & 0xF];
  }
  return crc;
}

/// One field of a definition: its number, size in bytes and base type.
typedef FitFieldLayout = ({int num, int size, int base});

/// A definition message: which message its data messages are and how
/// their fields lie.
class FitDefinition {
  FitDefinition(this.mesgNum, this.endian, this.fields, this.devSize, this.raw);

  /// A little-endian definition of [fields] without developer fields.
  factory FitDefinition.of(int mesgNum, List<FitFieldLayout> fields) {
    final raw = BytesBuilder()
      ..add([0x40, 0, 0, mesgNum & 0xFF, mesgNum >> 8, fields.length]);
    for (final f in fields) {
      raw.add([f.num, f.size, f.base]);
    }
    return FitDefinition(mesgNum, Endian.little, fields, 0, raw.takeBytes());
  }

  final int mesgNum;
  final Endian endian;
  final List<FitFieldLayout> fields;

  /// The bytes of the developer fields at the end of a data message.
  final int devSize;

  /// The definition message as it is in the file, header byte included.
  final Uint8List raw;

  /// The bytes of a data message's fields.
  late final int size = fields.fold(devSize, (sum, f) => sum + f.size);
}

/// Calls [onMessage] for every data message of every FIT file chained in
/// [data], with its definition, the offset of its fields, the offset of
/// its header byte and whether that header carries a compressed
/// timestamp. Throws a [FormatException] for something that is not a FIT
/// file.
void walkFit(
  Uint8List data,
  void Function(
    FitDefinition definition,
    int start,
    int header,
    bool compressed,
  )
  onMessage,
) {
  final view = ByteData.sublistView(data);
  try {
    var pos = 0;
    while (pos < data.length) {
      if (data.length - pos < 12) {
        throw const FormatException('Not a FIT file (too short)');
      }
      final headerSize = data[pos];
      final dataSize = view.getUint32(pos + 4, Endian.little);
      if ((headerSize != 12 && headerSize != 14) ||
          String.fromCharCodes(data, pos + 8, pos + 12) != '.FIT') {
        throw const FormatException('Not a FIT file');
      }
      final end = pos + headerSize + dataSize;
      if (end + 2 > data.length) {
        throw const FormatException('FIT file is truncated');
      }
      final definitions = <int, FitDefinition>{};
      var p = pos + headerSize;
      while (p < end) {
        final header = data[p];
        if (header & 0x80 != 0 || header & 0x40 == 0) {
          // A data message; one with a compressed timestamp can only
          // name the first four local message types.
          final compressed = header & 0x80 != 0;
          final definition =
              definitions[compressed ? (header >> 5) & 0x03 : header & 0x0F];
          if (definition == null) {
            throw const FormatException(
              'FIT data message without a definition',
            );
          }
          if (p + 1 + definition.size > data.length) {
            throw const FormatException('FIT file is truncated');
          }
          onMessage(definition, p + 1, p, compressed);
          p += 1 + definition.size;
        } else {
          final endian = data[p + 2] == 1 ? Endian.big : Endian.little;
          final mesgNum = view.getUint16(p + 3, endian);
          final count = data[p + 5];
          final fields = <FitFieldLayout>[
            for (var i = 0; i < count; i++)
              (
                num: data[p + 6 + 3 * i],
                size: data[p + 7 + 3 * i],
                base: data[p + 8 + 3 * i],
              ),
          ];
          var q = p + 6 + 3 * count;
          var devSize = 0;
          if (header & 0x20 != 0) {
            final devCount = data[q];
            for (var i = 0; i < devCount; i++) {
              devSize += data[q + 2 + 3 * i];
            }
            q += 1 + 3 * devCount;
          }
          definitions[header & 0x0F] = FitDefinition(
            mesgNum,
            endian,
            fields,
            devSize,
            Uint8List.sublistView(data, p, q),
          );
          p = q;
        }
      }
      pos = end + 2;
    }
  } on RangeError {
    // A definition that runs past the end of the data.
    throw const FormatException('FIT file is truncated');
  }
}
