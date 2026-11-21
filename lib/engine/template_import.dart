/// A page of the Overlay Designer, exported as a zip on the desktop,
/// brought into the user's templates (user story 9, U9.4; spec §10.46):
/// how a phone gets the diver's own overlays. The zip is the Designer's
/// (`exportZip`): `normal.json`, `template.json` and, for an image skin,
/// `normal.png`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/overlay_document.dart';
import 'package:uwmedia_app/core/hud/template_store.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/engine/template_files.dart';

/// What a page zip says about the page (the Designer's `zipMetaFilename`).
const pageZipMetaFilename = 'template.json';

/// Whether [bytes] is a zip holding a Designer page (and so no zip of
/// dive logs).
bool isPageZip(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
    return false;
  }
  try {
    return ZipDecoder().decodeBytes(bytes).findFile(stateFilename) != null;
  } on Object {
    return false;
  }
}

/// Saves the page in the zip [bytes] among the user's templates
/// ([user]), under the brand, computer and page it was exported from; a
/// page that is there already (bundled or the user's) is left alone and
/// this one numbered ("My page 2"). Gives what the page is now called.
/// Throws a [FormatException] for a zip that is no page, and a
/// [TemplateStoreError] or [FileSystemException] when it cannot be saved.
Future<String> importPageZip(
  Uint8List bytes, {
  required TemplateFolder? bundled,
  required TemplateFolder user,
  required Directory Function(String prefix) tempDir,
}) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw const FormatException('not a zip file');
  }
  final state = archive.findFile(stateFilename);
  if (state == null) {
    throw const FormatException('no $stateFilename in the zip');
  }
  final Map<String, dynamic> layout;
  var meta = <String, dynamic>{};
  try {
    layout = jsonDecode(utf8.decode(state.content)) as Map<String, dynamic>;
    final metaFile = archive.findFile(pageZipMetaFilename);
    if (metaFile != null) {
      meta = jsonDecode(utf8.decode(metaFile.content)) as Map<String, dynamic>;
    }
  } on Object {
    throw const FormatException('the page in the zip cannot be read');
  }
  String text(String key) => meta[key] is String ? meta[key] as String : '';
  String slugOr(String value, String fallback) {
    final slug = slugify(value);
    return slug.isEmpty ? fallback : slug;
  }

  final brand = slugOr(text('brand'), 'custom');
  final computer = slugOr(text('computer'), 'imported');
  final name = text('page_name').trim().isNotEmpty
      ? text('page_name').trim()
      : text('page').isNotEmpty
      ? text('page')
      : 'Imported';
  final page = slugOr(text('page').isNotEmpty ? text('page') : name, 'page');

  final work = tempDir('uwmedia_import_');
  try {
    String? skinPath;
    final skin = layout['hud_skin'] ??= <String, dynamic>{};
    if (skin is! Map<String, dynamic>) {
      throw const FormatException('the page in the zip cannot be read');
    }
    if ((skin['type'] ?? 'image') == 'image') {
      final image = archive.findFile(skinFilename);
      if (image == null) {
        throw const FormatException('no $skinFilename skin image in the zip');
      }
      skinPath = p.join(work.path, skinFilename);
      File(skinPath).writeAsBytesSync(image.content, flush: true);
      skin['path'] = skinPath;
    }
    final store = TemplateStore(
      bundled: bundled,
      user: user,
      fileExists: (path) => File(path).existsSync(),
      context: p.context,
    );
    final maker = text('manufacturer');
    final model = text('model');
    final profile = text('rules_profile');
    for (var n = 1; ; n++) {
      final ref = TemplateRef(brand, computer, n == 1 ? page : '${page}_$n');
      final pageName = n == 1 ? name : '$name $n';
      final TemplateSave save;
      try {
        save = store.saveTemplateAs(
          layout,
          ref,
          pageName,
          skinSource: skinPath,
          manufacturer: maker.isEmpty ? null : maker,
          model: model.isEmpty ? null : model,
          rulesProfile: profile.isEmpty ? null : profile,
          overwriteUser: false,
        );
      } on TemplateExistsError {
        if (n >= 99) {
          rethrow;
        }
        continue;
      }
      await carryOutTemplateSave(
        save,
        readBytes: (path) async => File(path).readAsBytesSync(),
      );
      return '$computer / $pageName';
    }
  } finally {
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      // Swept at the next start.
    }
  }
}

/// One of the user's own overlay pages: where it lies in the templates
/// (brand, computer and page ids) and what the pages call it.
typedef UserOverlay = ({
  String brand,
  String computer,
  String page,
  String label,
});

/// The user's own pages in their templates folder [user], by label.
List<UserOverlay> userOverlays(TemplateFolder user) {
  final tree = TemplateTree(user: user);
  final found = <UserOverlay>[];
  tree.brands.forEach((brand, computers) {
    computers.forEach((computer, manifest) {
      final maker = '${manifest['manufacturer'] ?? brand}'.trim();
      final model = '${manifest['model'] ?? computer}'.trim();
      final pages = manifest['pages'];
      for (final page in pages is List<dynamic> ? pages : const <dynamic>[]) {
        if (page is Map<String, dynamic> && page['id'] is String) {
          found.add((
            brand: brand,
            computer: computer,
            page: page['id'] as String,
            label: [
              if (maker.isNotEmpty) maker,
              if (model.isNotEmpty) model,
              '${page['name'] ?? page['id']}',
            ].join(' · '),
          ));
        }
      }
    });
  });
  return found..sort((a, b) => a.label.compareTo(b.label));
}

/// Removes [overlay] from the templates folder [userDir]: the page's
/// folder, and its line in the computer's `manifest.json`; a computer
/// (and a brand) left with no page goes too. Throws a
/// [FileSystemException] when it cannot be removed.
void removeUserOverlay(String userDir, UserOverlay overlay) {
  for (final id in [overlay.brand, overlay.computer, overlay.page]) {
    // Ids are folder names, never a way out of the templates folder.
    if (id.isEmpty ||
        id == '.' ||
        id == '..' ||
        id.contains(RegExp(r'[/\\]'))) {
      throw FileSystemException('Not an overlay of this app', id);
    }
  }
  final computerDir = Directory(
    p.join(userDir, overlay.brand, overlay.computer),
  );
  final pageDir = Directory(p.join(computerDir.path, overlay.page));
  if (pageDir.existsSync()) {
    pageDir.deleteSync(recursive: true);
  }
  final manifestFile = File(p.join(computerDir.path, 'manifest.json'));
  // Unknown until the manifest is read: a manifest that cannot be read
  // takes no other page with it.
  var left = manifestFile.existsSync() ? 1 : 0;
  if (manifestFile.existsSync()) {
    try {
      final manifest = jsonDecode(manifestFile.readAsStringSync());
      final pages = manifest is Map<String, dynamic> ? manifest['pages'] : null;
      if (manifest is Map<String, dynamic> && pages is List<dynamic>) {
        pages.removeWhere(
          (page) => page is Map<String, dynamic> && page['id'] == overlay.page,
        );
        left = pages.length;
        manifestFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(manifest),
        );
      }
    } on FormatException {
      // A manifest that is none lists no page.
    }
  }
  if (left == 0 && computerDir.existsSync()) {
    computerDir.deleteSync(recursive: true);
    final brandDir = Directory(p.join(userDir, overlay.brand));
    if (brandDir.existsSync() && brandDir.listSync().isEmpty) {
      brandDir.deleteSync();
    }
  }
}
