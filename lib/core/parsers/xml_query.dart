/// Reading XML logs the way the Python parsers do with lxml: the decoding
/// of the file, and the few XPath forms they use, on `package:xml`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

final _declaredEncoding = RegExp(
  r'''^<\?xml[^>]*\sencoding\s*=\s*["']([^"']+)["']''',
);

/// The text of an XML file: by its byte order mark, else by the encoding
/// its declaration names, else UTF-8. Throws a [FormatException] for bytes
/// that are not valid in that encoding, or an encoding this does not read.
String decodeXmlBytes(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Truncated UTF-16 text');
    }
    final littleEndian = bytes[0] == 0xff;
    return String.fromCharCodes([
      for (var i = 2; i < bytes.length; i += 2)
        littleEndian
            ? bytes[i] | bytes[i + 1] << 8
            : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    return utf8.decode(Uint8List.sublistView(bytes, 3));
  }
  final head = latin1.decode(
    bytes.length > 200 ? Uint8List.sublistView(bytes, 0, 200) : bytes,
  );
  final declared = _declaredEncoding
      .firstMatch(head.trimLeft())
      ?.group(1)
      ?.toLowerCase();
  switch (declared) {
    case null || 'utf-8' || 'utf8':
      return utf8.decode(bytes);
    case 'iso-8859-1' || 'latin1' || 'latin-1':
      return latin1.decode(bytes);
    case 'windows-1252' || 'cp1252':
      return String.fromCharCodes([
        for (final byte in bytes)
          0x80 <= byte && byte <= 0x9f ? _cp1252High[byte - 0x80] : byte,
      ]);
    case 'us-ascii' || 'ascii':
      return ascii.decode(bytes);
    default:
      throw FormatException('XML encoding not read: $declared');
  }
}

/// Windows-1252 for the bytes 0x80 to 0x9F, where it differs from Latin-1;
/// the five bytes it leaves undefined stay the control characters.
const List<int> _cp1252High = [
  0x20ac, 0x81, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, //
  0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d, 0x017d, 0x8f, //
  0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, //
  0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x9d, 0x017e, 0x0178, //
];

/// The document in [bytes]. Throws a [FormatException] or an
/// [XmlException] for a file that is not well-formed XML.
///
/// Line ends and attribute values are read as an XML parser must, which
/// `package:xml` leaves to the caller: CRLF and CR are a line feed, and a
/// line feed or a tab inside an attribute value is a space (also one
/// written as a character reference, which lxml would keep).
XmlDocument parseXmlBytes(Uint8List bytes) {
  final document = XmlDocument.parse(
    decodeXmlBytes(bytes).replaceAll(_carriageReturn, '\n'),
  );
  for (final element in document.descendantElements) {
    for (final attribute in element.attributes) {
      if (attribute.value.contains(_lineFeedOrTab)) {
        attribute.value = attribute.value.replaceAll(_lineFeedOrTab, ' ');
      }
    }
  }
  return document;
}

final _carriageReturn = RegExp(r'\r\n?');
final _lineFeedOrTab = RegExp(r'[\n\t]');

/// lxml's `element.text`: the text before the first child element.
String leadingText(XmlElement element) {
  final text = StringBuffer();
  for (final node in element.children) {
    if (node is XmlText || node is XmlCDATA) {
      text.write(node.value);
    } else {
      break;
    }
  }
  return text.toString();
}

/// lxml's `element.tag`: the plain name for an element in no namespace,
/// `{namespace}name` otherwise.
String lxmlTag(XmlElement element) {
  final namespace = element.name.namespaceUri;
  return namespace == null || namespace.isEmpty
      ? element.name.local
      : '{$namespace}${element.name.local}';
}

/// XPath `.//*[local-name()='name']` from [context] (from a document:
/// `//*[local-name()='name']`): the descendants with that local name, in
/// document order.
Iterable<XmlElement> descendantsNamed(XmlNode context, String name) =>
    context.descendantElements.where((e) => e.name.local == name);

/// XPath `*[local-name()='name']`: the children with that local name.
Iterable<XmlElement> childrenNamed(XmlElement context, String name) =>
    context.childElements.where((e) => e.name.local == name);

/// The first element, in document order, of the XPath
/// `.//*[local-name()=a]/*[local-name()=b]/…` from [context]: a descendant
/// named like the last of [path] whose parents, upwards, are named like the
/// ones before it. With [anyDepthBelowFirst], the last name may be any
/// descendant of the first (`.//a//b`).
XmlElement? firstByPath(
  XmlNode context,
  List<String> path, {
  bool anyDepthBelowFirst = false,
}) {
  for (final element in descendantsNamed(context, path.last)) {
    if (anyDepthBelowFirst) {
      XmlNode? ancestor = element.parent;
      while (ancestor != null && !identical(ancestor, context)) {
        if (ancestor is XmlElement && ancestor.name.local == path.first) {
          return element;
        }
        ancestor = ancestor.parent;
      }
      continue;
    }
    XmlNode? node = element;
    var matches = true;
    for (var i = path.length - 2; i >= 0; i--) {
      node = node?.parent;
      if (node is! XmlElement ||
          identical(node, context) ||
          node.name.local != path[i]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return element;
    }
  }
  return null;
}

/// XPath `string(…)` of an element: all the text inside it, or the empty
/// string for no element.
String stringValue(XmlElement? element) => element?.innerText ?? '';

/// XPath `string(*[local-name()='child']/@attribute)`: the attribute of the
/// first child of that name that has it, or the empty string.
String childAttribute(XmlElement context, String child, String attribute) {
  for (final element in childrenNamed(context, child)) {
    final value = element.getAttribute(attribute);
    if (value != null) {
      return value;
    }
  }
  return '';
}
