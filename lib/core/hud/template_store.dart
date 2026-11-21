/// Where overlay templates are written, and how (Python
/// `utils/template_store.py`).
///
/// Who owns what: a bundled page is read-only. The only way to change one
/// is "save as", which copies the page (layout and skin image) into a page
/// the user owns under a new page id, under the same computer, another one
/// or a new one. The user's pages are purely additive: they live in the
/// user's template folder in a tree that mirrors the bundled one,
/// `<brand>/<computer>/<page>/[<variant>/]normal.json` with `normal.png`
/// and a `manifest.json`. A user manifest under a bundled computer lists
/// only the user's pages. A user page can never take a bundled page's id.
///
/// Nothing is written here: every save gives the list of files to write
/// and skins to copy, which the caller carries out. A save that is refused
/// gives none (Python has by then sometimes written the manifest).
///
/// [TemplateTarget.repo], saving straight into the bundled tree, is the
/// Python app's mode for a source checkout; the app itself always saves to
/// the user's folder.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/overlay_document.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

const skinFilename = 'normal.png';
const stateFilename = 'normal.json';
const manifestFilename = 'manifest.json';
const customBrand = 'custom';
const customManufacturer = 'Custom';

/// Where saves go.
enum TemplateTarget { user, repo }

/// A save that cannot be done; the message is for the user.
class TemplateStoreError implements Exception {
  const TemplateStoreError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A save of a page that cannot be written in this mode.
class ReadOnlyTemplateError extends TemplateStoreError {
  const ReadOnlyTemplateError(super.message);
}

/// A save as, or a new computer, with an id that is taken.
class TemplateExistsError extends TemplateStoreError {
  const TemplateExistsError(super.message);
}

/// One thing a save puts on disk.
sealed class TemplateFileOp {
  /// The file that is written.
  String get path;
}

/// A text file to write (in one step: a temporary file, then renamed).
class WriteTextOp implements TemplateFileOp {
  const WriteTextOp(this.path, this.text);

  @override
  final String path;
  final String text;
}

/// A skin image to put at [path]: a copy of [source], or, when [convert]
/// is set (the source is not a PNG), the image as an RGBA PNG.
class CopySkinOp implements TemplateFileOp {
  const CopySkinOp(this.source, this.path, {required this.convert});

  final String source;
  @override
  final String path;
  final bool convert;
}

/// What a save does: the page's state file and the files to write.
typedef TemplateSave = ({String statePath, List<TemplateFileOp> ops});

final _notSlug = RegExp('[^a-z0-9]+');

/// An id that can be a folder name, from a display name: "My Camera HUD"
/// gives "my_camera_hud".
String slugify(String? name) => (name ?? '')
    .pyStrip()
    .toLowerCase()
    .replaceAll(_notSlug, '_')
    .replaceAll(RegExp(r'^_+|_+$'), '')
    .replaceAll(RegExp('_+'), '_');

// Python `str.title()`: a letter after anything but a letter is a capital.
String _title(String text) {
  final out = StringBuffer();
  var inWord = false;
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    final letter = ch.toLowerCase() != ch.toUpperCase();
    out.write(letter ? (inWord ? ch.toLowerCase() : ch.toUpperCase()) : ch);
    inWord = letter;
  }
  return out.toString();
}

String _jsonValue(Object? value, String indent) {
  final inner = '$indent  ';
  switch (value) {
    case final Map<String, dynamic> map when map.isNotEmpty:
      return '{\n${[for (final MapEntry(:key, :value) in map.entries) '$inner${jsonEncode(key)}: ${_jsonValue(value, inner)}'].join(',\n')}\n$indent}';
    case Map<String, dynamic>():
      return '{}';
    case final List<dynamic> list when list.isNotEmpty:
      return '[\n${[for (final item in list) '$inner${_jsonValue(item, inner)}'].join(',\n')}\n$indent]';
    case List<dynamic>():
      return '[]';
    case final double number:
      return number.isFinite ? pyFloatRepr(number) : jsonEncode(null);
    default:
      return jsonEncode(value);
  }
}

/// The text of a template file: Python's `json.dump(data, indent=2,
/// ensure_ascii=False)` and a line break at the end.
String templateJsonText(Map<String, dynamic> data) =>
    '${_jsonValue(data, '')}\n';

bool _set(Object? value) =>
    value != null && value != '' && value != false && value != 0;

void _roundPositions(Object? elements) {
  for (final elem in elements as List<dynamic>? ?? const []) {
    for (final key in ['rel_x', 'rel_y']) {
      final value = (elem as Map<String, dynamic>)[key];
      if (value is double) {
        elem[key] = pyRoundTo(value, relDecimals);
      }
    }
  }
}

String _skinType(Map<String, dynamic> layout) {
  final skin = layout['hud_skin'];
  return skin is Map<String, dynamic>
      ? skin['type'] as String? ?? 'image'
      : 'image';
}

/// The form a layout has on disk: the skin's path is `normal.png` for an
/// image skin, `rel_x` and `rel_y` are rounded like the hand-written
/// files, and the markers of a merged variant are gone.
Map<String, dynamic> normalizedLayout(Map<String, dynamic> layout) {
  final data = stripVariantMarkers(layout);
  final skin = data.putIfAbsent(
    'hud_skin',
    () => <String, dynamic>{},
  ) as Map<String, dynamic>;
  if ((skin['type'] ?? 'image') == 'image') {
    skin['path'] = skinFilename;
  } else {
    skin.remove('path');
  }
  _roundPositions(skin['linked_elements']);
  return data;
}

/// "~/…" for a folder under the home folder, for status lines.
String displayRoot(String root, String? home, {p.Context? context}) {
  final ctx = context ?? p.posix;
  return home != null &&
          home.isNotEmpty &&
          (ctx.isWithin(home, root) || ctx.equals(home, root))
      ? '~/${ctx.relative(root, from: home)}'
      : root;
}

/// The templates as they are now, and what saving into them takes.
///
/// A store reads the folders once: after a save has been carried out,
/// make a new one (from folders listed again) before the next save. One
/// kept across saves does not know the page just made (Python reads the
/// folders on every call).
class TemplateStore {
  /// [fileExists] answers for files outside the two folders (a skin image
  /// the user picked).
  TemplateStore({
    this.bundled,
    required this.user,
    this.target = TemplateTarget.user,
    bool Function(String path)? fileExists,
    p.Context? context,
  }) : tree = TemplateTree(bundled: bundled, user: user),
       _fileExists = fileExists ?? ((_) => false),
       _path = context ?? p.posix {
    if (target == TemplateTarget.repo && bundled == null) {
      throw ArgumentError('Saving into the bundled tree needs one');
    }
  }

  final TemplateFolder? bundled;
  final TemplateFolder user;
  final TemplateTarget target;
  final TemplateTree tree;
  final bool Function(String path) _fileExists;
  final p.Context _path;

  TemplateFolder get _writeFolder =>
      target == TemplateTarget.repo ? bundled! : user;

  /// The folder saves go to.
  String get writeRoot => _writeFolder.root;

  bool get isDevMode => target == TemplateTarget.repo;

  Iterable<TemplateFolder> get _folders => [?bundled, user];

  bool _inTree(String path) =>
      _folders.any((folder) => path.startsWith('${folder.root}/'));

  bool _exists(String path) {
    for (final folder in _folders) {
      if (path.startsWith('${folder.root}/')) {
        return folder.isFile(path.substring(folder.root.length + 1));
      }
    }
    return _fileExists(path);
  }

  /// "bundled", "user" or "missing".
  String templateOrigin(String brand, String computer, String page) {
    final entry = tree.page(brand, computer, page);
    return entry == null ? 'missing' : entry['origin'] as String? ?? 'bundled';
  }

  /// Whether a page can be saved over (as opposed to saved as another): it
  /// is there, and it is the user's own or the saves go to the bundled
  /// tree.
  bool canSaveInPlace(String brand, String computer, String page) {
    final origin = templateOrigin(brand, computer, page);
    return origin != 'missing' && (origin == originUser || isDevMode);
  }

  WriteTextOp _write(String path, Map<String, dynamic> data) =>
      WriteTextOp(path, templateJsonText(data));

  // A skin image put into a page folder, unless it is that file already.
  List<TemplateFileOp> _copySkin(String source, String dest) {
    if (!_exists(source)) {
      throw TemplateStoreError('Skin image not found: $source');
    }
    if (_path.normalize(source) == _path.normalize(dest)) {
      return const [];
    }
    return [
      CopySkinOp(
        source,
        dest,
        convert: pySuffix(source).toLowerCase() != '.png',
      ),
    ];
  }

  // The image a layout's skin path names, when it says where that is: an
  // absolute path, or one in the template folders.
  String? _skinSourceOf(Map<String, dynamic> layout) {
    if (_skinType(layout) != 'image') {
      return null;
    }
    final raw = (layout['hud_skin'] as Map<String, dynamic>?)?['path'];
    return raw is String &&
            raw.isNotEmpty &&
            (isAbsolutePath(raw, _path) || _inTree(raw))
        ? raw
        : null;
  }

  List<TemplateFileOp> _skinInto(
    String folder,
    Map<String, dynamic> layout,
    String? skinSource,
  ) {
    final source = _set(skinSource) ? skinSource : _skinSourceOf(layout);
    return source != null && _skinType(layout) == 'image'
        ? _copySkin(source, '$folder/$skinFilename')
        : const [];
  }

  /// Writes a page's state file over the one that is there. [layout] may
  /// carry the skin's resolved path (the document's own, or an image just
  /// picked); it is copied in as `normal.png` when it is not that file
  /// already. A merged variant goes back into its two files. Throws a
  /// [ReadOnlyTemplateError] for a bundled page.
  TemplateSave saveTemplate(
    TemplateRef ref,
    Map<String, dynamic> layout, {
    String? skinSource,
  }) {
    if (!canSaveInPlace(ref.brand, ref.computer, ref.page)) {
      throw ReadOnlyTemplateError(
        '${ref.label} is a built-in template and is read-only here - '
        'use Save as… to make your own copy.',
      );
    }
    final statePath = tree.resolveState(
      ref.brand,
      ref.computer,
      ref.page,
      variant: ref.variant,
    );
    if (statePath == null) {
      throw TemplateStoreError('No state file found for ${ref.label}.');
    }
    final base = layout[layoutBaseKey];
    if (base is String && base.isNotEmpty) {
      return _saveVariantOverlay(statePath, base, layout, skinSource);
    }
    return (
      statePath: statePath,
      ops: [
        ..._skinInto(_path.dirname(statePath), layout, skinSource),
        _write(statePath, normalizedLayout(layout)),
      ],
    );
  }

  // A merged variant layout back into its two files: the shared elements,
  // the skin and the page's own keys into the base, the variant's own
  // elements (and its overrides and removals of base elements) into the
  // overlay. The skin image lies beside the base, or beside the overlay
  // for a variant with its own skin.
  TemplateSave _saveVariantOverlay(
    String statePath,
    String basePath,
    Map<String, dynamic> layout,
    String? skinSource,
  ) {
    final baseText = tree.readText(basePath);
    if (baseText == null) {
      throw TemplateStoreError(
        'The shared base $basePath for this variant is missing.',
      );
    }
    final (newBase, overlay) = splitVariantLayout(
      layout,
      jsonDecode(baseText) as Map<String, dynamic>,
    );
    final stateDir = _path.dirname(statePath);
    final skinDir = _set(overlay[variantSkinField])
        ? stateDir
        : _path.dirname(basePath);
    final ops = [
      ..._skinInto(skinDir, layout, skinSource),
      _write(basePath, normalizedLayout(newBase)),
    ];
    _roundPositions(overlay[variantElementsField]);
    ops.add(
      _write(statePath, {
        // With forward slashes on every system, so that the file reads
        // everywhere.
        variantBaseField: _path
            .relative(basePath, from: stateDir)
            .replaceAll(r'\', '/'),
        ...overlay,
      }),
    );
    return (statePath: statePath, ops: ops);
  }

  // The manifest of a computer in the write folder with a page added to
  // it, or renamed; a new one when the folder has none.
  WriteTextOp _manifestWith(
    String brand,
    String computer,
    String pageId,
    String pageName,
    String? manufacturer,
    String? model,
    String? rulesProfile,
  ) {
    final relative = '$brand/$computer/$manifestFilename';
    final text = _writeFolder.readText(relative);
    final Map<String, dynamic> data;
    if (text != null) {
      try {
        data = jsonDecode(text) as Map<String, dynamic>;
      } on Object {
        throw TemplateStoreError(
          'The manifest $writeRoot/$relative cannot be read.',
        );
      }
    } else {
      data = {
        'manufacturer': _set(manufacturer) ? manufacturer : customManufacturer,
        'model': model ?? _title(computer.replaceAll('_', ' ')),
        'pages': <dynamic>[],
        if (_set(rulesProfile)) 'rules_profile': rulesProfile,
      };
    }
    final pages = data.putIfAbsent('pages', () => <dynamic>[]) as List<dynamic>;
    final entry = pages
        .whereType<Map<String, dynamic>>()
        .where((page) => page['id'] == pageId)
        .firstOrNull;
    if (entry == null) {
      pages.add({'id': pageId, 'name': pageName});
    } else {
      entry['name'] = pageName;
    }
    return _write('$writeRoot/$relative', data);
  }

  /// Writes [layout] as the page [dst] in the write folder, with the
  /// computer's folder and manifest when they are not there yet and with
  /// the skin image copied, so that the page holds all it needs. An id
  /// that a bundled page has is refused (the one hard rule); a user page
  /// of that id is written over when [overwriteUser] is set.
  TemplateSave saveTemplateAs(
    Map<String, dynamic> layout,
    TemplateRef dst,
    String pageName, {
    String? skinSource,
    String? manufacturer,
    String? model,
    String? rulesProfile,
    bool overwriteUser = true,
  }) {
    for (final part in [dst.brand, dst.computer, dst.page]) {
      if (part.isEmpty || slugify(part) != part) {
        throw TemplateStoreError(
          "Invalid template id '$part' - use lowercase letters, digits and "
          'underscores.',
        );
      }
    }
    final variant = dst.variant ?? '';
    if (variant.isNotEmpty && slugify(variant) != variant) {
      throw TemplateStoreError("Invalid variant id '$variant'.");
    }

    final existingComputer = tree.brands[dst.brand]?[dst.computer];
    final existingPage = tree.page(dst.brand, dst.computer, dst.page);
    if (existingPage != null) {
      if (existingPage['origin'] == originBundled || isDevMode) {
        throw TemplateExistsError(
          "A page with id '${dst.page}' already exists under "
          '${dst.brand}/${dst.computer} - choose another name.',
        );
      }
      if (!overwriteUser) {
        throw TemplateExistsError(
          "You already have a page '${dst.page}' under "
          '${dst.brand}/${dst.computer}.',
        );
      }
    }
    var maker = manufacturer;
    var named = model;
    var profile = rulesProfile;
    if (existingComputer != null) {
      maker = _set(maker) ? maker : existingComputer['manufacturer'] as String?;
      named ??= existingComputer['model'] as String? ?? '';
      profile = _set(profile)
          ? profile
          : existingComputer['rules_profile'] as String?;
    }

    final pageDir = [
      writeRoot,
      dst.brand,
      dst.computer,
      dst.page,
      if (variant.isNotEmpty) variant,
    ].join('/');
    final manifest = _manifestWith(
      dst.brand,
      dst.computer,
      dst.page,
      pageName,
      maker,
      named,
      profile,
    );

    final data = normalizedLayout(layout);
    if (_set(maker)) {
      data['manufacturer'] = maker;
    }
    if (named != null) {
      data['model'] = named;
    }
    if (_set(profile)) {
      data['rules_profile'] = profile;
    }

    final skin = <TemplateFileOp>[];
    if (_skinType(layout) == 'image') {
      final source = _set(skinSource) ? skinSource : _skinSourceOf(layout);
      if (source == null) {
        throw const TemplateStoreError(
          'The skin image path is not absolute - cannot locate the image to '
          'copy.',
        );
      }
      skin.addAll(_copySkin(source, '$pageDir/$skinFilename'));
    }
    final statePath = '$pageDir/$stateFilename';
    return (
      statePath: statePath,
      ops: [manifest, ...skin, _write(statePath, data)],
    );
  }

  /// The manifest of a new computer without pages in the write folder, for
  /// the wizard of the user's own brand before its first page is saved.
  TemplateSave createComputer(
    String brand,
    String computer,
    String manufacturer,
    String model, {
    String? rulesProfile,
  }) {
    for (final part in [brand, computer]) {
      if (part.isEmpty || slugify(part) != part) {
        throw TemplateStoreError("Invalid template id '$part'.");
      }
    }
    if (tree.brands[brand]?[computer] != null) {
      throw TemplateExistsError('$brand/$computer already exists.');
    }
    final path = '$writeRoot/$brand/$computer/$manifestFilename';
    return (
      statePath: path,
      ops: [
        _write(path, {
          'manufacturer': manufacturer,
          'model': model,
          'pages': <dynamic>[],
          if (_set(rulesProfile)) 'rules_profile': rulesProfile,
        }),
      ],
    );
  }
}
