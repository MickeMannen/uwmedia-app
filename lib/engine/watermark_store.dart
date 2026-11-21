/// The diver's watermarks as the app keeps them (spec §10.45): the list
/// in the settings (`watermarks`), each picture as a copy in a folder of
/// the app's data, so that moving the picked file does not break a run.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';

/// The settings key of the list, and the folder of the pictures in the
/// app's data folder.
const watermarksKey = 'watermarks';
const watermarksFolder = 'watermarks';

/// The settings field of the watermarks the runs use: a list of names
/// (before 2026-11-16 one name, '' for none; still read).
const watermarkSelectField = 'watermark_select';

/// The picture types a watermark can be.
const watermarkPictureTypes = ['.png', '.jpg', '.jpeg'];

class WatermarkStore {
  WatermarkStore(this.config, this.folder);

  final ConfigStore config;

  /// Where the pictures are kept (created when needed).
  final Directory folder;

  /// The watermarks, in the order they were added.
  List<Watermark> list() {
    final kept = config.settings()[watermarksKey];
    return [
      if (kept is List)
        for (final entry in kept) ?Watermark.fromJson(entry),
    ];
  }

  Watermark? named(String name) =>
      list().where((mark) => mark.name == name).firstOrNull;

  void _save(List<Watermark> marks) => config.updateSettings({
    watermarksKey: [for (final mark in marks) mark.toJson()],
  });

  /// A name not in use, from [wanted] ("Logo", "Logo 2", ...).
  String freeName(String wanted) {
    final base = wanted.trim().isEmpty ? 'Watermark' : wanted.trim();
    final taken = {for (final mark in list()) mark.name};
    var name = base;
    for (var i = 2; taken.contains(name); i++) {
      name = '$base $i';
    }
    return name;
  }

  /// A picture watermark from the file at [path], copied into the app.
  /// Throws a [FormatException] for a file that is no PNG or JPEG.
  Watermark addPicture(String path) {
    final type = p.extension(path).toLowerCase();
    final bytes = File(path).readAsBytesSync();
    if (!watermarkPictureTypes.contains(type) || imageSize(bytes) == null) {
      throw FormatException('${p.basename(path)} is not a PNG or JPEG picture');
    }
    folder.createSync(recursive: true);
    var file = p.basename(path);
    for (var i = 2; File(p.join(folder.path, file)).existsSync(); i++) {
      file = '${p.basenameWithoutExtension(path)}_$i$type';
    }
    File(p.join(folder.path, file)).writeAsBytesSync(bytes, flush: true);
    final mark = Watermark(
      name: freeName(p.basenameWithoutExtension(path)),
      picture: file,
    );
    _save([...list(), mark]);
    return mark;
  }

  /// A text watermark saying [text].
  Watermark addText(String text) {
    final mark = Watermark(name: freeName(text), text: text.trim());
    _save([...list(), mark]);
    return mark;
  }

  /// [changed] in the place of the watermark called [name]. A new name
  /// that another one has is made free ("Logo 2").
  Watermark update(String name, Watermark changed) {
    final marks = list();
    final index = marks.indexWhere((mark) => mark.name == name);
    if (index < 0) {
      return changed;
    }
    var kept = changed;
    final wanted = changed.name.trim();
    if (wanted.isEmpty) {
      kept = changed.copyWith(name: name);
    } else if (wanted != name) {
      marks.removeAt(index);
      _save(marks);
      kept = changed.copyWith(name: freeName(wanted));
      marks.insert(index, kept);
      _save(marks);
      final chosen = selectedNames;
      if (chosen.contains(name)) {
        config.setField(watermarkSelectField, [
          for (final one in chosen) one == name ? kept.name : one,
        ]);
      }
      return kept;
    }
    marks[index] = kept;
    _save(marks);
    return kept;
  }

  /// Takes the watermark called [name] away, its picture too.
  void remove(String name) {
    final marks = list();
    final gone = marks.where((mark) => mark.name == name).toList();
    marks.removeWhere((mark) => mark.name == name);
    _save(marks);
    for (final mark in gone) {
      final picture = mark.picture;
      if (picture != null && !marks.any((m) => m.picture == picture)) {
        try {
          File(p.join(folder.path, picture)).deleteSync();
        } on FileSystemException {
          // Not there.
        }
      }
    }
    if (selectedNames.contains(name)) {
      select(name, false);
    }
  }

  /// The names kept as chosen, whether or not each is still there.
  List<String> get selectedNames {
    final kept = config.fields()[watermarkSelectField];
    return kept is String
        ? [if (kept.isNotEmpty) kept]
        : [
            if (kept is List)
              for (final name in kept)
                if (name is String) name,
          ];
  }

  /// The watermarks the runs use, in the list's order; those that are
  /// gone left out.
  List<Watermark> get selected {
    final chosen = selectedNames.toSet();
    return [
      for (final mark in list())
        if (chosen.contains(mark.name)) mark,
    ];
  }

  /// Puts the watermark called [name] on the runs, or takes it off.
  void select(String name, bool on) {
    final chosen = selectedNames..remove(name);
    config.setField(watermarkSelectField, [...chosen, if (on) name]);
  }

  /// The picture of [mark] as the app keeps it; `null` for a text, or a
  /// picture that is gone.
  Uint8List? pictureBytes(Watermark mark) {
    final picture = mark.picture;
    if (picture == null) {
      return null;
    }
    try {
      return File(p.join(folder.path, picture)).readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  /// [mark] as a layer of a run, drawn on every file by the place it has
  /// for the frame's shape; `null` when its picture is gone or cannot be
  /// read.
  HudLayerSource? layerOf(Watermark mark) {
    final bytes = pictureBytes(mark);
    if (mark.isPicture && bytes == null) {
      return null;
    }
    return watermarkLayer(
      mark,
      pictureBytes: bytes,
      skinPath: mark.picture ?? 'watermark',
    );
  }

  /// The layers of the watermarks the runs use.
  List<HudLayerSource> selectedLayers() => [
    for (final mark in selected) ?layerOf(mark),
  ];
}

/// [mark] as a layer drawn on every file: on each frame by the layout of
/// that frame's shape ([watermarkLayout]). `null` for a picture whose
/// [pictureBytes] are no picture.
HudLayerSource? watermarkLayer(
  Watermark mark, {
  Uint8List? pictureBytes,
  String skinPath = 'watermark',
}) {
  final pictureSize = pictureBytes == null ? null : imageSize(pictureBytes);
  HudLayerSource? on(int frameW, int frameH, {bool resolved = false}) {
    final layout = watermarkLayout(
      mark,
      pictureSize: pictureSize,
      skinPath: skinPath,
      frameW: frameW,
      frameH: frameH,
    );
    return layout == null
        ? null
        : HudLayerSource(
            layout,
            skinBytes: pictureBytes,
            always: true,
            forFrame: resolved ? null : (w, h) => on(w, h, resolved: true)!,
          );
  }

  return on(1920, 1080);
}
