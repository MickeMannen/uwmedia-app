// The unit systems against the Python app: the cases of its
// tests/test_units.py, then the sweeps of the parity fixture made by
// tool/python_reference/notices_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

void main() {
  const metric = UnitSystem.metric;
  const imperial = UnitSystem.imperial;

  group('tests/test_units.py', () {
    test('test_conversions_match_the_manuals_pairs', () {
      // 11 m / 35 ft (Perdix 2 p.27)
      expect(pyRound(depth(11.0, imperial)), 36);
      expect(pyRound(depth(10.67, imperial)), 35);
      // 50 bar / 725 psi (p.57), 21 bar / 300 psi
      expect(pyRound(pressure(50.0, imperial)), 725);
      expect(pyRound(pressure(21.0, imperial)), 305);
      expect(pyRound(pressure(20.7, imperial)), 300);
      expect(temperature(27.0, imperial), closeTo(80.6, 1e-9));
      // 10 ft stop levels (p.28)
      expect(stopDepth(6.0, imperial), 20);
      expect(stopDepth(3.0, imperial), 10);
      expect(stopDepth(9.0, imperial), 30);
      // The 5 m safety stop is 15 ft (Mk3 p.10).
      expect(stopDepth(5.0, imperial), 15);
      expect(stopDepth(4.5, imperial), 15);
      expect(depthLabel(imperial), 'ft');
      expect(pressureLabel(imperial), 'PSI');
      expect(pressureLabel(imperial, upper: false), 'psi');
      expect(temperatureLabel(imperial), '°F');
      expect(sacLabel(imperial), 'psi/min');
      expect(volumeRateLabel(imperial), 'cuft/min');
      expect(
        depthToMetres(depth(12.3, imperial), imperial),
        closeTo(12.3, 1e-9),
      );
      expect(
        pressureToBar(pressure(207, imperial), imperial),
        closeTo(207, 1e-9),
      );
      expect(
        temperatureToCelsius(temperature(27, imperial), imperial),
        closeTo(27, 1e-9),
      );
      expect(depth(11.0, metric), 11.0);
      expect(stopDepth(6.0, metric), 6);
      expect(depthLabel(metric), 'm');
      expect(pressureLabel(metric), 'BAR');
    });

    test('test_formatting_follows_the_brands_decimals', () {
      const rule = <String, dynamic>{
        'depth_decimals': <String, dynamic>{'metric': 1, 'imperial': 0},
      };
      expect(formatDepth(45.3, metric, displayRule: rule), '45.3');
      // Perdix 2 p.12: whole feet
      expect(formatDepth(13.72, imperial, displayRule: rule), '45');
      // Teric p.23
      expect(
        formatDepth(
          31.58,
          imperial,
          displayRule: const {
            'depth_decimals': <String, dynamic>{'imperial': 1},
          },
        ),
        '103.6',
      );
      expect(formatDepth(null, metric), '--');
      expect(formatPressure(207.0, imperial), '3002');
      expect(formatPressure(207.0, metric), '207');
      expect(formatTemperature(27.0, imperial), '81');
      expect(formatTemperature(27.0, metric), '27');
    });

    // Python's order is a one-off override, then the layout, then the app
    // setting. Here the override and the setting are the caller's `current`.
    test('test_resolution_order_override_then_layout_then_setting', () {
      expect(resolveUnits(const {'units': 'metric'}, imperial), metric);
      expect(resolveUnits(const {}, imperial), imperial);
      expect(resolveUnits(const {}, metric), metric);
      expect(resolveUnits(null, imperial), imperial);
      expect(normalizeUnits('FT'), imperial);
      expect(normalizeUnits(null), metric);
      expect(normalizeUnits('psi'), imperial);
    });
  });

  group('parity with the Python units', () {
    final reference =
        pythonReference('rules/notices_cases.json')['units']
            as Map<String, dynamic>;

    test('normalize and resolve_units', () {
      for (final pair in reference['normalize'] as List<dynamic>) {
        final [value, expected] = pair as List<dynamic>;
        expect(normalizeUnits(value).key, expected, reason: '"$value"');
      }
      for (final c in jsonObjects(reference['resolve'])) {
        expect(
          resolveUnits(
            c['layout'] as Map<String, dynamic>?,
            normalizeUnits(c['current']),
          ).key,
          c['expected'],
          reason: '$c',
        );
      }
    });

    for (final units in UnitSystem.values) {
      test('conversions, labels and formats in ${units.key}', () {
        final system =
            (reference['systems'] as Map<String, dynamic>)[units.key]
                as Map<String, dynamic>;
        final values = [
          for (final v in system['values'] as List<dynamic>)
            (v as num).toDouble(),
        ];
        final displayRules = [
          for (final r in reference['display_rules'] as List<dynamic>)
            r as Map<String, dynamic>?,
        ];
        void column(String name, double Function(double) convert) {
          final expected = system[name] as List<dynamic>;
          for (var i = 0; i < values.length; i++) {
            expect(
              convert(values[i]),
              nearly(expected[i] as num),
              reason: '$name(${values[i]})',
            );
          }
        }

        column('depth', (v) => depth(v, units));
        column('pressure', (v) => pressure(v, units));
        column('temperature', (v) => temperature(v, units));
        column('volume_rate', (v) => volumeRate(v, units));
        column('depth_to_metres', (v) => depthToMetres(v, units));
        column('pressure_to_bar', (v) => pressureToBar(v, units));
        column('temperature_to_celsius', (v) => temperatureToCelsius(v, units));
        expect([
          for (final v in values) stopDepth(v, units),
        ], system['stop_depth']);
        expect([
          for (final v in values) formatPressure(v, units),
          formatPressure(null, units),
        ], system['format_pressure']);
        for (final decimals in [0, 1]) {
          expect(
            [
              for (final v in values)
                formatTemperature(v, units, decimals: decimals),
              formatTemperature(null, units, decimals: decimals),
            ],
            (system['format_temperature'] as List<dynamic>)[decimals],
            reason: 'format_temperature, $decimals decimals',
          );
        }
        for (var r = 0; r < displayRules.length; r++) {
          expect(
            [
              for (final v in values)
                formatDepth(v, units, displayRule: displayRules[r]),
              formatDepth(null, units, displayRule: displayRules[r]),
            ],
            (system['format_depth'] as List<dynamic>)[r],
            reason: 'format_depth with ${displayRules[r]}',
          );
          expect(
            depthDecimals(displayRules[r], units),
            (system['depth_decimals'] as List<dynamic>)[r],
            reason: 'depth_decimals of ${displayRules[r]}',
          );
        }
        for (final decimals in [0, 1, 2]) {
          expect(
            [for (final v in values) formatDepth(v, units, decimals: decimals)],
            (system['format_depth_decimals'] as List<dynamic>)[decimals],
            reason: 'format_depth, $decimals decimals',
          );
        }
        final labels = system['labels'] as Map<String, dynamic>;
        for (final kind in labels.keys) {
          expect(unitLabel(kind, units), labels[kind], reason: kind);
        }
      });
    }
  });
}
