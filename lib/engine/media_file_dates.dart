/// A photo's or video's date tags read and written by the app's own
/// readers and writers (no exiftool): JPEG and HEIC photos through their
/// EXIF block, MP4 and MOV videos through their headers and keys. The tags
/// come under exiftool's names, so the date logic reads them as it reads
/// exiftool's answer. For the phones, where every change goes into a
/// corrected copy (owner, 2026-11-13).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/metadata/heic_exif.dart';
import 'package:uwmedia_app/core/metadata/jpeg_exif.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/mp4_dates.dart';
import 'package:uwmedia_app/engine/mp4_file.dart';

const _jpeg = {'.jpg', '.jpeg'};
const _heic = {'.heic', '.heif'};
const _video = {'.mp4', '.mov', '.m4v'};

/// The file types this reads and writes.
const mediaDateExtensions = {..._jpeg, ..._heic, ..._video};

/// Whether [path] is a photo or video this reads and writes.
bool hasMediaDates(String path) =>
    mediaDateExtensions.contains(p.extension(path).toLowerCase());

/// The date tags of the file at [path]. Throws a [FormatException] for a
/// file that is not what its name says, and an [ArgumentError] for a type
/// this does not read.
MediaTags readFileDates(String path) {
  final ext = p.extension(path).toLowerCase();
  if (_jpeg.contains(ext)) {
    return readJpegDates(File(path).readAsBytesSync());
  }
  if (_heic.contains(ext)) {
    return readHeicDates(File(path).readAsBytesSync());
  }
  if (_video.contains(ext)) {
    final file = File(path).openSync();
    try {
      return Mp4Movie.read(FileBytes(file)).tags;
    } on Mp4Exception catch (e) {
      throw FormatException(e.message);
    } finally {
      file.closeSync();
    }
  }
  throw ArgumentError.value(path, 'path', 'Not a photo or video read here');
}

/// A copy of the file at [path] at [output] with [tags] written (the ones
/// that do not belong to its type left out: EXIF ones on a video,
/// QuickTime ones on a photo); the source as it was.
void writeFileDatesCopy(String path, Map<String, String> tags, String output) {
  final ext = p.extension(path).toLowerCase();
  if (_video.contains(ext)) {
    writeMp4Dates(path, {
      for (final MapEntry(:key, :value) in tags.entries)
        if (key.startsWith('QuickTime:')) key: value,
    }, output: output);
    return;
  }
  final photoTags = {
    for (final MapEntry(:key, :value) in tags.entries)
      if (jpegDateTags.containsKey(key)) key: value,
  };
  final bytes = File(path).readAsBytesSync();
  final written = _heic.contains(ext)
      ? writeHeicDates(bytes, photoTags)
      : _jpeg.contains(ext)
      ? writeJpegDates(bytes, photoTags)
      : throw ArgumentError.value(path, 'path', 'Not a photo written here');
  final fresh = File('$output.new')..writeAsBytesSync(written, flush: true);
  fresh.renameSync(output);
}
