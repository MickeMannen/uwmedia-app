/// Python's `round()`, which the reference implementation uses wherever it
/// rounds a stored value. It differs from Dart's `round()` and
/// `toStringAsFixed` on exact halves: Python rounds those to the even
/// neighbour, Dart away from zero.
library;

import 'dart:typed_data';

/// Python `round(x)`: nearest integer, an exact half to the even one.
int pyRound(double x) {
  final floor = x.floorToDouble();
  if (x - floor == 0.5) {
    return (floor % 2 == 0 ? floor : floor + 1).toInt();
  }
  return x.round();
}

/// Python `round(x, digits)` for a float: the decimal with [digits] places
/// nearest to the double's exact value, an exact half to the even last
/// digit, converted back to the nearest double.
///
/// `2.675` gives `2.67` (the double is just below the half) and `0.125`
/// gives `0.12` (an exact half).
double pyRoundTo(double x, int digits) {
  assert(digits >= 0, 'digits must not be negative, got $digits');
  if (!x.isFinite || x == 0) {
    return x;
  }
  // x = ±mantissa · 2^exponent, exactly.
  final bytes = ByteData(8)..setFloat64(0, x.abs());
  final high = bytes.getUint32(0);
  final low = bytes.getUint32(4);
  final biasedExponent = (high >> 20) & 0x7ff;
  var mantissa = (BigInt.from(high & 0xfffff) << 32) | BigInt.from(low);
  final int exponent;
  if (biasedExponent == 0) {
    exponent = -1074;
  } else {
    mantissa |= BigInt.one << 52;
    exponent = biasedExponent - 1075;
  }
  if (exponent >= 0) {
    // A whole number.
    return x;
  }
  final numerator = mantissa * BigInt.from(10).pow(digits);
  final denominator = BigInt.one << -exponent;
  var scaled = numerator ~/ denominator;
  final twiceRemainder = (numerator % denominator) << 1;
  final comparison = twiceRemainder.compareTo(denominator);
  if (comparison > 0 || (comparison == 0 && scaled.isOdd)) {
    scaled += BigInt.one;
  }
  final rounded = double.parse('${scaled}e-$digits');
  return x < 0 ? -rounded : rounded;
}

/// Python `sum()` of floats (3.12 and later): a compensated (Neumaier) sum,
/// so the result can differ in the last bits from adding left to right.
double pySum(Iterable<double> values) {
  var result = 0.0;
  var compensation = 0.0;
  for (final x in values) {
    final t = result + x;
    if (result.abs() >= x.abs()) {
      compensation += (result - t) + x;
    } else {
      compensation += (x - t) + result;
    }
    result = t;
  }
  if (compensation != 0 && compensation.isFinite) {
    result += compensation;
  }
  return result;
}

/// Python `f"{x:.{decimals}f}"`: fixed decimals, an exact half to the even
/// last digit (Dart's `toStringAsFixed` rounds it away from zero).
String pyFormatFixed(double x, int decimals) {
  if (x.isNaN) {
    return 'nan';
  }
  if (x.isInfinite) {
    return x < 0 ? '-inf' : 'inf';
  }
  if (x.abs() >= 1e21) {
    // A whole number that large; `toStringAsFixed` would write an exponent.
    final digits = BigInt.from(x).toString();
    return decimals == 0 ? digits : '$digits.${'0' * decimals}';
  }
  return pyRoundTo(x, decimals).toStringAsFixed(decimals);
}
