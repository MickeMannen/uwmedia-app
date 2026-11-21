// The JPEG writer against Pillow (libjpeg-turbo): the parity fixture made
// by tool/python_reference/jpeg_fixture.py holds computed pictures, the
// tables and subsampling they were saved with, and the files Pillow
// wrote.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/image/jpeg_encoder.dart';
import 'package:uwmedia_app/core/image/jpeg_tables.dart';

import '../../helpers/python_reference.dart';

JpegSampling? _sampling(int pillow) =>
    JpegSampling.values.where((s) => s.pillow == pillow).firstOrNull;

// Pillow hands a table out row by row; the file, and the port, have it in
// zigzag order.
List<int> _zigzagged(List<dynamic> rows) => [
  for (final at in jpegZigzag) rows[at] as int,
];

Map<int, List<int>> _tables(Object? json) => switch (json) {
  final Map<String, dynamic> map => {
    for (final MapEntry(:key, :value) in map.entries)
      int.parse(key): _zigzagged(value as List<dynamic>),
  },
  final List<dynamic> list => {
    for (final (i, table) in list.indexed)
      i: (table as List<dynamic>).cast<int>(),
  },
  _ => {},
};

String _firstDifference(Uint8List got, Uint8List want) {
  for (var i = 0; i < got.length && i < want.length; i++) {
    if (got[i] != want[i]) {
      return 'byte $i of ${got.length}/${want.length}';
    }
  }
  return 'lengths ${got.length}/${want.length}';
}

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File('test/fixtures/python_reference/image/jpeg_cases.json.gz')
            .readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;
  final cases = jsonObjects(reference['cases']);

  test('every file is the one Pillow writes', () {
    expect(cases.length, 30);
    final different = <String>[];
    for (final c in cases) {
      final want = base64.decode(c['jpeg'] as String);
      final given = c['qtables'];
      final got = encodeJpeg(
        base64.decode(c['rgb'] as String),
        c['width'] as int,
        c['height'] as int,
        quantTables: given == null
            ? jpegFinestTables
            : usableQuantTables(_tables(given))!,
        sampling: _sampling(c['subsampling'] as int),
      );
      if (!_same(got, want)) {
        different.add('${c['name']}: ${_firstDifference(got, want)}');
      }
    }
    expect(different, isEmpty, reason: different.join('\n'));
  });

  test('what a file says of its tables and subsampling', () {
    for (final c in [...cases, ...jsonObjects(reference['sources'])]) {
      final read = readJpegTables(base64.decode(c['jpeg'] as String))!;
      expect(
        read.sampling?.pillow ?? -1,
        c['read_sampling'],
        reason: c['name'] as String,
      );
      expect(
        read.quantization,
        _tables(c['read_quantization']),
        reason: c['name'] as String,
      );
    }
    expect(readJpegTables(Uint8List.fromList([1, 2, 3, 4])), isNull);
    expect(readJpegTables(Uint8List(0)), isNull);
    expect(
      readJpegTables(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDB, 0, 80])),
      isNull,
    );
  });

  test('the tables a writer can use', () {
    final t = List.filled(64, 3);
    expect(usableQuantTables({0: t, 1: t})!.length, 2);
    // A gap in the numbers ends the list, as in Pillow.
    expect(usableQuantTables({0: t, 2: t})!.length, 1);
    expect(usableQuantTables({1: t}), isNull);
    expect(usableQuantTables({}), isNull);
  });

  test('what cannot be a JPEG', () {
    final rgb = Uint8List(12);
    expect(
      () => encodeJpeg(rgb, 2, 3, quantTables: jpegFinestTables),
      throwsArgumentError,
    );
    expect(
      () => encodeJpeg(rgb, 2, 2, quantTables: const []),
      throwsArgumentError,
    );
    expect(
      () => encodeJpeg(rgb, 0, 2, quantTables: jpegFinestTables),
      throwsArgumentError,
    );
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
