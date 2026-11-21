/// Carrying out a template save (`core/hud/template_store.dart` gives what
/// to write, this writes it): each text file in one step (a temporary
/// file, then renamed), each skin image copied, or converted to an RGBA PNG
/// when it is not one. The skin's source may be a bundled asset, so its
/// bytes come through [readBytes].
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/template_store.dart';

/// Writes the files of [save]. Throws a [FileSystemException] when one
/// cannot be written and a [TemplateStoreError] when a skin cannot be read.
Future<void> carryOutTemplateSave(
  TemplateSave save, {
  required Future<Uint8List?> Function(String path) readBytes,
}) async {
  for (final op in save.ops) {
    Directory(p.dirname(op.path)).createSync(recursive: true);
    switch (op) {
      case WriteTextOp(:final path, :final text):
        final fresh = File('$path.new')..writeAsStringSync(text, flush: true);
        fresh.renameSync(path);
      case CopySkinOp(:final source, :final path, :final convert):
        final bytes = await readBytes(source);
        if (bytes == null) {
          throw TemplateStoreError('Could not read the skin image $source');
        }
        final png = convert ? await _asPng(bytes) : bytes;
        final fresh = File('$path.new')..writeAsBytesSync(png, flush: true);
        fresh.renameSync(path);
    }
  }
}

Future<Uint8List> _asPng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
