// A small MP4 as a Sony camera writes its dates: the movie header's in
// UTC and the clock's timezone in the camera's own `uuid` box.
import 'dart:convert';
import 'dart:typed_data';

Uint8List _box(String type, List<int> body) {
  final out = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, 8 + body.length)).buffer.asUint8List())
    ..add(latin1.encode(type))
    ..add(body);
  return out.toBytes();
}

/// A file with only a movie header made at [created] (seconds from 1904)
/// and Sony's box saying [zoneMinutes] east of UTC, after an entry of
/// another kind.
Uint8List sonyMp4({required int created, required int zoneMinutes}) {
  final header = ByteData(100)
    ..setUint32(4, created)
    ..setUint32(8, created)
    ..setUint32(12, 1000);
  final zone = ByteData(2)..setInt16(0, zoneMinutes);
  final table = [
    0, 2, // two entries
    0, 12, 0, 0, 0, 0x0a, 0x55, 0xc4, 0, 0, 0, 1, // some other entry
    0, 12, 0, 0, 0, 0x0b, 0x55, 0xc4, 0, 0, ...zone.buffer.asUint8List(),
  ];
  return Uint8List.fromList([
    ..._box('ftyp', [...latin1.encode('XAVC'), 0, 0, 0, 0]),
    ..._box('moov', [
      ..._box('mvhd', header.buffer.asUint8List()),
      ..._box('uuid', [
        0x55, 0x53, 0x4d, 0x54, 0x21, 0xd2, 0x4f, 0xce, //
        0xbb, 0x88, 0x69, 0x5c, 0xfa, 0xc9, 0xc7, 0x40,
        ..._box('MTDT', table),
      ]),
    ]),
  ]);
}
