/// exiftool on the desktop (Python `metadata/exif.py`'s `MetadataHandler`
/// on pyexiftool): reading a file's tags, writing tags and carrying a
/// source's metadata over to its output. What is asked is in
/// `core/metadata/exiftool_commands.dart`.
///
/// The arguments are handed to exiftool as an argument file on its
/// standard input (`-@ -`), one a line in UTF-8, as pyexiftool does, so
/// that a name outside the system's code page arrives whole. One process
/// per command.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uwmedia_app/core/metadata/exiftool_commands.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/file_times.dart';

export 'package:uwmedia_app/engine/file_times.dart' show fileModified;

const exiftoolMissingMessage =
    'ExifTool executable not found. Configure its location on the Settings '
    "page, or install ExifTool and ensure it's on your PATH.";

/// The exiftool at [executable].
class Exiftool {
  Exiftool(this.executable);

  final String executable;

  /// Runs exiftool with [args]; `null` when it could not be started.
  Future<RunResult?> execute(List<String> args) async {
    for (final arg in args) {
      if (arg.contains('\n') || arg.contains('\r')) {
        throw EngineException('A line break in an exiftool argument: $arg');
      }
    }
    final Process process;
    try {
      process = await Process.start(executable, [
        // The names in the argument file are UTF-8; Windows would take
        // them for its own code page (elsewhere they are passed as bytes).
        if (Platform.isWindows) ...['-charset', 'filename=utf8'],
        '-@',
        '-',
      ]);
    } on ProcessException {
      return null;
    }
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      process.stdin.add(utf8.encode('${args.join('\n')}\n'));
      await process.stdin.close();
    } on IOException {
      // exiftool ended before it had read everything; its exit code says
      // why.
    }
    String stdout;
    try {
      stdout = await out;
    } on FormatException {
      stdout = '';
    }
    return (
      exitCode: await process.exitCode,
      stdout: stdout,
      stderr: await err,
    );
  }

  /// Every tag of the file, by group and name; `null` when exiftool
  /// cannot read it.
  Future<MediaTags?> metadata(String path) async {
    final result = await execute(exiftoolReadArgs(path));
    return result == null || result.exitCode != 0
        ? null
        : parseExiftoolJson(result.stdout);
  }

  /// The values of [names] as text; empty for a tag the file does not
  /// have, and for every tag when the file cannot be read.
  Future<Map<String, String>> tags(String path, List<String> names) async {
    final result = await execute(exiftoolReadArgs(path, names));
    return namedTags(
      result == null || result.exitCode != 0
          ? null
          : parseExiftoolJson(result.stdout),
      names,
    );
  }

  /// Writes [tags] into the file, in place. Throws an [EngineException]
  /// with what exiftool wrote when it refuses.
  Future<void> setTags(String path, Map<String, Object?> tags) async {
    if (tags.isEmpty) {
      return;
    }
    final result = await execute(exiftoolSetTagsArgs(path, tags));
    if (result == null) {
      throw const EngineException(exiftoolMissingMessage);
    }
    if (result.exitCode != 0) {
      throw EngineException(
        'Error writing tags',
        exitCode: result.exitCode,
        output: result.stderr.trim(),
      );
    }
  }

  /// Carries [source]'s metadata over to [dest] (Python `copy_all`):
  /// every tag, the local creation date with its timezone
  /// ([forcedTzMinutes], else the source's own), the user's
  /// [customTags] and Sony's XML tags as XMP. Gives what exiftool said
  /// that was not "updated": warnings, and errors of the steps, which do
  /// not stop the ones after (a tag exiftool cannot write does not undo
  /// the copy). Throws an [EngineException] when exiftool cannot be run,
  /// and a [FormatException] when a timezone is to be written and the
  /// source has no date.
  Future<List<String>> copyAll(
    String source,
    String dest, {
    int? forcedTzMinutes,
    List<String>? customTags,
  }) async {
    final meta = await metadata(source);
    final messages = <String>[];
    for (final command in copyAllCommands(
      source: source,
      dest: dest,
      meta: meta,
      forcedTzMinutes: forcedTzMinutes,
      fileModified: fileModified(source),
      customTags: customTags,
    )) {
      final result = await execute(command);
      if (result == null) {
        throw const EngineException(exiftoolMissingMessage);
      }
      messages.addAll(
        const LineSplitter()
            .convert(result.stderr)
            .where((line) => line.trim().isNotEmpty),
      );
    }
    return messages;
  }
}
