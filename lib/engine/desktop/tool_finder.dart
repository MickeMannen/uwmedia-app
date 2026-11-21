/// Finding the ffmpeg, ffprobe and exiftool to run on the desktop (Python
/// `utils/tool_paths.py` and `utils/dependency_check.py`): the path set
/// on the Advanced page, else the copy bundled with the app, else the
/// one on the PATH, else the usual install folders of the system. A
/// candidate counts only when it runs.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';

const toolFfmpeg = 'ffmpeg';
const toolFfprobe = 'ffprobe';
const toolExiftool = 'exiftool';
const requiredTools = [toolFfmpeg, toolFfprobe, toolExiftool];

/// The settings keys of the paths set on the Advanced page.
const ffmpegPathKey = 'ffmpeg_path';
const exiftoolPathKey = 'exiftool_path';

/// How long a tool may take to answer its version. A bundled macOS binary
/// that has never run takes about a second for its first start (the
/// system's one-time scan) against 15 ms afterwards, and a fresh install
/// is when that is paid, so the bundled copy gets real headroom.
const versionTimeout = Duration(seconds: 3);
const bundledVersionTimeout = Duration(seconds: 15);

/// The file name of [tool] on [os].
String executableName(String tool, EngineOs os) =>
    os == EngineOs.windows ? '$tool.exe' : tool;

/// The arguments that make [tool] print its version and end.
List<String> versionArgs(String tool) => [
  tool == toolExiftool ? '-ver' : '-version',
];

/// The folders an install of the tools usually lies in on [os], in the
/// order they are tried. [wingetDirs] are the folders under WinGet's
/// package folder that hold an ffmpeg or exiftool executable.
List<String> toolSearchDirs(
  EngineOs os,
  Map<String, String> env, {
  List<String> wingetDirs = const [],
}) {
  switch (os) {
    case EngineOs.macos:
      final home = env['HOME'] ?? '';
      return [
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/opt/local/bin',
        p.posix.join(home, 'bin'),
        p.posix.join(home, '.local/bin'),
      ];
    case EngineOs.windows:
      final home = env['USERPROFILE'] ?? '';
      final programFiles = env['PROGRAMFILES'] ?? r'C:\Program Files';
      final programFilesX86 =
          env['PROGRAMFILES(X86)'] ?? r'C:\Program Files (x86)';
      final programData = env['PROGRAMDATA'] ?? r'C:\ProgramData';
      final w = p.windows;
      return [
        r'C:\ffmpeg\bin',
        w.join(programFiles, 'ffmpeg', 'bin'),
        w.join(programFilesX86, 'ffmpeg', 'bin'),
        w.join(programData, 'chocolatey', 'bin'),
        w.join(home, 'ffmpeg', 'bin'),
        r'C:\exiftool',
        r'C:\Windows',
        w.join(programFiles, 'exiftool'),
        w.join(home, 'exiftool'),
        ...wingetDirs,
      ];
    case EngineOs.linux:
      final home = env['HOME'] ?? '';
      return [
        '/usr/bin',
        '/usr/local/bin',
        '/usr/bin/vendor_perl',
        '/snap/bin',
        p.posix.join(home, '.local/bin'),
      ];
  }
}

/// Where WinGet keeps its packages.
String wingetPackagesDir(Map<String, String> env) => p.windows.join(
  env['LOCALAPPDATA'] ?? r'C:\Users\Default\AppData\Local',
  'Microsoft',
  'WinGet',
  'Packages',
);

/// What to tell the user when [missing] tools were not found: how to
/// install them on [os].
String installationInstructions(List<String> missing, EngineOs os) {
  final ffmpeg = missing.contains(toolFfmpeg) || missing.contains(toolFfprobe);
  final exiftool = missing.contains(toolExiftool);
  final lines = [
    'Missing required external dependencies: '
        '${missing.map((m) => "'$m'").join(', ')}',
    '',
    'To resolve this issue, please install the missing software for your '
        'system:',
    '',
  ];
  switch (os) {
    case EngineOs.macos:
      lines.addAll([
        '--- macOS Installation ---',
        'Option 1: Using Homebrew (Recommended)',
        if (ffmpeg) '  brew install ffmpeg',
        if (exiftool) '  brew install exiftool',
        '',
        'Option 2: Manual Download',
        if (ffmpeg) ...[
          '  • FFmpeg/FFprobe: Download static binaries from '
              'https://evermeet.cx/ffmpeg/ or '
              'https://ffmpeg.org/download.html',
          "    Extract and copy 'ffmpeg' and 'ffprobe' to /usr/local/bin "
              'or /opt/homebrew/bin',
        ],
        if (exiftool)
          '  • ExifTool: Download the MacOS package from '
              'https://exiftool.org/',
      ]);
    case EngineOs.windows:
      lines.addAll([
        '--- Windows Installation ---',
        'Option 1: Using Package Manager (winget / chocolatey)',
        if (ffmpeg) '  winget install FFmpeg   (or: choco install ffmpeg)',
        if (exiftool)
          '  winget install OliverBetz.ExifTool   (or: choco install '
              'exiftool)',
        '',
        'Option 2: Manual Download',
        if (ffmpeg) ...[
          '  • FFmpeg: Download build from '
              'https://www.gyan.dev/ffmpeg/builds/',
          "    Extract zip and add the 'bin' folder to your System PATH.",
        ],
        if (exiftool) ...[
          '  • ExifTool: Download Windows executable from '
              'https://exiftool.org/',
          "    Rename 'exiftool(-k).exe' to 'exiftool.exe' and add to "
              r'System PATH (or C:\Windows).',
        ],
      ]);
    case EngineOs.linux:
      String packages(String ffmpegName, String exiftoolName) =>
          [if (ffmpeg) ffmpegName, if (exiftool) exiftoolName].join(' ');
      lines.addAll([
        '--- Linux Installation ---',
        'Ubuntu / Debian:',
        '  sudo apt update && sudo apt install '
            '${packages('ffmpeg', 'libimage-exiftool-perl')}',
        '',
        'Fedora / RHEL:',
        '  sudo dnf install ${packages('ffmpeg', 'perl-Image-ExifTool')}',
        '',
        'Arch Linux:',
        '  sudo pacman -S ${packages('ffmpeg', 'perl-image-exiftool')}',
      ]);
  }
  lines.addAll([
    '',
    'After installing the missing dependencies, please restart the '
        'application.',
  ]);
  return lines.join('\n');
}

/// The system this process runs on, for the engine.
EngineOs currentEngineOs() => Platform.isMacOS
    ? EngineOs.macos
    : Platform.isWindows
    ? EngineOs.windows
    : EngineOs.linux;

/// Where the tools shipped with the app lie, for the app whose executable
/// is [executable] (spec §13.2): `Contents/Resources/bin` of the bundle on
/// macOS (as in the Python app's), a `bin` folder beside the executable
/// on Windows and Linux. The folder holds `ffmpeg`, `ffprobe` and
/// `exiftool` (with exiftool's `lib` beside it).
String bundledToolsDir(EngineOs os, String executable) {
  final context = os == EngineOs.windows ? p.windows : p.posix;
  final folder = context.dirname(executable);
  return os == EngineOs.macos
      ? context.join(context.dirname(folder), 'Resources', 'bin')
      : context.join(folder, 'bin');
}

/// Finds the tools on this machine. What it asks of the machine is in
/// the three functions, so that a test can answer for it.
class ToolFinder {
  ToolFinder({
    required this.os,
    required this.env,
    this.bundledBinDir,
    bool Function(String path)? fileExists,
    Future<bool> Function(String path, List<String> args, Duration timeout)?
    runs,
    this.wingetDirs,
  }) : fileExists = fileExists ?? ((path) => File(path).existsSync()),
       runs = runs ?? _runs;

  /// The finder for this machine. [bundledBinDir] is the folder of the
  /// tools the app ships with; by default [bundledToolsDir] of the running
  /// app, when the package has that folder.
  factory ToolFinder.forThisMachine({String? bundledBinDir}) {
    final os = currentEngineOs();
    var bundled = bundledBinDir;
    if (bundled == null) {
      final own = bundledToolsDir(os, Platform.resolvedExecutable);
      if (Directory(own).existsSync()) {
        bundled = own;
      }
    }
    return ToolFinder(
      os: os,
      env: Platform.environment,
      bundledBinDir: bundled,
    );
  }

  final EngineOs os;
  final Map<String, String> env;

  /// The folder of the tools bundled with the app; `null` when run
  /// without them (then the PATH and the system's folders are all there
  /// is).
  final String? bundledBinDir;
  final bool Function(String path) fileExists;

  /// Whether the executable at a path runs and ends well with the given
  /// arguments within the time.
  final Future<bool> Function(String path, List<String> args, Duration timeout)
  runs;

  /// The folders under WinGet's packages that hold one of the tools; the
  /// machine's own when not given.
  final List<String> Function()? wingetDirs;

  static Future<bool> _runs(
    String path,
    List<String> args,
    Duration timeout,
  ) async => (await runCapture(path, args, timeout: timeout))?.exitCode == 0;

  p.Context get _context => os == EngineOs.windows ? p.windows : p.posix;

  List<String> _winget() {
    final given = wingetDirs;
    if (given != null) {
      return given();
    }
    if (os != EngineOs.windows) {
      return const [];
    }
    final root = Directory(wingetPackagesDir(env));
    if (!root.existsSync()) {
      return const [];
    }
    final found = <String>[];
    try {
      for (final entry in root.listSync(recursive: true, followLinks: false)) {
        final name = p.basename(entry.path).toLowerCase();
        if (entry is File &&
            name.endsWith('.exe') &&
            (name.startsWith('ffmpeg') || name.startsWith('exiftool'))) {
          found.add(entry.parent.path);
        }
      }
    } on FileSystemException {
      // What was found before a folder that cannot be read still counts.
    }
    return found;
  }

  Future<bool> _valid(String path, String tool, [Duration? timeout]) =>
      runs(path, versionArgs(tool), timeout ?? versionTimeout);

  /// The folders of the PATH, in order.
  List<String> get _pathDirs => (env['PATH'] ?? env['Path'] ?? '')
      .split(os == EngineOs.windows ? ';' : ':')
      .where((dir) => dir.isNotEmpty)
      .toList();

  /// The [tool] to run, or `null` when none was found: the bundled copy
  /// (so that the app runs the ffmpeg it ships with, not whichever a user
  /// happens to have), then the PATH, then for ffprobe the folder ffmpeg
  /// was found in ([knownFfmpegDir]), then the system's usual folders.
  Future<String?> find(String tool, {String? knownFfmpegDir}) async {
    final name = executableName(tool, os);
    final bundled = bundledBinDir;
    if (bundled != null) {
      final candidate = _context.join(bundled, name);
      if (fileExists(candidate) &&
          await _valid(candidate, tool, bundledVersionTimeout)) {
        return candidate;
      }
    }
    for (final dir in _pathDirs) {
      final candidate = _context.join(dir, name);
      if (fileExists(candidate)) {
        // The first on the PATH is the one a shell would run; when it
        // does not run, the PATH has no answer.
        if (await _valid(candidate, tool)) {
          return candidate;
        }
        break;
      }
    }
    if (tool == toolFfprobe && knownFfmpegDir != null) {
      final candidate = _context.join(knownFfmpegDir, name);
      if (fileExists(candidate) && await _valid(candidate, tool)) {
        return candidate;
      }
    }
    for (final dir in toolSearchDirs(os, env, wingetDirs: _winget())) {
      final candidate = _context.join(dir, name);
      if (fileExists(candidate) && await _valid(candidate, tool)) {
        return candidate;
      }
    }
    return null;
  }

  /// The tool at the path the settings name under [settingsKey] when that
  /// file is still there, else the one [find] finds.
  Future<String?> resolve(
    String tool,
    Map<String, dynamic> settings,
    String settingsKey, {
    String? knownFfmpegDir,
  }) async {
    final override = settings[settingsKey];
    if (override is String && override.isNotEmpty && fileExists(override)) {
      return override;
    }
    return find(tool, knownFfmpegDir: knownFfmpegDir);
  }

  /// ffmpeg, ffprobe (which has no setting of its own: it is expected
  /// beside ffmpeg) and exiftool by name; a tool that was not found is
  /// missing from the map.
  Future<Map<String, String>> findAll(Map<String, dynamic> settings) async {
    final found = <String, String>{};
    final ffmpeg = await resolve(toolFfmpeg, settings, ffmpegPathKey);
    if (ffmpeg != null) {
      found[toolFfmpeg] = ffmpeg;
    }
    final ffprobe = await find(
      toolFfprobe,
      knownFfmpegDir: ffmpeg == null ? null : _context.dirname(ffmpeg),
    );
    if (ffprobe != null) {
      found[toolFfprobe] = ffprobe;
    }
    final exiftool = await resolve(toolExiftool, settings, exiftoolPathKey);
    if (exiftool != null) {
      found[toolExiftool] = exiftool;
    }
    return found;
  }

  /// Whether the file at [path] is an ffmpeg that runs.
  Future<bool> isValidFfmpeg(String? path) async =>
      path != null &&
      path.isNotEmpty &&
      fileExists(path) &&
      await _valid(path, toolFfmpeg);

  /// Whether the file at [path] is an exiftool that runs.
  Future<bool> isValidExiftool(String? path) async =>
      path != null &&
      path.isNotEmpty &&
      fileExists(path) &&
      await _valid(path, toolExiftool);
}
