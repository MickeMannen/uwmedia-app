/// The older `.zip` HUD packages (Python `cli_main.py` with a `--layout`
/// ending in `.zip`, as the Overlay Generator's custom layout passes it):
/// a `hud_layout.json` with its skin image beside it. Python unpacks the
/// package into a working folder and reads the layout from there; here it
/// is read from the archive itself, with the same paths.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';

/// The layout file in a package.
const packageLayoutName = 'hud_layout.json';

/// Whether [path] names a HUD package rather than a layout file.
bool isLayoutPackage(String path) => p.extension(path).toLowerCase() == '.zip';

/// The layout of the package at [zipPath] with its skin. Throws a
/// [FormatException] with Python's message when there is no such file or
/// no layout in it, or when it is no zip.
HudLayerSource layerOfPackage(String zipPath) {
  final file = File(zipPath);
  if (!file.existsSync()) {
    throw FormatException('HUD package $zipPath not found.');
  }
  final Archive archive;
  try {
    final bytes = file.readAsBytesSync();
    // The decoder gives an empty archive for what is no zip at all.
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const FormatException('not a zip file');
    }
    archive = ZipDecoder().decodeBytes(bytes);
  } on FileSystemException catch (e) {
    throw FormatException(
      'Could not read HUD package ${p.basename(zipPath)}: ${e.message}',
    );
  } on FormatException catch (e) {
    throw FormatException(
      'Could not read HUD package ${p.basename(zipPath)}: ${e.message}',
    );
  } on Object catch (e) {
    throw FormatException(
      'Could not read HUD package ${p.basename(zipPath)}: $e',
    );
  }
  // The package's files by their path inside it, as unpacked (Python's
  // extractall leaves out ".." and a leading "/").
  final files = <String, ArchiveFile>{
    for (final entry in archive.files)
      if (entry.isFile) _inside(entry.name): entry,
  };
  if (!files.containsKey(packageLayoutName)) {
    throw const FormatException('HUD package missing $packageLayoutName');
  }
  Uint8List bytesOf(String path) {
    final entry = files[_inside(path)];
    if (entry == null) {
      throw FormatException('HUD package has no $path');
    }
    return entry.content;
  }

  final layout = loadLayoutFile(
    packageLayoutName,
    (path) => utf8.decode(bytesOf(path)),
  );
  final skin = layout['hud_skin'];
  final skinPath = skin is Map ? skin['path'] : null;
  Uint8List? bytes;
  if (skinPath is String && skinPath.isNotEmpty) {
    if (p.isAbsolute(skinPath)) {
      // A skin outside the package, as Python would find it.
      final outside = File(skinPath);
      bytes = outside.existsSync() ? outside.readAsBytesSync() : null;
    } else {
      bytes = files[_inside(skinPath)]?.content;
    }
  }
  return HudLayerSource(layout, skinBytes: bytes);
}

String _inside(String name) => p.posix
    .split(p.posix.normalize(name.replaceAll(r'\', '/')))
    .where((part) => part != '..' && part != '/' && part != '.')
    .join('/');
