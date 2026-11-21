/// Reading and writing the app's two small YAML files, `config.yaml` and
/// `color.yaml`, as text. The Python app reads them with PyYAML
/// (`yaml.safe_load`) and writes them with
/// `yaml.dump(default_flow_style=False, sort_keys=False)`; [writeYaml]
/// gives the same text for the same data, so a file can go between the two
/// apps.
///
/// PyYAML follows YAML 1.1 and `package:yaml` YAML 1.2, which read a few
/// unquoted words differently (`yes`, `010`, `1:30`). A scalar written
/// without quotes is therefore kept as [YamlPlain], with the text as it
/// stands in the file, and written back as that text.
library;

import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:yaml/yaml.dart';

/// A scalar that stands in the file without quotes: its [text] there, and
/// the [value] YAML 1.2 reads it as (a number, a bool, `null` or the text).
class YamlPlain {
  const YamlPlain(this.text, this.value);

  final String text;
  final Object? value;

  @override
  String toString() => text;
}

Object? _plainTree(YamlNode node) {
  switch (node) {
    case YamlMap():
      return <String, Object?>{
        for (final MapEntry(:key, :value) in node.nodes.entries)
          _keyText(key as YamlNode): _plainTree(value),
      };
    case YamlList():
      return [for (final item in node.nodes) _plainTree(item)];
    case YamlScalar():
      final text = node.span.text;
      // An anchor, a tag or an alias stands before the scalar's own text:
      // then the value itself is what the file means.
      if (node.style == ScalarStyle.PLAIN &&
          !text.contains('\n') &&
          !text.startsWith(RegExp('[&!*]'))) {
        return YamlPlain(text, node.value);
      }
      return node.value;
  }
  return null;
}

String _keyText(YamlNode key) => switch (_plainTree(key)) {
  final YamlPlain plain => plain.text,
  final String text => text,
  final other => '$other',
};

/// The content of a YAML document: maps with text keys, lists, text (a
/// quoted or block scalar) and [YamlPlain] for unquoted scalars. `null`
/// for an empty document; throws a [FormatException] for text that is not
/// YAML.
Object? readYaml(String text) {
  try {
    return _plainTree(loadYamlNode(text));
  } on YamlException catch (e) {
    throw FormatException(e.message, text);
  }
}

/// Whether [text] is a YAML file that cannot be read (broken, or with a
/// key twice in one map, which this reader refuses and PyYAML takes the
/// last of): saving over it loses what it holds, so a caller can ask
/// first.
bool yamlUnreadable(String? text) {
  if (text == null) {
    return false;
  }
  try {
    readYaml(text);
    return false;
  } on FormatException {
    return true;
  }
}

/// The top-level map of a YAML file, and an empty one when there is no
/// file, when it cannot be read or when it holds something else than a
/// map.
Map<String, Object?> readYamlMap(String? text) {
  if (text == null) {
    return {};
  }
  try {
    final data = readYaml(text);
    return data is Map<String, Object?> ? data : {};
  } on FormatException {
    return {};
  }
}

/// What a value read by [readYaml] stands for: the value of a [YamlPlain],
/// anything else as it is.
Object? yamlValue(Object? node) => node is YamlPlain ? node.value : node;

// What PyYAML's resolver takes an unquoted scalar for when it is not text
// (YAML 1.1): such text has to be quoted to stay text.
final _notText = RegExp(
  r'^(?:'
  // bool
  'yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE'
  '|on|On|ON|off|Off|OFF'
  // float
  r'|[-+]?[0-9][0-9_]*\.[0-9_]*(?:[eE][-+][0-9]+)?'
  r'|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?'
  r'|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*'
  r'|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN)'
  // int
  '|[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)'
  '|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+'
  // merge, null, value
  '|<<|~|null|Null|NULL|='
  // timestamp
  '|[0-9]{4}-[0-9]{2}-[0-9]{2}'
  r'|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}'
  r'(?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9]{1,2}(?::[0-9]{2})?))?'
  r')$',
);

const _escapes = {
  0x00: '0',
  0x07: 'a',
  0x08: 'b',
  0x09: 't',
  0x0A: 'n',
  0x0B: 'v',
  0x0C: 'f',
  0x0D: 'r',
  0x1B: 'e',
  0x22: '"',
  0x5C: r'\',
  0x85: 'N',
  0xA0: '_',
  0x2028: 'L',
  0x2029: 'P',
};

String _doubleQuoted(String text) {
  final out = StringBuffer('"');
  for (final rune in text.runes) {
    final escape = _escapes[rune];
    if (escape != null) {
      out.write('\\$escape');
    } else if (rune >= 0x20 && rune <= 0x7E) {
      out.writeCharCode(rune);
    } else if (rune <= 0xFF) {
      out.write('\\x${rune.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else if (rune <= 0xFFFF) {
      out.write('\\u${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    } else {
      out.write('\\U${rune.toRadixString(16).toUpperCase().padLeft(8, '0')}');
    }
  }
  out.write('"');
  return out.toString();
}

// Whether PyYAML writes [text] without quotes in a block: no character
// that means something to YAML where it stands, no space at either end.
bool _plainAllowed(String text) {
  if (text.isEmpty ||
      text.startsWith(' ') ||
      text.endsWith(' ') ||
      text.startsWith('---') ||
      text.startsWith('...')) {
    return false;
  }
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    final beforeSpace = i + 1 == text.length || text[i + 1] == ' ';
    if (i == 0) {
      if ('#,[]{}&*!|>\'"%@`'.contains(ch)) {
        return false;
      }
      if ('?:-'.contains(ch) && beforeSpace) {
        return false;
      }
    } else {
      if (ch == ':' && beforeSpace) {
        return false;
      }
      if (ch == '#' && text[i - 1] == ' ') {
        return false;
      }
    }
  }
  return true;
}

final _special = RegExp(r'[^\x20-\x7E]');

/// Text as a YAML scalar, the way PyYAML writes it: plain where that reads
/// back as the same text, in single quotes otherwise, in double quotes
/// with escapes when there is anything but printable ASCII in it (PyYAML
/// writes a line break in single quotes over several lines; here it is
/// `\n` in double quotes, which reads the same).
String _textScalar(String text) {
  if (_special.hasMatch(text)) {
    return _doubleQuoted(text);
  }
  if (_plainAllowed(text) && !_notText.hasMatch(text)) {
    return text;
  }
  return "'${text.replaceAll("'", "''")}'";
}

String _floatScalar(double value) {
  if (value.isNaN) {
    return '.nan';
  }
  if (value.isInfinite) {
    return value > 0 ? '.inf' : '-.inf';
  }
  final repr = pyFloatRepr(value);
  return !repr.contains('.') && repr.contains('e')
      ? repr.replaceFirst('e', '.0e')
      : repr;
}

String? _scalar(Object? value) => switch (value) {
  null => 'null',
  final bool b => '$b',
  final int i => '$i',
  final double d => _floatScalar(d),
  final String s => _textScalar(s),
  final YamlPlain plain => plain.text,
  Map(isEmpty: true) => '{}',
  List(isEmpty: true) => '[]',
  _ => null,
};

void _writeNode(StringBuffer out, Object? value, int indent, bool inline) {
  final lead = ' ' * indent;
  if (value is Map) {
    var first = inline;
    value.forEach((key, child) {
      out.write('${first ? '' : lead}${_textScalar('$key')}:');
      first = false;
      final scalar = _scalar(child);
      if (scalar != null) {
        out.writeln(' $scalar');
      } else {
        out.writeln();
        // A list under a key is not indented; a map is.
        _writeNode(out, child, child is List ? indent : indent + 2, false);
      }
    });
  } else if (value is List) {
    var first = inline;
    for (final child in value) {
      out.write('${first ? '' : lead}- ');
      first = false;
      final scalar = _scalar(child);
      if (scalar != null) {
        out.writeln(scalar);
      } else {
        _writeNode(out, child, indent + 2, true);
      }
    }
  } else {
    throw ArgumentError.value(value, 'value', 'not YAML data');
  }
}

/// [value] (maps, lists, text, numbers, bools, `null` and [YamlPlain]) as
/// the YAML text PyYAML's
/// `yaml.dump(default_flow_style=False, sort_keys=False)` writes: block
/// style, two spaces per level, keys in the order of the map. PyYAML
/// breaks text longer than 80 characters over several lines; here it
/// stays on one.
String writeYaml(Object? value) {
  final scalar = _scalar(value);
  if (scalar != null) {
    return '$scalar\n';
  }
  final out = StringBuffer();
  _writeNode(out, value, 0, false);
  return out.toString();
}
