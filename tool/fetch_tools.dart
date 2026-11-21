// Fetches the ffmpeg, ffprobe and exiftool the desktop builds ship with
// (spec §13.2) and lays them out in a folder as the app looks for them
// (`bundledToolsDir` in lib/engine/desktop/tool_finder.dart). The files
// are this repo's "deps" release on GitHub (until 2026-11-19 the Python
// app's; tool/DEPS_RELEASE.md says how the release is made), each checked
// against the sha256 in assets/licenses/BINARY_MANIFEST.json before it is
// used.
//
//   dart run tool/fetch_tools.dart <macos|windows|linux> <bin folder>
//
// Downloads are kept in build/tools_cache/ (UWMEDIA_TOOLS_CACHE), so a
// second run fetches nothing. UWMEDIA_DEPS_URL names another place than
// the release to download from. `tool/bundle_tools.sh` runs this for a
// built app.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const manifestPath = 'assets/licenses/BINARY_MANIFEST.json';
const depsRepo = 'MickeMannen/uwmedia-app';

Future<void> main(List<String> args) async {
  if (args.length != 2 ||
      !const ['macos', 'windows', 'linux'].contains(args[0])) {
    stderr.writeln(
      'usage: dart run tool/fetch_tools.dart <macos|windows|linux> '
      '<bin folder>',
    );
    exit(64);
  }
  final os = args[0];
  final bin = Directory(args[1])..createSync(recursive: true);
  final manifest =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
  final base =
      Platform.environment['UWMEDIA_DEPS_URL'] ??
      'https://github.com/$depsRepo/releases/download/'
          '${manifest['deps_release_tag']}';
  final cache = Directory(
    Platform.environment['UWMEDIA_TOOLS_CACHE'] ?? 'build/tools_cache',
  )..createSync(recursive: true);
  Map<String, dynamic> entry(String tool) =>
      ((manifest[tool] as Map)['platforms'] as Map)[os] as Map<String, dynamic>;

  final exe = os == 'windows' ? '.exe' : '';
  final ffmpeg = entry('ffmpeg');
  for (final (name, asset, sum) in [
    ('ffmpeg', ffmpeg['asset'], ffmpeg['sha256']),
    ('ffprobe', ffmpeg['ffprobe_asset'], ffmpeg['ffprobe_sha256']),
  ]) {
    final file = await fetch(base, '$asset', '$sum', cache);
    file.copySync(p.join(bin.path, '$name$exe'));
  }

  // exiftool: the upstream package, its library kept beside it under the
  // name it looks for.
  final exiftool = entry('exiftool');
  final package = await fetch(
    base,
    '${exiftool['asset']}',
    '${exiftool['sha256']}',
    cache,
  );
  final unpacked = Directory(p.join(cache.path, 'exiftool_$os'));
  if (unpacked.existsSync()) {
    unpacked.deleteSync(recursive: true);
  }
  await extractFileToDisk(package.path, unpacked.path);
  // One folder inside (Image-ExifTool-13.59, exiftool-13.59_64).
  final inside = unpacked.listSync().whereType<Directory>().toList();
  final root = inside.length == 1 ? inside.single : unpacked;
  if (os == 'windows') {
    put(
      p.join(root.path, 'exiftool(-k).exe'),
      p.join(bin.path, 'exiftool.exe'),
    );
    put(
      p.join(root.path, 'exiftool_files'),
      p.join(bin.path, 'exiftool_files'),
    );
  } else {
    put(p.join(root.path, 'exiftool'), p.join(bin.path, 'exiftool'));
    put(p.join(root.path, 'lib'), p.join(bin.path, 'lib'));
  }
  unpacked.deleteSync(recursive: true);

  if (!Platform.isWindows && os != 'windows') {
    for (final name in const ['ffmpeg', 'ffprobe', 'exiftool']) {
      final done = Process.runSync('chmod', ['+x', p.join(bin.path, name)]);
      if (done.exitCode != 0) {
        fail('chmod +x $name: ${done.stderr}');
      }
    }
  }
  stdout.writeln(
    'ffmpeg ${ffmpeg['version']}, exiftool ${exiftool['version']} '
    'in ${bin.path}',
  );
}

Never fail(String message) {
  stderr.writeln('fetch_tools: $message');
  exit(1);
}

/// [asset] of the release in the [cache], downloaded unless it is there
/// with the right [sha256]; refuses a file whose sum is another.
Future<File> fetch(
  String base,
  String asset,
  String sha256sum,
  Directory cache,
) async {
  final file = File(p.join(cache.path, asset));
  if (file.existsSync() && await sumOf(file) == sha256sum) {
    return file;
  }
  stdout.writeln('Downloading $asset');
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('$base/$asset'));
    final response = await request.close();
    if (response.statusCode != 200) {
      fail('$base/$asset answered ${response.statusCode}');
    }
    await response.pipe(file.openWrite());
  } finally {
    client.close();
  }
  final sum = await sumOf(file);
  if (sum != sha256sum) {
    file.deleteSync();
    fail(
      'CHECKSUM MISMATCH for $asset: expected $sha256sum, got $sum. '
      'Refusing to use this file.',
    );
  }
  return file;
}

Future<String> sumOf(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// [from] (a file or a folder) to [to], replacing what is there.
void put(String from, String to) {
  final type = FileSystemEntity.typeSync(from);
  if (type == FileSystemEntityType.notFound) {
    fail('$from is not in the package');
  }
  if (FileSystemEntity.typeSync(to) != FileSystemEntityType.notFound) {
    type == FileSystemEntityType.directory
        ? Directory(to).deleteSync(recursive: true)
        : File(to).deleteSync();
  }
  if (type == FileSystemEntityType.directory) {
    Directory(to).createSync(recursive: true);
    for (final entity in Directory(from).listSync(recursive: true)) {
      final target = p.join(to, p.relative(entity.path, from: from));
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        File(target).parent.createSync(recursive: true);
        entity.copySync(target);
      }
    }
  } else {
    File(from).copySync(to);
  }
}
