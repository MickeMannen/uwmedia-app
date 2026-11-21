// Which camera a photo or video is from, read by the app's own readers
// where exiftool is not there (spec §10.72): EXIF's Make and Model, a
// Sony camera's XML block, a DJI camera's name and category.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/metadata/jpeg_exif.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/mp4_dates.dart';

Uint8List _box(String type, List<int> body) => Uint8List.fromList([
  ...(ByteData(4)..setUint32(0, 8 + body.length)).buffer.asUint8List(),
  ...latin1.encode(type),
  ...body,
]);

List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

// An Xtra entry: its size, the name, one UTF-16 value.
List<int> _xtra(String name, String text) {
  final value = [
    for (final unit in '$text\u0000'.codeUnits) ...[unit & 0xff, unit >> 8],
  ];
  final body = [
    ..._u32(name.length),
    ...latin1.encode(name),
    ..._u32(1),
    ..._u32(6 + value.length),
    0,
    8,
    ...value,
  ];
  return [..._u32(4 + body.length), ...body];
}

Uint8List _movie({List<int> userData = const [], List<int> after = const []}) =>
    Uint8List.fromList([
      ..._box('ftyp', [...latin1.encode('mp42'), 0, 0, 0, 0]),
      ..._box('moov', [
        ..._box('mvhd', Uint8List(100)),
        if (userData.isNotEmpty) ..._box('udta', userData),
      ]),
      ...after,
    ]);

// A TIFF block (little-endian) whose first directory has ASCII [entries].
Uint8List _tiff(Map<int, String> entries) {
  final tags = entries.keys.toList()..sort();
  final table = 8 + 2 + tags.length * 12 + 4;
  final out = BytesBuilder()
    ..add([0x49, 0x49, 42, 0, 8, 0, 0, 0])
    ..add([tags.length, 0]);
  final values = BytesBuilder();
  for (final tag in tags) {
    final text = [...latin1.encode(entries[tag]!), 0];
    final row = ByteData(12)
      ..setUint16(0, tag, Endian.little)
      ..setUint16(2, 2, Endian.little)
      ..setUint32(4, text.length, Endian.little);
    if (text.length <= 4) {
      row.buffer.asUint8List().setRange(8, 8 + text.length, text);
    } else {
      row.setUint32(8, table + values.length, Endian.little);
      values.add(text);
    }
    out.add(row.buffer.asUint8List());
  }
  out
    ..add([0, 0, 0, 0])
    ..add(values.toBytes());
  return out.toBytes();
}

void main() {
  test('a photo: Make and Model of the first directory', () {
    final tags = readTiffDates(
      _tiff({
        0x010F: 'SONY',
        0x0110: 'ILCE-6700 ',
        0x0132: '2026:01:02 03:04:05',
      }),
    );
    expect(tags['EXIF:Make'], 'SONY');
    expect(tags['EXIF:Model'], 'ILCE-6700');
    expect(tags['EXIF:ModifyDate'], '2026:01:02 03:04:05');
    expect(cameraOf(tags), (make: 'SONY', model: 'ILCE-6700'));
    // They are read, never written.
    expect(jpegDateTags.keys, isNot(contains('EXIF:Model')));
    expect(readTiffDates(_tiff({0x0132: '2026:01:02 03:04:05'})).keys, [
      'EXIF:ModifyDate',
    ]);
  });

  test('a Sony video: the XML block after the movie', () {
    const xml =
        '<?xml version="1.0"?><NonRealTimeMeta><Duration value="2880"/>'
        '<Device manufacturer="Sony" modelName="ILCE-6700" '
        'serialNo="4294967295"/></NonRealTimeMeta>';
    final file = _movie(
      after: _box('meta', [
        0, 0, 0, 0, //
        ..._box('xml ', [0, 0, 0, 0, ...utf8.encode(xml)]),
      ]),
    );
    final tags = Mp4Movie.read(MemoryBytes(file)).tags;
    expect(tags['XML:DeviceManufacturer'], 'Sony');
    expect(tags['XML:DeviceModelName'], 'ILCE-6700');
    expect(tags.keys.where((k) => k.contains('erial')), isEmpty);
    expect(cameraOf(tags), (make: 'Sony', model: 'ILCE-6700'));
  });

  test('a DJI video: its name as the encoder, its category', () {
    final file = _movie(
      userData: [
        ..._box('meta', [
          0, 0, 0, 0, //
          ..._box('ilst', [
            ..._box('©too', [
              ..._box('data', [
                0, 0, 0, 1, 0, 0, 0, 0, //
                ...utf8.encode('DJI OsmoAction5 Pro'),
              ]),
            ]),
          ]),
        ]),
        ..._box(
          'Xtra',
          _xtra('WM/Category', 'pb_file:x.proto;model_name:AC004;'),
        ),
      ],
    );
    final tags = Mp4Movie.read(MemoryBytes(file)).tags;
    expect(tags['QuickTime:Encoder'], 'DJI OsmoAction5 Pro');
    expect(tags['QuickTime:Category'], 'pb_file:x.proto;model_name:AC004;');
    expect(cameraOf(tags), (make: 'DJI', model: 'OsmoAction5 Pro'));
    // The category alone names the model; another program's encoder none.
    expect(cameraOf({'QuickTime:Category': 'a:b;model_name:AC004;'}), (
      make: null,
      model: 'AC004',
    ));
    expect(cameraOf({'QuickTime:Encoder': 'Lavf61.7.100'}), (
      make: null,
      model: null,
    ));
    expect(
      mp4CameraTags,
      containsAll(tags.keys.where((k) => !k.contains('Date'))),
    );
  });

  test('no camera said: nothing, and a damaged box is passed over', () {
    expect(cameraOf(null), (make: null, model: null));
    final plain = Mp4Movie.read(MemoryBytes(_movie())).tags;
    expect(plain.keys.where(mp4CameraTags.contains), isEmpty);
    final cut = _movie(
      userData: [
        ..._box('Xtra', [0, 0, 0, 99, 0, 0]),
      ],
    );
    expect(
      Mp4Movie.read(MemoryBytes(cut)).tags.keys.where(mp4CameraTags.contains),
      isEmpty,
    );
    // exiftool's answer names the same tags.
    expect(
      cameraOf({'QuickTime:Make': 'Apple', 'QuickTime:Model': 'iPhone 17'}),
      (make: 'Apple', model: 'iPhone 17'),
    );
  });
}
