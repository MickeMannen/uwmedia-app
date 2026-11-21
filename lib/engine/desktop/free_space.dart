/// The free space on a computer's disk, for a run to check before it
/// writes a large working file (spec §10.88).
library;

import 'dart:io';

/// The bytes the user may still write on the disk [dir] is on, or `null`
/// when that cannot be told (no `df`, a network share on Windows): the
/// caller then goes on as if there were room.
Future<int?> freeBytes(String dir) async {
  try {
    if (Platform.isWindows) {
      final quoted = dir.replaceAll("'", "''");
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot('
            "'$quoted')).AvailableFreeSpace",
      ]);
      if (result.exitCode != 0) {
        return null;
      }
      return int.tryParse((result.stdout as String).trim());
    }
    final result = await Process.run('df', ['-Pk', dir]);
    if (result.exitCode != 0) {
      return null;
    }
    return dfAvailableBytes(result.stdout as String);
  } on ProcessException {
    return null;
  }
}

/// The available bytes in the output of `df -Pk` (POSIX: the
/// filesystem, its 1024-blocks, used, available and capacity, then where
/// it is mounted; a name or a mount with spaces in it is passed over).
int? dfAvailableBytes(String output) {
  final lines = output.trim().split('\n');
  if (lines.length < 2) {
    return null;
  }
  final columns = RegExp(r'\s(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s')
      .firstMatch('${lines.last} ');
  final kilobytes = int.tryParse(columns?.group(3) ?? '');
  return kilobytes == null ? null : kilobytes * 1024;
}

/// [bytes] for a person, in GB with one decimal (as the Convert page).
String gigabytesText(int bytes) =>
    '${(bytes / 1000000000).toStringAsFixed(1)} GB';
