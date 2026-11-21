import 'dart:io';

/// Whether the command-line tool [name] is installed (on the PATH): the
/// tests that run ffmpeg, ffprobe or exiftool skip themselves without it.
bool hasTool(String name) {
  try {
    return Process.runSync(Platform.isWindows ? 'where' : 'which', [
          name,
        ]).exitCode ==
        0;
  } on ProcessException {
    return false;
  }
}

/// Whether `chmod 000` keeps this process out of a file: not on Windows,
/// and not for root, who reads it anyway (the CI's Linux container). The
/// tests of an unreadable file leave that part out without it.
final bool canLockFiles =
    !Platform.isWindows &&
    (Process.runSync('id', ['-u']).stdout as String).trim() != '0';
