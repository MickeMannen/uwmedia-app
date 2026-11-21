/// Finding the overlay templates (Python `utils/layouts.py`
/// `list_templates`, `resolve_template_state`, `list_layouts`): the bundled
/// tree and the user's own, `brand/computer/manifest.json` with a folder
/// per page and, in it, the state files or a folder per variant.
///
/// The folders are reached through [TemplateFolder], so the bundled tree
/// can be the app's asset list and the user's a folder on disk.
library;

import 'dart:convert';

import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

/// A folder of templates.
abstract interface class TemplateFolder {
  /// What the paths of this folder's entries start with (no slash at the
  /// end).
  String get root;

  /// The names of the folders in [path] (relative to the root, `''` for
  /// the root itself); empty when there is no such folder.
  List<String> folders(String path);

  /// Whether [path] is a file.
  bool isFile(String path);

  /// The text of the file [path], or `null` when it cannot be read.
  String? readText(String path);
}

/// A [TemplateFolder] made of a list of file paths, relative to [root] and
/// with `/` between the parts: the app's asset list, or a folder that was
/// listed once.
class ListedTemplateFolder implements TemplateFolder {
  ListedTemplateFolder(this.root, Iterable<String> files, this._read)
    : _files = files.toSet();

  @override
  final String root;

  final Set<String> _files;
  final String? Function(String path) _read;

  @override
  List<String> folders(String path) {
    final prefix = path.isEmpty ? '' : '$path/';
    return {
      for (final file in _files)
        if (file.startsWith(prefix) && file.indexOf('/', prefix.length) != -1)
          file.substring(prefix.length, file.indexOf('/', prefix.length)),
    }.toList();
  }

  @override
  bool isFile(String path) => _files.contains(path);

  @override
  String? readText(String path) => isFile(path) ? _read(path) : null;
}

/// Where a template came from.
const originBundled = 'bundled';
const originUser = 'user';

/// The message for a user page that has the id of a bundled one.
String collisionWarning(String brand, String computer, String page) =>
    'Warning: user template page $brand/$computer/$page collides with a '
    'bundled page and is ignored (bundled pages cannot be overridden).';

// The manifest of one computer's folder, with "path" added to it and to
// each page, and "variants" (the page folder's subfolders) to each page.
// Null when there is none or it cannot be read.
Map<String, dynamic>? _readManifest(TemplateFolder folder, String computer) {
  final text = folder.readText('$computer/manifest.json');
  if (text == null) {
    return null;
  }
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    return null;
  }
  // Python fails on a manifest that is not an object, or on a page without
  // an id; here such a manifest is passed over.
  if (data is! Map<String, dynamic>) {
    return null;
  }
  final listed = data['pages'] ?? const <dynamic>[];
  if (listed is! List ||
      listed.any((p) => p is! Map<String, dynamic> || p['id'] is! String)) {
    return null;
  }
  return {
    ...data,
    'path': '${folder.root}/$computer',
    'pages': [
      for (final page in listed.cast<Map<String, dynamic>>())
        {
          ...page,
          'path': '${folder.root}/$computer/${page['id']}',
          'variants': sortVariants(folder.folders('$computer/${page['id']}')),
        },
    ],
  };
}

/// The bundled templates and the user's own.
class TemplateTree {
  /// Reads the manifests of both folders. [warn] is told about user pages
  /// that are passed over.
  TemplateTree({
    TemplateFolder? bundled,
    TemplateFolder? user,
    void Function(String message)? warn,
  }) : _folders = {originBundled: ?bundled, originUser: ?user} {
    _folders.forEach((origin, folder) {
      for (final brand in folder.folders('')..sort()) {
        for (final computer in folder.folders(brand)..sort()) {
          final manifest = _readManifest(folder, '$brand/$computer');
          if (manifest == null) {
            continue;
          }
          final pages = (manifest['pages'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          manifest['origin'] = origin;
          for (final page in pages) {
            page['origin'] = origin;
          }
          if (origin == originUser) {
            manifest['user_path'] = manifest['path'];
          }
          final existing = brands[brand]?[computer];
          if (existing == null) {
            brands.putIfAbsent(brand, () => {})[computer] = manifest;
            continue;
          }
          // Additive: the user's pages go beside the bundled ones, and a
          // bundled page is never shadowed.
          existing['user_path'] = manifest['path'];
          final known = (existing['pages'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          final ids = {for (final page in known) page['id']};
          for (final page in pages) {
            if (!ids.add(page['id'])) {
              warn?.call(
                collisionWarning(brand, computer, page['id'] as String),
              );
              continue;
            }
            known.add(page);
          }
        }
      }
    });
  }

  final Map<String, TemplateFolder> _folders;

  /// `{brand: {computer: manifest}}`. A manifest is the content of
  /// `manifest.json` plus `path` (the computer's folder), `origin`
  /// ([originBundled] or [originUser]), `user_path` when the user's tree
  /// has that computer, and per page `path`, `origin` and `variants` (the
  /// names of its subfolders, tank setups first; empty when the page has
  /// no variant level).
  ///
  /// A brand or computer that only the user's tree has is added whole; a
  /// user computer that matches a bundled one adds its pages to it.
  final Map<String, Map<String, Map<String, dynamic>>> brands = {};

  /// The page entry of a manifest, or `null`.
  Map<String, dynamic>? page(String brand, String computer, String page) {
    final pages = brands[brand]?[computer]?['pages'] as List<dynamic>?;
    return pages
        ?.cast<Map<String, dynamic>>()
        .where((p) => p['id'] == page)
        .firstOrNull;
  }

  /// The path of the state file of a page (and variant), or `null` when
  /// there is none. A page with variants has no state of its own (its
  /// page-level `normal.json`, when there is one, is the variants' shared
  /// base), so without a [variant] the answer is `null` there.
  String? resolveState(
    String brand,
    String computer,
    String page, {
    String? variant,
    String state = 'normal',
  }) {
    final entry = this.page(brand, computer, page);
    if (entry == null) {
      return null;
    }
    if (variant == null && (entry['variants'] as List<dynamic>).isNotEmpty) {
      return null;
    }
    final hasVariant = variant != null && variant.isNotEmpty;
    final path = hasVariant
        ? '${entry['path']}/$variant/$state.json'
        : '${entry['path']}/$state.json';
    final folder = _folders[entry['origin']]!;
    return folder.isFile(path.substring(folder.root.length + 1)) ? path : null;
  }

  /// The text of a file of either folder by its full path, as
  /// [resolveState] gives it; for `loadLayoutFile`.
  String? readText(String path) {
    for (final folder in _folders.values) {
      // A file the document named by the platform's own separator, `\` on
      // Windows (a variant's shared page-level state, spec §10.86).
      if (path.startsWith('${folder.root}/') ||
          path.startsWith('${folder.root}\\')) {
        return folder.readText(path.substring(folder.root.length + 1));
      }
    }
    return null;
  }
}

/// The legacy overlay packages (`.zip` and `.json` files) of the bundled
/// folder and the user's, as name and path, sorted by name. A user file
/// with the name of a bundled one takes its place. The arguments are the
/// paths of the files directly in each folder.
List<(String name, String path)> listLayouts(
  Iterable<String> bundledFiles,
  Iterable<String> userFiles,
) {
  final entries = <String, String>{};
  for (final files in [bundledFiles, userFiles]) {
    for (final path in files.toList()..sort()) {
      if (layoutSuffixes.contains(pySuffix(path).toLowerCase())) {
        entries[pyStem(path)] = path;
      }
    }
  }
  return [
    for (final name in entries.keys.toList()..sort()) (name, entries[name]!),
  ];
}
