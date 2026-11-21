import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

import '../../helpers/python_reference.dart';

void main() {
  final cases =
      pythonReference('model/model_cases.json')['round']
          as Map<String, dynamic>;

  test('pyRound matches Python round(x)', () {
    for (final c in jsonObjects(cases['to_int'])) {
      final value = (c['value'] as num).toDouble();
      expect(pyRound(value), c['expected'], reason: 'round($value)');
    }
  });

  test('pyRoundTo matches Python round(x, 2)', () {
    for (final c in jsonObjects(cases['to_2_decimals'])) {
      final value = (c['value'] as num).toDouble();
      expect(
        pyRoundTo(value, 2),
        (c['expected'] as num).toDouble(),
        reason: 'round($value, 2)',
      );
    }
  });

  test('pyRoundTo matches Python round(x, n) for other digit counts', () {
    for (final c in jsonObjects(cases['to_digits'])) {
      final value = (c['value'] as num).toDouble();
      final digits = c['digits'] as int;
      expect(
        pyRoundTo(value, digits),
        (c['expected'] as num).toDouble(),
        reason: 'round($value, $digits)',
      );
    }
  });

  test('pyRoundTo leaves what is not a finite number alone', () {
    expect(pyRoundTo(double.infinity, 2), double.infinity);
    expect(pyRoundTo(double.negativeInfinity, 2), double.negativeInfinity);
    expect(pyRoundTo(double.nan, 2).isNaN, isTrue);
    expect(pyRoundTo(-0.0, 2).isNegative, isTrue);
  });

  test('pyStrip removes what Python str.strip() removes', () {
    expect(' \t\n 1:30 \r\n'.pyStrip(), '1:30');
    // The separators U+001C to U+001F and U+0085 are white space to Python.
    expect('\x1C0:10\x1F'.pyStrip(), '0:10');
    expect('\x85 5 \xA0'.pyStrip(), '5');
    // A byte order mark is not.
    expect('\u{FEFF}7'.pyStrip(), '\u{FEFF}7');
    expect(pyFloat('\x1C 2.5 \x1D'), 2.5);
    expect(pyFloat('\u{FEFF}2.5'), isNull);
    expect(pyInt('99999999999999999999'), isNull);
  });

  test('pyStrptime has no year 0, as Python', () {
    expect(pyStrptime('0000-01-01 00:00:00', '%Y-%m-%d %H:%M:%S'), isNull);
    expect(pyStrptime('0001-01-01 00:00:00', '%Y-%m-%d %H:%M:%S'), isNotNull);
  });
}
