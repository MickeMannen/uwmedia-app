/// What drawing overlays in the app needs, loaded once: the overlay fonts
/// registered with Flutter and read for measuring, the rules, and the
/// template trees (the bundled one in the app's assets, the user's on
/// disk).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// Where the bundled templates are among the assets.
const bundledTemplatesRoot = 'assets/overlays/templates';

/// The renderer and the painter, on the fonts and rules of the assets.
class HudKit {
  /// A kit of a renderer and a painter already made (tests use the font
  /// files of the repo).
  HudKit(this.renderer, this.painter);

  final HudRenderer renderer;
  final HudPainter painter;

  static Future<HudKit>? _loading;

  /// The kit, loaded on the first call (the fonts registered with Flutter
  /// once).
  static Future<HudKit> load([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle).catchError((Object e) {
        // A failed load is tried again next time.
        _loading = null;
        throw e;
      });

  static Future<HudKit> _load(AssetBundle bundle) async {
    final files = <String, Uint8List>{};
    for (final family in fontRegistry.values) {
      for (final file in family.values) {
        if (files.containsKey(file)) {
          continue;
        }
        final data = await bundle.load('assets/fonts/$file');
        files[file] = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        await (FontLoader(
          fontFamilyOf(file),
        )..addFont(Future.value(data))).load();
      }
    }
    final ink = await bundle.load('assets/fonts/ink_tables.bin');
    final fonts = TtfFonts(
      (file) => files[file] ?? (throw ArgumentError('No font $file')),
      inkTables: InkTables.parse(
        ink.buffer.asUint8List(ink.offsetInBytes, ink.lengthInBytes),
      ),
    );
    final rules = jsonDecode(
      await bundle.loadString('assets/hud_rules.json'),
    ) as Map<String, dynamic>;
    return HudKit(HudRenderer(fonts, HudRules(rules)), HudPainter(fonts));
  }
}

/// The bundled templates: the asset list under [bundledTemplatesRoot],
/// with the text files read in advance ([TemplateFolder] reads them as it
/// goes).
Future<TemplateFolder> bundledTemplateFolder([AssetBundle? bundle]) async {
  final assets = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assets);
  const prefix = '$bundledTemplatesRoot/';
  final files = [
    for (final asset in manifest.listAssets())
      if (asset.startsWith(prefix)) asset.substring(prefix.length),
  ];
  final texts = <String, String>{
    for (final file in files)
      if (file.endsWith('.json'))
        file: await assets.loadString('$prefix$file', cache: false),
  };
  return ListedTemplateFolder(
    bundledTemplatesRoot,
    files,
    (path) => texts[path],
  );
}

/// The user's templates in a folder on disk; an empty tree when there is
/// no such folder.
class DiskTemplateFolder implements TemplateFolder {
  DiskTemplateFolder(this.root);

  @override
  final String root;

  String _full(String path) => path.isEmpty ? root : p.join(root, path);

  @override
  List<String> folders(String path) {
    final dir = Directory(_full(path));
    if (!dir.existsSync()) {
      return [];
    }
    try {
      return [
        for (final entry in dir.listSync())
          if (entry is Directory && !p.basename(entry.path).startsWith('.'))
            p.basename(entry.path),
      ];
    } on FileSystemException {
      return [];
    }
  }

  @override
  bool isFile(String path) => File(_full(path)).existsSync();

  @override
  String? readText(String path) {
    try {
      return File(_full(path)).readAsStringSync();
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// The bytes of a template file by its full path as [TemplateTree] gives
/// it: an asset under [bundledTemplatesRoot], else a file on disk; `null`
/// when there is none.
Future<Uint8List?> templateFileBytes(String path, [AssetBundle? bundle]) async {
  if (path.startsWith('$bundledTemplatesRoot/')) {
    try {
      final data = await (bundle ?? rootBundle).load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on Object {
      // No such asset.
      return null;
    }
  }
  final file = File(path);
  return file.existsSync() ? file.readAsBytesSync() : null;
}
