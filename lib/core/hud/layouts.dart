/// Template layout files, ported from `utils/layouts.py` of the Python app
/// (spec §5.1): the variant names and labels, and the merge of a variant
/// overlay with its page's shared base into the flat layout the renderer
/// and the Overlay Designer work with, and back.
///
/// A variant state file is either a complete layout or an overlay on the
/// page's shared base:
///
/// ```text
/// main/normal.json              the base: manufacturer, model, hud_skin
///                               and every element the variants share,
///                               each with an "id"
/// main/single_tank/normal.json  {"base": "../normal.json",
///                                "linked_elements": [...],
///                                "overrides": {"<id>": {"rel_x": ...}},
///                                "remove": ["<id>"],
///                                "skin": "normal.png"}
/// ```
///
/// The merged layout has the base's elements first (overrides applied,
/// removed ones dropped), then the variant's own, and its skin path points
/// at the base's image (or at the variant's own). It is tagged so the
/// Overlay Designer can put an edit back where it came from: [layoutBaseKey]
/// on the layout and [elementOriginKey] on each element. Both are
/// transient; [stripVariantMarkers] removes them before anything is
/// written.
///
/// Nothing here touches a file system: [loadLayoutFile] takes a reader, so
/// the same code loads a bundled asset and a user's file. Finding the
/// templates (the Python `list_templates`) is the app's, on top of its
/// asset list and its data folder.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

const List<String> layoutSuffixes = ['.zip', '.json'];

/// The tank-setup variants of a page, in the order the pickers list them:
/// the number of tanks, from none up. What else a template tree adds
/// follows by name.
const List<String> variantOrder = [
  'no_tank',
  'single_tank',
  'sidemount',
  'multi_tank',
];
const Map<String, String> variantLabels = {
  'no_tank': 'No tank',
  'single_tank': 'Single tank',
  'sidemount': 'Sidemount',
  'multi_tank': 'Multi-tank',
};

List<String> sortVariants(Iterable<String> names) {
  final all = names.toList();
  return [
    for (final v in variantOrder)
      if (all.contains(v)) v,
    ...all.where((v) => !variantOrder.contains(v)).toList()..sort(),
  ];
}

/// Python `str.title()` on words separated by spaces.
String _title(String text) => text
    .split(' ')
    .map(
      (word) => word.isEmpty
          ? word
          : word[0].toUpperCase() + word.substring(1).toLowerCase(),
    )
    .join(' ');

String variantDisplayName(String variant) =>
    variantLabels[variant] ?? _title(variant.replaceAll('_', ' '));

/// The label of a manifest page entry; a user's own page is marked, so
/// every template picker shows the same "yours" hint.
String pageDisplayName(Map<String, dynamic> page) {
  final own = page['name'];
  final name = own is String && own.isNotEmpty ? own : '${page['id'] ?? ''}';
  return page['origin'] == 'user' ? '$name · yours' : name;
}

const String variantBaseField = 'base';
const String variantElementsField = 'linked_elements';
const String variantOverridesField = 'overrides';
const String variantRemoveField = 'remove';
const String variantSkinField = 'skin';
const String layoutBaseKey = '_variant_of';
const String layoutVariantSkinKey = '_variant_skin';
const String elementOriginKey = '_origin';
const String originBase = 'base';
const String originOverride = 'override';
const String originVariant = 'variant';

Object? _deepCopy(Object? value) => switch (value) {
  final Map<String, dynamic> map => <String, dynamic>{
    for (final entry in map.entries) entry.key: _deepCopy(entry.value),
  },
  final List<dynamic> list => <dynamic>[
    for (final item in list) _deepCopy(item),
  ],
  _ => value,
};

Map<String, dynamic> _copy(Map<String, dynamic> map) =>
    _deepCopy(map)! as Map<String, dynamic>;

bool _truthy(Object? value) => switch (value) {
  null || false => false,
  final num number => number != 0,
  final String text => text.isNotEmpty,
  final List<dynamic> list => list.isNotEmpty,
  final Map<dynamic, dynamic> map => map.isNotEmpty,
  _ => true,
};

List<Map<String, dynamic>> _elements(Map<String, dynamic> layout) {
  final skin = layout['hud_skin'];
  final list = skin is Map<String, dynamic> ? skin['linked_elements'] : null;
  return [
    if (list is List<dynamic>)
      for (final elem in list)
        if (elem is Map<String, dynamic>) elem,
  ];
}

bool isVariantOverlay(Object? data) =>
    data is Map<String, dynamic> && data[variantBaseField] is String;

/// The base file a variant overlay at [overlayPath] names.
String variantBasePath(
  String overlayPath,
  Map<String, dynamic> data, {
  p.Context? context,
}) {
  final ctx = context ?? p.posix;
  return ctx.normalize(
    ctx.join(ctx.dirname(overlayPath), data[variantBaseField] as String),
  );
}

/// The flat layout of a variant [overlay] on [base] (which is copied),
/// tagged with [elementOriginKey]. A relative skin path is rewritten
/// relative to [overlayDir], where the layout's users resolve it; an
/// overlay's own "skin" replaces the base's image and tags the layout with
/// [layoutVariantSkinKey].
Map<String, dynamic> mergeVariantLayout(
  Map<String, dynamic> base,
  Map<String, dynamic> overlay,
  String baseDir,
  String overlayDir, {
  p.Context? context,
}) {
  final ctx = context ?? p.posix;
  final layout = _copy(base);
  final skin = layout.putIfAbsent(
    'hud_skin',
    () => <String, dynamic>{},
  ) as Map<String, dynamic>;
  final raw = skin['path'];
  if (raw is String && raw.isNotEmpty && !ctx.isAbsolute(raw)) {
    skin['path'] = ctx
        .relative(
          ctx.normalize(ctx.join(baseDir, raw)),
          from: ctx.normalize(overlayDir),
        )
        .replaceAll(ctx.separator, '/');
  }
  if (_truthy(overlay[variantSkinField])) {
    skin['path'] = overlay[variantSkinField];
    layout[layoutVariantSkinKey] = true;
  }
  final overrides = overlay[variantOverridesField] is Map<String, dynamic>
      ? overlay[variantOverridesField] as Map<String, dynamic>
      : const <String, dynamic>{};
  final removed = overlay[variantRemoveField] is List<dynamic>
      ? (overlay[variantRemoveField] as List<dynamic>).toSet()
      : const <dynamic>{};
  final merged = <dynamic>[];
  for (final original in _elements(layout)) {
    final id = original['id'];
    if (removed.contains(id)) {
      continue;
    }
    final elem = Map<String, dynamic>.of(original);
    final override = overrides[id];
    if (id is String && override is Map<String, dynamic>) {
      elem.addAll(override);
      elem[elementOriginKey] = originOverride;
    } else {
      elem[elementOriginKey] = originBase;
    }
    merged.add(elem);
  }
  final own = overlay[variantElementsField];
  if (own is List<dynamic>) {
    for (final original in own) {
      merged.add(
        Map<String, dynamic>.of(original as Map<String, dynamic>)
          ..[elementOriginKey] = originVariant,
      );
    }
  }
  skin['linked_elements'] = merged;
  for (final entry in overlay.entries) {
    if (!const [
      variantBaseField,
      variantElementsField,
      variantOverridesField,
      variantRemoveField,
      variantSkinField,
    ].contains(entry.key)) {
      layout[entry.key] = entry.value;
    }
  }
  return layout;
}

/// The flat layout in the template state file at [path]: the file itself,
/// or, for a variant overlay, its base merged with it. The result of an
/// overlay carries the transient markers; [stripVariantMarkers] removes
/// them. [readText] gives a file's text.
Map<String, dynamic> loadLayoutFile(
  String path,
  String Function(String path) readText, {
  p.Context? context,
}) {
  final ctx = context ?? p.posix;
  final data = jsonDecode(readText(path)) as Map<String, dynamic>;
  if (!isVariantOverlay(data)) {
    return data;
  }
  final basePath = variantBasePath(path, data, context: ctx);
  final base = jsonDecode(readText(basePath)) as Map<String, dynamic>;
  return mergeVariantLayout(
    base,
    data,
    ctx.dirname(basePath),
    ctx.dirname(path),
    context: ctx,
  )..[layoutBaseKey] = basePath;
}

/// True for a variant's element that comes unchanged from the shared base:
/// a move or an edit of it is saved to the base, so every variant of the
/// page follows.
bool isSharedElement(Map<String, dynamic> elem) =>
    elem[elementOriginKey] == originBase;

/// A copy for a duplicate or a paste: a new element of the variant being
/// edited, so it drops the original's origin marker and its id (the id is
/// what ties an element to the base).
Map<String, dynamic> asNewElement(Map<String, dynamic> elem) => _copy(elem)
  ..remove(elementOriginKey)
  ..remove('id');

/// A copy without the transient overlay markers: what gets written,
/// exported or compared.
Map<String, dynamic> stripVariantMarkers(Map<String, dynamic> layout) {
  final data = _copy(layout)
    ..remove(layoutBaseKey)
    ..remove(layoutVariantSkinKey);
  for (final elem in _elements(data)) {
    elem.remove(elementOriginKey);
  }
  return data;
}

bool _jsonEquals(Object? a, Object? b) {
  if (a is Map<String, dynamic> && b is Map<String, dynamic>) {
    return a.length == b.length &&
        a.entries.every(
          (e) => b.containsKey(e.key) && _jsonEquals(e.value, b[e.key]),
        );
  }
  if (a is List<dynamic> && b is List<dynamic>) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

/// The inverse of [mergeVariantLayout] for saving an edited merged layout:
/// (new base layout, overlay data). Shared elements (origin base or
/// override) go back to the base in the edited order; an overridden
/// element keeps the base's own values in the base and its differing keys
/// in the overlay's overrides; the elements the variant added, and any
/// without an origin (added while editing this variant), go to the
/// overlay; base elements no longer present are listed under remove. The
/// skin and every other key follow the base, except the image of a variant
/// with its own skin, which stays the variant's ("normal.png" beside the
/// overlay, where the caller puts it).
(Map<String, dynamic>, Map<String, dynamic>) splitVariantLayout(
  Map<String, dynamic> layout,
  Map<String, dynamic> base,
) {
  final baseElems = <Object, Map<String, dynamic>>{
    for (final e in _elements(base))
      if (_truthy(e['id'])) e['id'] as Object: e,
  };
  final newBase = stripVariantMarkers(layout);
  final shared = <dynamic>[];
  final variantElems = <dynamic>[];
  final overrides = <String, dynamic>{};
  final seen = <Object?>{};
  for (final elem in _elements(layout)) {
    final origin = elem[elementOriginKey];
    final clean = Map<String, dynamic>.of(elem)..remove(elementOriginKey);
    final id = clean['id'];
    if ((origin == originBase || origin == originOverride) &&
        baseElems.containsKey(id)) {
      seen.add(id);
      final original = baseElems[id]!;
      if (origin == originOverride) {
        final diff = <String, dynamic>{
          for (final entry in clean.entries)
            if (entry.key != 'id' &&
                !(original.containsKey(entry.key) &&
                    _jsonEquals(original[entry.key], entry.value)))
              entry.key: entry.value,
        };
        if (diff.isNotEmpty) {
          overrides['$id'] = diff;
        }
        shared.add(_copy(original));
      } else {
        shared.add(clean);
      }
    } else if (origin == originBase) {
      // A base element without an id: written back as it is.
      shared.add(clean);
    } else {
      variantElems.add(clean);
    }
  }
  final newSkin = newBase.putIfAbsent(
    'hud_skin',
    () => <String, dynamic>{},
  ) as Map<String, dynamic>;
  newSkin['linked_elements'] = shared;
  final removed = [
    for (final id in baseElems.keys)
      if (!seen.contains(id)) id,
  ];
  final overlay = <String, dynamic>{
    variantElementsField: variantElems,
    if (overrides.isNotEmpty) variantOverridesField: overrides,
    if (removed.isNotEmpty) variantRemoveField: removed,
  };
  if (_truthy(layout[layoutVariantSkinKey])) {
    final baseSkin = base['hud_skin'];
    newSkin['path'] = baseSkin is Map<String, dynamic>
        ? baseSkin['path']
        : null;
    overlay[variantSkinField] = 'normal.png';
  }
  return (newBase, overlay);
}
