/// A video's dates written on disk with the pure-Dart MP4 writer
/// (`core/metadata/mp4_dates.dart`): the file read by position (a film is
/// never loaded whole), then changed where it lies when nothing moves, or
/// written anew segment by segment when the picture data moves. For the
/// phones (no exiftool) and wherever only the dates change.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:uwmedia_app/core/metadata/mp4_dates.dart';

/// A [ByteSource] over a file open for reading.
class FileBytes implements ByteSource {
  FileBytes(this.file) : length = file.lengthSync();

  final RandomAccessFile file;

  @override
  final int length;

  @override
  Uint8List read(int offset, int count) {
    file.setPositionSync(offset);
    final bytes = file.readSync(count);
    if (bytes.length != count) {
      throw FileSystemException('Read past the end', file.path);
    }
    return bytes;
  }
}

/// How a date change was put on disk.
enum Mp4WriteMode {
  /// Nothing to change.
  unchanged,

  /// Changed where the file lies (only the dates' bytes written).
  patched,

  /// Written anew (the picture data moved).
  rewritten,
}

const _chunk = 1 << 20;

/// [tags] (as [Mp4Movie.write] takes them) written to the video at
/// [path], or into a new file at [output] with the source left as it is.
/// Returns how, and the tags that were not written. A rewritten file is
/// put together under `<target>.new` and then renamed over the target, so
/// a failure leaves the target as it was.
({Mp4WriteMode mode, List<String> ignored}) writeMp4Dates(
  String path,
  Map<String, String> tags, {
  String? output,
}) {
  final source = File(path).openSync();
  final Mp4Rewrite rewrite;
  final List<(int, Uint8List)> patches;
  try {
    final bytes = FileBytes(source);
    rewrite = Mp4Movie.read(bytes).write(tags);
    patches = rewrite.patches;
    final unchanged =
        rewrite.keepsOffsets &&
        rewrite.length == bytes.length &&
        patches.every((patch) {
          final (at, data) = patch;
          final old = bytes.read(at, data.length);
          for (var i = 0; i < data.length; i++) {
            if (old[i] != data[i]) {
              return false;
            }
          }
          return true;
        });
    if (unchanged) {
      if (output != null) {
        File(path).copySync(output);
      }
      return (mode: Mp4WriteMode.unchanged, ignored: rewrite.ignored);
    }
    if (output == null && rewrite.keepsOffsets) {
      source.closeSync();
      // The same file, written where the dates are.
      final target = File(path).openSync(mode: FileMode.append);
      try {
        for (final (at, data) in patches) {
          target
            ..setPositionSync(at)
            ..writeFromSync(data);
        }
        target
          ..truncateSync(rewrite.length)
          ..flushSync();
      } finally {
        target.closeSync();
      }
      return (mode: Mp4WriteMode.patched, ignored: rewrite.ignored);
    }
    final target = output ?? path;
    final fresh = File('$target.new');
    final sink = fresh.openSync(mode: FileMode.write);
    try {
      for (final segment in rewrite.segments) {
        switch (segment) {
          case Mp4Copy(:final offset, :final length):
            for (var done = 0; done < length; done += _chunk) {
              final count = length - done < _chunk ? length - done : _chunk;
              sink.writeFromSync(bytes.read(offset + done, count));
            }
          case Mp4Data(bytes: final data):
            sink.writeFromSync(data);
        }
      }
      sink.flushSync();
    } catch (_) {
      sink.closeSync();
      fresh.deleteSync();
      rethrow;
    }
    sink.closeSync();
    source.closeSync();
    fresh.renameSync(target);
    return (mode: Mp4WriteMode.rewritten, ignored: rewrite.ignored);
  } finally {
    try {
      source.closeSync();
    } on FileSystemException {
      // Closed above.
    }
  }
}
