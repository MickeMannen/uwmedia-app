/// A comparison's mask and divider line (spec §10.94) written as the
/// pictures a video engine reads.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';

/// The names of the two pictures in a run's working folder.
const compareMaskFileName = 'compare_mask.png';
const compareLineFileName = 'compare_line.png';

Future<void> _writePng(
  String path,
  Uint8List rgba,
  int width,
  int height,
) async {
  final image = await hudSkinImage(rgba, width, height);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File(path).writeAsBytesSync(png!.buffer.asUint8List(), flush: true);
}

/// Writes [edge]'s mask and its line into [dir] as PNGs of the frame's
/// size; their paths, the mask first.
Future<List<String>> writeComparePictures(
  CompareEdge edge,
  Directory dir,
) async {
  final mask = p.join(dir.path, compareMaskFileName);
  final line = p.join(dir.path, compareLineFileName);
  await _writePng(mask, compareMask(edge), edge.width, edge.height);
  await _writePng(line, compareLine(edge), edge.width, edge.height);
  return [mask, line];
}
