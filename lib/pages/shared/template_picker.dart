/// The overlay picker of the Color page and the Overlay Generator (Python
/// `color_backend.py`'s Add HUD cascade and `overlay_generator_backend.py`'s
/// brand cascade): brand, dive computer, page and tank setup over the
/// template trees, and the picked page's layout copied to a working folder
/// with its skin, so that an overlay does not change when its template
/// does.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';

/// The picker's choices: display names to keys.
typedef Choices = Map<String, String>;

/// A picked page made a layout file: its path, the layout, and the
/// manifest and page entry it came from.
typedef PickedLayout = ({
  String layoutPath,
  Map<String, dynamic> layout,
  Map<String, dynamic> manifest,
  Map<String, dynamic> page,
  String brand,
  String computer,
});

/// "dive_computers" as "Dive Computers": Python's `str.title()` of a key
/// with spaces for underscores.
String prettifyKey(String key) => key
    .replaceAll('_', ' ')
    .split(' ')
    .map(
      (w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase(),
    )
    .join(' ');

class TemplatePicker extends ChangeNotifier {
  TemplatePicker(
    this.templates, {
    required this.tempDir,
    this.templateBytes,
    this.relist,
  });

  TemplateTree templates;

  /// Lists the templates again (the user's may have changed).
  final TemplateTree Function()? relist;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;

  /// The bytes of a template file (an asset or a file on disk).
  final Future<Uint8List?> Function(String path)? templateBytes;

  String? _brand;
  String? _computer;
  String? _page;
  String? _variant;

  /// Why the last pick gave no layout; empty otherwise.
  String error = '';

  Choices get brandChoices => {
    for (final key in templates.brands.keys.toList()..sort())
      prettifyKey(key): key,
  };

  Map<String, Map<String, dynamic>> get _computers =>
      _brand == null ? const {} : templates.brands[_brand] ?? const {};

  Choices get computerChoices => {
    for (final key in _computers.keys.toList()..sort()) prettifyKey(key): key,
  };

  /// A brand with one computer does not ask which.
  bool get computerVisible => _computers.length > 1;

  List<Map<String, dynamic>> get _pages {
    final manifest = _computer == null ? null : _computers[_computer];
    final pages = manifest?['pages'];
    return pages is List ? pages.cast<Map<String, dynamic>>() : const [];
  }

  Choices get pageChoices => {
    for (final page in _pages) pageDisplayName(page): page['id'] as String,
  };

  List<String> get _variants {
    final entry = _pages.where((p) => p['id'] == _page).firstOrNull;
    final variants = entry?['variants'];
    return variants is List ? variants.cast<String>() : const [];
  }

  /// The page's tank setups (no tank, single tank, sidemount, multi-tank).
  Choices get variantChoices => {
    for (final v in _variants) variantDisplayName(v): v,
  };

  String? get selectedBrand => _brand;
  String? get selectedComputer => _computer;
  String? get selectedPage => _page;
  String? get selectedVariant => _variant;

  void _pickVariant() {
    final variants = _variants;
    if (!variants.contains(_variant)) {
      _variant = variants.contains('single_tank')
          ? 'single_tank'
          : variants.firstOrNull;
    }
  }

  void selectBrand(String key) {
    _brand = key;
    _computer = computerChoices.values.firstOrNull;
    _page = pageChoices.values.firstOrNull;
    _pickVariant();
    error = '';
    notifyListeners();
  }

  void selectComputer(String key) {
    _computer = key;
    _page = pageChoices.values.firstOrNull;
    _pickVariant();
    notifyListeners();
  }

  void selectPage(String key) {
    _page = key;
    _pickVariant();
    notifyListeners();
  }

  void selectVariant(String key) {
    _variant = key;
    notifyListeners();
  }

  /// The templates listed again after a save in the Overlay Designer, and
  /// the first brand picked (Python's `reloadTemplates`).
  void reload() {
    final list = relist;
    if (list != null) {
      templates = list();
    }
    reset();
  }

  /// The first brand and its first choices.
  void reset() {
    error = '';
    final first = brandChoices.values.firstOrNull;
    if (first != null) {
      selectBrand(first);
    } else {
      notifyListeners();
    }
  }

  /// The choice as it can be kept and given back to [restore].
  Map<String, String> get choice => {
    'brand': ?_brand,
    'computer': ?_computer,
    'page': ?_page,
    'variant': ?_variant,
  };

  /// The choice [kept] by [choice] picked again, as far as it is still
  /// there: a brand, computer, page or tank setup that is gone gives way
  /// to the first of what there is. Nothing kept is [reset].
  void restore(Object? kept) {
    reset();
    if (kept is! Map) {
      return;
    }
    final brand = kept['brand'];
    if (!brandChoices.containsValue(brand)) {
      return;
    }
    selectBrand(brand as String);
    final computer = kept['computer'];
    if (!computerChoices.containsValue(computer)) {
      return;
    }
    selectComputer(computer as String);
    final page = kept['page'];
    if (!pageChoices.containsValue(page)) {
      return;
    }
    selectPage(page as String);
    final variant = kept['variant'];
    if (variantChoices.containsValue(variant)) {
      selectVariant(variant as String);
    }
  }

  /// The picked page's layout, its variant markers taken out, written to a
  /// fresh working folder ([tempPrefix]) as `brand[_computer]_page[_variant]
  /// .json` with its skin beside it. `null` with [error] set when there is
  /// no layout for the choice.
  Future<PickedLayout?> materialize(String tempPrefix) async {
    final brand = _brand;
    final computer = _computer;
    final page = _page;
    final manifest = computer == null ? null : _computers[computer];
    final entry = _pages.where((p) => p['id'] == page).firstOrNull;
    final state = brand == null || computer == null || page == null
        ? null
        : templates.resolveState(brand, computer, page, variant: _variant);
    Map<String, dynamic>? layout;
    if (manifest != null && entry != null && state != null) {
      try {
        layout = stripVariantMarkers(
          loadLayoutFile(
            state,
            (path) => templates.readText(path) ?? (throw FormatException(path)),
          ),
        );
      } on Object {
        layout = null;
      }
    }
    if (layout == null) {
      error = 'Could not resolve a layout for that choice.';
      notifyListeners();
      return null;
    }
    final names = [
      brand!,
      if (_computers.length > 1) computer!,
      page!,
      ?_variant,
    ];
    final dir = tempDir(tempPrefix);
    final hudSkin =
        (layout['hud_skin'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    final skinPath = hudSkin['path'];
    if (skinPath is String && skinPath.isNotEmpty) {
      final from = p.isAbsolute(skinPath)
          ? skinPath
          : state!.startsWith('$bundledTemplatesRoot/')
          ? p.posix.join(p.posix.dirname(state), skinPath)
          : p.join(p.dirname(state), skinPath);
      final bytes = await templateBytes?.call(from);
      if (bytes != null) {
        final name = p.basename(skinPath);
        File(p.join(dir.path, name)).writeAsBytesSync(bytes);
        hudSkin['path'] = name;
      }
    }
    final layoutPath = p.join(dir.path, '${names.join('_')}.json');
    File(layoutPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(layout));
    return (
      layoutPath: layoutPath,
      layout: layout,
      manifest: manifest!,
      page: entry!,
      brand: brand,
      computer: computer!,
    );
  }
}
