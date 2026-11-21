/// Writing a FIT file, the way the Python FIT SDK's `Encoder` does
/// (`garmin_fit_sdk/encoder.py`, `mesg_definition.py`, `output_stream.py`),
/// so that the Dive Profile Builder's FIT log is the same file from both
/// apps. A message is its fields by profile name, in the order they are
/// to be written; the profile itself is the part of the SDK's that the
/// builder's log uses (`fit_profile_subset.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:uwmedia_app/core/parsers/fit_records.dart';
import 'package:uwmedia_app/core/plan/fit_profile_subset.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

export 'package:uwmedia_app/core/parsers/fit_records.dart' show fitCrc;

/// FIT base type numbers (the low five bits of a definition's type byte).
const int fitEnum = 0x00;
const int fitString = 0x07;
const int fitFloat32 = 0x08;
const int fitFloat64 = 0x09;

const int _headerWithCrcSize = 14;
const int _maxFieldSize = 255;

/// Size in bytes and whether signed, by base type. A whole number is
/// written by its low bits, so the sign needs no rule of its own.
const Map<int, (int, bool)> _baseTypes = {
  0x00: (1, false),
  0x01: (1, true),
  0x02: (1, false),
  0x03: (2, true),
  0x04: (2, false),
  0x05: (4, true),
  0x06: (4, false),
  0x07: (1, false),
  0x08: (4, true),
  0x09: (8, true),
  0x0A: (1, false),
  0x0B: (2, false),
  0x0C: (4, false),
  0x0D: (1, false),
  0x0E: (8, true),
  0x0F: (8, false),
  0x10: (8, false),
};

const Set<String> _numericTypes = {
  'sint8', 'uint8', 'sint16', 'uint16', 'sint32', 'uint32', 'float32', //
  'float64', 'uint8z', 'uint16z', 'uint32z', 'byte', 'sint64', 'uint64',
  'uint64z',
};

class _Field {
  _Field(this.name, this.num, this.size, this.baseType, this.profile);

  final String name;
  final int num;
  final int size;
  final int baseType;
  final FitFieldProfile profile;
}

class _DeveloperField {
  _DeveloperField(this.key, this.num, this.size, this.baseType, this.index);

  final String key;
  final int num;
  final int size;
  final int baseType;
  final int index;
}

class _Definition {
  _Definition(this.mesgNum, this.fields, this.developerFields);

  final int mesgNum;
  final List<_Field> fields;
  final List<_DeveloperField> developerFields;
  int localNum = 0;

  /// The same fields with the same sizes, in any order.
  bool matches(_Definition other) =>
      mesgNum == other.mesgNum &&
      fields.length == other.fields.length &&
      developerFields.length == other.developerFields.length &&
      fields.every(
        (a) => other.fields.any(
          (b) => a.num == b.num && a.size == b.size && a.baseType == b.baseType,
        ),
      ) &&
      developerFields.every(
        (a) => other.developerFields.any(
          (b) => a.num == b.num && a.size == b.size && a.index == b.index,
        ),
      );
}

/// A FIT file being written. Messages go in with [writeMesg]; [close]
/// gives the file.
class FitEncoder {
  FitEncoder() {
    _out.add(Uint8List(_headerWithCrcSize));
  }

  final BytesBuilder _out = BytesBuilder(copy: false);
  final List<_Definition?> _local = List.filled(16, null);
  int _nextLocal = 0;
  final Map<String, ({int index, int num, int baseType})> _descriptions = {};

  /// Makes the developer field [key] known: the developer data index and
  /// field number its description message gives it, and its base type. The
  /// description messages themselves are written by the caller.
  void addDeveloperField(
    String key, {
    required int developerDataIndex,
    required int fieldDefinitionNumber,
    required int fitBaseTypeId,
  }) {
    _descriptions[key] = (
      index: developerDataIndex,
      num: fieldDefinitionNumber,
      baseType: fitBaseTypeId & 0x1F,
    );
  }

  static int _sizeOf(Object value, int baseType) {
    final values = value is List ? value : [value];
    if (baseType == fitString) {
      var total = 0;
      for (final text in values) {
        if (text is! String) {
          throw FormatException('Not text for a FIT string field', text);
        }
        total += utf8.encode(text).length + 1;
      }
      return total;
    }
    return _baseTypes[baseType]!.$1 * values.length;
  }

  _Definition _definitionOf(
    int mesgNum,
    Map<String, Object?> fields,
    Map<String, Object?> developerFields,
  ) {
    final profile = fitMesgFields[mesgNum];
    if (profile == null) {
      throw ArgumentError.value(mesgNum, 'mesgNum', 'not in the profile');
    }
    final definitions = <_Field>[];
    fields.forEach((name, value) {
      if (value == null) {
        return;
      }
      final field = profile[name];
      if (field == null) {
        // The SDK passes over a field its profile does not have; here the
        // profile is only what the builder writes, so this is a mistake.
        throw ArgumentError.value(name, 'fields', 'not in the profile');
      }
      definitions.add(
        _Field(
          name,
          field.num,
          _sizeOf(value, field.baseType),
          field.baseType,
          field,
        ),
      );
    });
    final developer = <_DeveloperField>[];
    for (final key in developerFields.keys.toList()..sort()) {
      final description = _descriptions[key];
      if (description == null) {
        throw ArgumentError.value(key, 'developerFields', 'not described');
      }
      developer.add(
        _DeveloperField(
          key,
          description.num,
          _sizeOf(developerFields[key]!, description.baseType),
          description.baseType,
          description.index,
        ),
      );
    }
    if (definitions.isEmpty) {
      throw const FormatException('No valid fields were found in the message');
    }
    for (final size in [
      for (final f in definitions) f.size,
      for (final f in developer) f.size,
    ]) {
      if (size > _maxFieldSize) {
        throw FormatException(
          'A FIT field cannot be larger than $_maxFieldSize bytes',
          size,
        );
      }
    }
    return _Definition(mesgNum, definitions, developer);
  }

  void _writeDefinition(_Definition definition) {
    final developer = definition.developerFields;
    final bytes = BytesBuilder()
      ..addByte(0x40 | definition.localNum | (developer.isEmpty ? 0 : 0x20))
      ..addByte(0) // reserved
      ..addByte(0) // little endian
      ..addByte(definition.mesgNum & 0xFF)
      ..addByte(definition.mesgNum >> 8)
      ..addByte(definition.fields.length);
    for (final field in definition.fields) {
      bytes
        ..addByte(field.num)
        ..addByte(field.size)
        // Types of more than one byte carry the endian flag.
        ..addByte(
          field.baseType | (_baseTypes[field.baseType]!.$1 > 1 ? 0x80 : 0),
        );
    }
    if (developer.isNotEmpty) {
      bytes.addByte(developer.length);
      for (final field in developer) {
        bytes
          ..addByte(field.num)
          ..addByte(field.size)
          ..addByte(field.index);
      }
    }
    _out.add(bytes.takeBytes());
  }

  /// One value as the number or text the file holds: a named value's
  /// number, a scaled field's whole number.
  static Object _transform(Object value, String type, num scale, num offset) {
    if (value is bool) {
      throw FormatException('A FIT field takes no true or false', value);
    }
    if (_numericTypes.contains(type)) {
      if (value is! num || !value.isFinite) {
        throw FormatException('Not a number for a FIT field', value);
      }
      if (scale != 1 || offset != 0) {
        final scaled = (value + offset) * scale;
        return type == 'float32' || type == 'float64' || scaled is int
            ? scaled
            : pyRound(scaled.toDouble());
      }
      return value;
    }
    if (type == 'string') {
      if (value is! String) {
        throw FormatException('Not text for a FIT string field', value);
      }
      return value;
    }
    if (value is num) {
      if (!value.isFinite) {
        throw FormatException('Not a number for a FIT field', value);
      }
      return value;
    }
    final number = fitTypeValues[type]?[value];
    if (number == null) {
      throw FormatException('No "$value" in the FIT type "$type"');
    }
    return number;
  }

  void _writeValues(Object value, int baseType, Object Function(Object) map) {
    final values = value is List ? value : [value];
    if (baseType == fitString) {
      // Several texts in one field are joined by a zero.
      _out
        ..add(utf8.encode(values.map((v) => map(v as Object)).join('\x00')))
        ..addByte(0);
      return;
    }
    final size = _baseTypes[baseType]!.$1;
    final data = ByteData(size * values.length);
    for (final (i, raw) in values.indexed) {
      final v = map(raw as Object) as num;
      final at = i * size;
      if (baseType == fitFloat32) {
        data.setFloat32(at, v.toDouble(), Endian.little);
      } else if (baseType == fitFloat64) {
        data.setFloat64(at, v.toDouble(), Endian.little);
      } else {
        // A number that does not fit keeps its low bits.
        final whole = v.truncate();
        switch (size) {
          case 1:
            data.setUint8(at, whole & 0xFF);
          case 2:
            data.setUint16(at, whole & 0xFFFF, Endian.little);
          case 4:
            data.setUint32(at, whole & 0xFFFFFFFF, Endian.little);
          default:
            data.setInt64(at, whole, Endian.little);
        }
      }
    }
    _out.add(data.buffer.asUint8List());
  }

  /// Writes the message [mesgNum] with [fields] by profile name (a field
  /// that is `null` is left out) and [developerFields] by the keys given
  /// to [addDeveloperField]. A value is a number, text, the name of a
  /// profile value ("garmin", "activity") or a list of those. Throws a
  /// [FormatException] for a value the field cannot hold.
  void writeMesg(
    int mesgNum,
    Map<String, Object?> fields, {
    Map<String, Object?> developerFields = const {},
  }) {
    var definition = _definitionOf(mesgNum, fields, developerFields);
    final known = _local.nonNulls.where((d) => d.matches(definition));
    if (known.isNotEmpty) {
      definition = known.first;
    } else {
      // The sixteen local numbers are handed out in turn; a new definition
      // takes over the oldest's.
      definition.localNum = _nextLocal & 0x0F;
      _nextLocal++;
      _writeDefinition(definition);
      _local[definition.localNum] = definition;
    }
    _out.addByte(definition.localNum);
    for (final field in definition.fields) {
      final p = field.profile;
      _writeValues(
        fields[field.name]!,
        field.baseType,
        (v) => _transform(v, p.type, p.scale, p.offset),
      );
    }
    for (final field in definition.developerFields) {
      _writeValues(developerFields[field.key]!, field.baseType, (v) => v);
    }
  }

  /// The finished file: the header with the data's length, the messages
  /// and the checksum.
  Uint8List close() {
    final data = _out.takeBytes();
    final header = ByteData.sublistView(data, 0, _headerWithCrcSize)
      ..setUint8(0, _headerWithCrcSize)
      ..setUint8(1, 0x20) // protocol 2.0
      ..setUint16(2, fitProfileVersion, Endian.little)
      ..setUint32(4, data.length - _headerWithCrcSize, Endian.little);
    data.setRange(8, 12, ascii.encode('.FIT'));
    header.setUint16(
      12,
      fitCrc(Uint8List.sublistView(data, 0, 12)),
      Endian.little,
    );
    final crc = fitCrc(data);
    return (BytesBuilder(copy: false)
          ..add(data)
          ..addByte(crc & 0xFF)
          ..addByte(crc >> 8))
        .takeBytes();
  }
}
