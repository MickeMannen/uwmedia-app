import 'dart:convert';
import 'dart:io';

import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/model/dive.dart';

/// The renderer fixture made by tool/python_reference/renderer_fixture.py:
/// the drawing operations of the Python renderer per case, the dives and
/// histories they were drawn for, and every text measurement Pillow gave.
class RendererReference {
  RendererReference._(this.data) {
    final dumps = data['dives'] as Map<String, dynamic>;
    for (final name in dumps.keys) {
      dives[name] = Dive.fromJson(dumps[name] as Map<String, dynamic>);
    }
  }

  factory RendererReference.load() => RendererReference._(
    jsonDecode(
      utf8.decode(
        gzip.decode(
          File(
            'test/fixtures/python_reference/renderer/'
            'renderer_cases.json.gz',
          ).readAsBytesSync(),
        ),
      ),
    ) as Map<String, dynamic>,
  );

  final Map<String, dynamic> data;
  final Map<String, Dive> dives = {};
  final Map<String, List<Waypoint>> _forced = {};
  final Map<String, Map<String, dynamic>> _layouts = {};

  List<Map<String, dynamic>> get cases => [
    for (final c in data['cases'] as List<dynamic>) c as Map<String, dynamic>,
  ];

  late final ReplayFonts fonts = ReplayFonts(
    data['measures'] as Map<String, dynamic>,
    metrics: data['metrics'] as Map<String, dynamic>? ?? const {},
    glyphs: data['glyphs'] as Map<String, dynamic>? ?? const {},
  );

  /// (waypoint, history) of a case: a moment of a dummy dive, or the last
  /// waypoint of a forced state's short history (which has none when the
  /// state is made from one waypoint alone).
  (Waypoint, List<Waypoint>?) situation(Map<String, dynamic> c) {
    final key = c['history'] as String;
    final index = c['index'] as int;
    final dive = dives[key];
    if (dive != null) {
      return (dive.waypoints[index], dive.waypoints);
    }
    final stored =
        (data['histories'] as Map<String, dynamic>)[key]
            as Map<String, dynamic>;
    final waypoints = _forced.putIfAbsent(key, () {
      final of = dives[stored['dive']]!;
      return [
        for (final w in stored['waypoints'] as List<dynamic>)
          Waypoint.fromJson(w as Map<String, dynamic>)..dive = of,
      ];
    });
    return (waypoints[index], stored['alone'] == true ? null : waypoints);
  }

  static String templatePath(List<dynamic> template) =>
      'assets/overlays/templates/'
      '${template.whereType<String>().join('/')}/normal.json';

  /// The bundled template of a case, loaded by the port's own loader, as
  /// the Python app has it: what the port's template changes on purpose
  /// ([templateDifferences]) is put back, so that the renderer is compared
  /// on the template Python drew.
  Map<String, dynamic> layout(List<dynamic> template) => _layouts.putIfAbsent(
    template.whereType<String>().join('/'),
    () => asPython(
      template.whereType<String>().join('/'),
      stripVariantMarkers(
        loadLayoutFile(
          templatePath(template),
          (path) => File(path).readAsStringSync(),
        ),
      ),
    ),
  );

  /// The skin image's size, as Python read it from the file.
  (int, int)? skinSize(List<dynamic> template) {
    final size =
        (data['skins'] as Map<String, dynamic>)[template
            .whereType<String>()
            .join('/')];
    return size is List<dynamic> ? (size[0] as int, size[1] as int) : null;
  }
}

/// Where a bundled template differs from the Python app's on purpose
/// (spec §10): per template, per element id, the port's values and
/// Python's.
const templateDifferences = <String, Map<String, Map<String, (num, num)>>>{
  // §10.83: the Descent X50i's tank icons stand on the pressure digits'
  // foot.
  'garmin/x50i/main/single_tank': {
    'primary_tank_pressure_icon': {'rel_y': (0.3092, 0.31409)},
  },
  'garmin/x50i/main/sidemount': {
    'primary_tank_pressure_icon': {'rel_y': (0.3092, 0.31409)},
    'secondary_tank_pressure_icon': {'rel_y': (0.3092, 0.31409)},
  },
  'garmin/x50i/cc': {
    'primary_tank_pressure_icon': {'rel_y': (0.3092, 0.31409)},
  },
};

/// [layout] of the bundled [template] with Python's values in the places
/// of [templateDifferences]. A difference the template no longer has
/// throws: the list is then out of date.
Map<String, dynamic> asPython(String template, Map<String, dynamic> layout) {
  final differences = templateDifferences[template];
  if (differences == null) {
    return layout;
  }
  final copy = jsonDecode(jsonEncode(layout)) as Map<String, dynamic>;
  final elements =
      (copy['hud_skin'] as Map<String, dynamic>)['linked_elements']
          as List<dynamic>;
  for (final MapEntry(key: id, value: values) in differences.entries) {
    final elem = elements.singleWhere(
      (e) => (e as Map<String, dynamic>)['id'] == id,
    ) as Map<String, dynamic>;
    for (final MapEntry(key: name, value: (port, python)) in values.entries) {
      if (elem[name] != port) {
        throw StateError('$template: $id.$name is ${elem[name]}, not $port');
      }
      elem[name] = python;
    }
  }
  return copy;
}

/// The text of the bundled template file [path] with Python's values in
/// the places of [templateDifferences], for the tests that read the file
/// itself. A difference the file no longer has throws.
String asPythonText(String path, String text) {
  final at = path.replaceAll(r'\', '/');
  for (final MapEntry(key: template, value: differences)
      in templateDifferences.entries) {
    if (!at.endsWith('/templates/$template/normal.json')) {
      continue;
    }
    // An id's place in the text is not looked for: the same value of
    // several elements is put back once for all of them.
    final values = {
      for (final of in differences.values)
        for (final MapEntry(key: name, value: (port, python)) in of.entries)
          (name, port, python),
    };
    for (final (name, port, python) in values) {
      if (!text.contains('"$name": $port,')) {
        throw StateError('$template: no $name of $port');
      }
      text = text.replaceAll('"$name": $port,', '"$name": $python,');
    }
  }
  return text;
}

/// The changed copies of a layout the fixture renders too: the same change
/// to every element as `changed()` in the generator makes.
Map<String, dynamic> changedLayout(Map<String, dynamic> layout, String name) {
  final copy = jsonDecode(jsonEncode(layout)) as Map<String, dynamic>;
  final elements =
      (copy['hud_skin'] as Map<String, dynamic>)['linked_elements']
          as List<dynamic>? ??
      const [];
  for (var i = 0; i < elements.length; i++) {
    final elem = elements[i] as Map<String, dynamic>;
    final isText = !elem.containsKey('type');
    switch (name) {
      case 'outline':
        elem['outline'] = true;
      case 'turned':
        if (isText) {
          elem['orientation'] = const ['stacked', 'up', 'down'][i % 3];
          if (i.isOdd) {
            elem['unit_orientation'] = const ['up', 'down', 'stacked'][i % 3];
          }
        }
      case 'aligned':
        elem['align'] = const ['left', 'center', 'right'][i % 3];
        elem['valign'] = const ['middle', 'bottom', 'top'][(i ~/ 3) % 3];
        if (isText && i % 4 == 0) {
          elem['unit_suffix'] = true;
          elem.remove('unit_position');
        }
        if (isText && i % 5 == 0) {
          elem['max_width'] = 40;
        }
      case 'scaled':
        elem['scale'] = const [0.5, 1.3, 2.0][i % 3];
        if (elem['type'] == 'badge') {
          elem['value_align'] = 'center';
          elem['title_box'] = i.isEven;
        }
        if (elem['type'] == 'graph') {
          elem['marker_style'] = const ['cross', 'bold_cross', 'dot'][i % 3];
          elem['stop_label'] = true;
          elem['reveal_profile'] = !(elem['reveal_profile'] == true);
        }
    }
  }
  return copy;
}

/// Fonts that answer with Pillow's own measurements from the fixture, so
/// the renderer's geometry can be compared with Python's exactly. A text
/// Python never measured is a difference in the port and throws.
class ReplayFonts implements HudFonts {
  ReplayFonts(this.measures, {this.metrics = const {}, this.glyphs = const {}});

  final Map<String, dynamic> measures;

  /// Pillow's `getmetrics()` per `<file>@<size>`.
  final Map<String, dynamic> metrics;

  /// Per font file, per character: whether Python found the glyph missing.
  final Map<String, dynamic> glyphs;

  @override
  HudFont font(int size, String file) => _ReplayFont(
    file,
    size,
    measures['$file@$size'] as Map<String, dynamic>? ?? const {},
    metrics['$file@$size'] as List<dynamic>?,
    glyphs[file] as Map<String, dynamic>? ?? const {},
  );
}

class _ReplayFont implements HudFont {
  _ReplayFont(this.file, this.size, this.texts, this.metrics, this.lacks);

  @override
  final String file;
  @override
  final int size;
  final Map<String, dynamic> texts;
  final List<dynamic>? metrics;
  final Map<String, dynamic> lacks;

  @override
  int get ascent {
    final m = metrics;
    if (m == null) {
      throw StateError(
        'Python did not ask for the metrics of $file at $size px',
      );
    }
    return m[0] as int;
  }

  @override
  bool hasGlyph(String char) {
    final missing = lacks[char];
    if (missing == null) {
      throw StateError('Python did not check "$char" in $file');
    }
    return missing != true;
  }

  Object _measure(String text, int slot) {
    final entry = texts[text] as List<dynamic>?;
    final value = entry?[slot];
    if (value == null) {
      throw StateError(
        'Python did not ask for the ${slot == 0 ? 'ink box' : 'length'} of '
        '"$text" in $file at $size px',
      );
    }
    return value as Object;
  }

  @override
  (int, int, int, int) getbbox(String text) {
    final box = _measure(text, 0) as List<dynamic>;
    return (box[0] as int, box[1] as int, box[2] as int, box[3] as int);
  }

  @override
  double getlength(String text) => (_measure(text, 1) as num).toDouble();
}

/// The first difference between two operation lists, or `null`.
String? firstOpDifference(List<dynamic> got, List<dynamic> expected) {
  for (var i = 0; i < got.length && i < expected.length; i++) {
    if (!_same(got[i], expected[i])) {
      return 'operation $i:\n  port:   ${jsonEncode(got[i])}\n'
          '  Python: ${jsonEncode(expected[i])}';
    }
  }
  if (got.length != expected.length) {
    final longer = got.length > expected.length ? got : expected;
    final shorter = got.length > expected.length ? expected : got;
    return '${got.length} operations, Python has ${expected.length}; the '
        'first one only ${got.length > expected.length ? 'the port' : 'Python'}'
        ' has:\n  ${jsonEncode(longer[shorter.length])}';
  }
  return null;
}

bool _same(Object? a, Object? b) {
  if (a is num && b is num) {
    return (a - b).abs() <= 1e-6;
  }
  if (a is List<dynamic> && b is List<dynamic>) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

/// Fonts with made-up, regular measurements (half the size per letter),
/// for tests that only need some geometry, not Pillow's.
class FakeFonts implements HudFonts {
  const FakeFonts();

  @override
  HudFont font(int size, String file) => _FakeFont(file, size);
}

class _FakeFont implements HudFont {
  const _FakeFont(this.file, this.size);

  @override
  final String file;
  @override
  final int size;

  @override
  (int, int, int, int) getbbox(String text) =>
      (0, size ~/ 5, getlength(text).round(), size);

  @override
  double getlength(String text) => text.runes.length * size / 2;

  @override
  int get ascent => size * 4 ~/ 5;

  @override
  bool hasGlyph(String char) => true;
}
