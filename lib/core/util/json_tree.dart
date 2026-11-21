/// Copying and comparing JSON-like values (maps with text keys, lists,
/// text, numbers, bools, null), as Python's `copy.deepcopy` and `==` do
/// for the same data.
library;

/// A copy that shares no map or list with [value].
Object? jsonDeepCopy(Object? value) => switch (value) {
  final Map<String, dynamic> map => <String, dynamic>{
    for (final entry in map.entries) entry.key: jsonDeepCopy(entry.value),
  },
  final List<dynamic> list => <dynamic>[
    for (final item in list) jsonDeepCopy(item),
  ],
  _ => value,
};

/// [jsonDeepCopy] of a map.
Map<String, dynamic> jsonCopyMap(Map<String, dynamic> map) =>
    jsonDeepCopy(map)! as Map<String, dynamic>;

/// Whether two values are the same data: maps whatever the order of their
/// keys, lists item by item, `1` equal to `1.0` and, as in Python, `true`
/// equal to `1`.
bool jsonDeepEquals(Object? a, Object? b) {
  if (a is Map<String, dynamic> && b is Map<String, dynamic>) {
    return a.length == b.length &&
        a.entries.every(
          (e) => b.containsKey(e.key) && jsonDeepEquals(e.value, b[e.key]),
        );
  }
  if (a is List<dynamic> && b is List<dynamic>) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!jsonDeepEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  // Python's True and False are the numbers 1 and 0.
  if (a is bool && b is num) {
    return (a ? 1 : 0) == b;
  }
  if (a is num && b is bool) {
    return a == (b ? 1 : 0);
  }
  return a == b;
}
