// The Color Tuning sliders (lib/core/color/color_params.dart) against
// Python's utils/color_params.py and the page's value text, on the parity
// fixture made by tool/python_reference/color_params_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_params.dart';

import '../../helpers/python_reference.dart';

void main() {
  final reference = pythonReference('color/color_params_cases.json');

  test('the groups and parameters are Python\'s, then the look', () {
    expect([
      for (final (title, params) in colorParamGroups)
        if (title != lookGroupTitle)
          {
            'title': title,
            'params': [
              for (final p in params)
                [p.key, p.label, p.min, p.max, p.defaultValue, p.isInt],
            ],
          },
    ], reference['groups']);
    // The app's own group comes last (spec §10.101).
    final (title, look) = colorParamGroups.last;
    expect(title, lookGroupTitle);
    expect(
      [
        for (final p in look)
          [p.key, p.label, p.min, p.max, p.defaultValue, p.isInt],
      ],
      [
        ['vibrance', 'Vibrance', 0.0, 2.0, 0.0, false],
        ['contrast', 'Contrast', 0.0, 1.0, 0.0, false],
      ],
    );
    expect(colorSliderScale, reference['slider_scale']);
    expect(newProfileNameMax, reference['name_max']);
  });

  test('the value text beside a slider', () {
    for (final [value as num, isInt as bool, text]
        in (reference['texts'] as List<dynamic>).cast<List<dynamic>>()) {
      expect(colorValueText(value.toDouble(), isInt), text, reason: '$value');
    }
  });

  test('the defaults are the engine\'s own', () {
    final values = {
      for (final p in colorParamsByKey.values) p.key: p.defaultValue,
    };
    final fromTable = ColorProfile.fromMap(values);
    const builtIn = ColorProfile();
    expect(fromTable.toMap(), builtIn.toMap());
    expect(colorParamsByKey.length, 28);
  });
}
