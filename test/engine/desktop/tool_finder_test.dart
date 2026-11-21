// Finding ffmpeg, ffprobe and exiftool (lib/engine/desktop/tool_finder.dart)
// on a machine that is made up: which candidate wins, and the text for
// missing tools against the Python app's (the parity fixture made by
// tool/python_reference/tools_fixture.py).
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';

import '../../helpers/python_reference.dart';

void main() {
  const systems = {
    'Darwin': EngineOs.macos,
    'Windows': EngineOs.windows,
    'Linux': EngineOs.linux,
  };

  test('the text for missing tools is the Python app\'s', () {
    final cases = jsonObjects(
      pythonReference('engine/tools_cases.json')['instructions'],
    );
    expect(cases.length, 21);
    for (final c in cases) {
      expect(
        installationInstructions(
          (c['missing'] as List<dynamic>).cast<String>(),
          systems[c['system']]!,
        ),
        c['text'],
        reason: '${c['system']} ${c['missing']}',
      );
    }
  });

  test('where the tools shipped with the app lie (spec §13.2)', () {
    expect(
      bundledToolsDir(
        EngineOs.macos,
        '/Applications/UWMedia.app/Contents/MacOS/UWMedia',
      ),
      '/Applications/UWMedia.app/Contents/Resources/bin',
    );
    expect(
      bundledToolsDir(
        EngineOs.windows,
        r'C:\Users\d\AppData\Local\Programs\uwmedia\uwmedia.exe',
      ),
      r'C:\Users\d\AppData\Local\Programs\uwmedia\bin',
    );
    expect(
      bundledToolsDir(EngineOs.linux, '/opt/uwmedia/uwmedia'),
      '/opt/uwmedia/bin',
    );
  });

  test('names, version arguments and the folders searched', () {
    expect(executableName('ffmpeg', EngineOs.windows), 'ffmpeg.exe');
    expect(executableName('ffmpeg', EngineOs.linux), 'ffmpeg');
    expect(versionArgs('exiftool'), ['-ver']);
    expect(versionArgs('ffprobe'), ['-version']);
    expect(toolSearchDirs(EngineOs.macos, {'HOME': '/Users/x'}), [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/opt/local/bin',
      '/Users/x/bin',
      '/Users/x/.local/bin',
    ]);
    expect(toolSearchDirs(EngineOs.linux, {'HOME': '/home/x'}), [
      '/usr/bin',
      '/usr/local/bin',
      '/usr/bin/vendor_perl',
      '/snap/bin',
      '/home/x/.local/bin',
    ]);
    expect(
      toolSearchDirs(
        EngineOs.windows,
        {'USERPROFILE': r'C:\Users\x', 'PROGRAMFILES': r'D:\Programs'},
        wingetDirs: [r'C:\w\ffmpeg-7\bin'],
      ),
      [
        r'C:\ffmpeg\bin',
        r'D:\Programs\ffmpeg\bin',
        r'C:\Program Files (x86)\ffmpeg\bin',
        r'C:\ProgramData\chocolatey\bin',
        r'C:\Users\x\ffmpeg\bin',
        r'C:\exiftool',
        r'C:\Windows',
        r'D:\Programs\exiftool',
        r'C:\Users\x\exiftool',
        r'C:\w\ffmpeg-7\bin',
      ],
    );
    expect(
      wingetPackagesDir({'LOCALAPPDATA': r'C:\L'}),
      r'C:\L\Microsoft\WinGet\Packages',
    );
  });

  group('which candidate wins', () {
    // A machine: the files that exist, and those of them that run.
    ToolFinder machine({
      required Set<String> files,
      Set<String>? working,
      EngineOs os = EngineOs.macos,
      String? bundled,
      String path = '/usr/local/bin:/opt/tools',
      List<(String, List<String>, Duration)>? asked,
    }) => ToolFinder(
      os: os,
      env: {'HOME': '/Users/x', 'USERPROFILE': r'C:\Users\x', 'PATH': path},
      bundledBinDir: bundled,
      fileExists: files.contains,
      runs: (file, args, timeout) async {
        asked?.add((file, args, timeout));
        return (working ?? files).contains(file);
      },
      wingetDirs: () => [r'C:\w\ffmpeg-7\bin'],
    );

    test(
      'the bundled copy before the PATH, with time for a first start',
      () async {
        final asked = <(String, List<String>, Duration)>[];
        final finder = machine(
          files: {'/app/bin/ffmpeg', '/usr/local/bin/ffmpeg'},
          bundled: '/app/bin',
          asked: asked,
        );
        expect(await finder.find('ffmpeg'), '/app/bin/ffmpeg');
        final (file, args, timeout) = asked.single;
        expect(file, '/app/bin/ffmpeg');
        expect(args, ['-version']);
        expect(timeout, bundledVersionTimeout);
      },
    );

    test('a bundled copy that does not run gives way to the PATH', () async {
      final finder = machine(
        files: {'/app/bin/exiftool', '/opt/tools/exiftool'},
        working: {'/opt/tools/exiftool'},
        bundled: '/app/bin',
      );
      expect(await finder.find('exiftool'), '/opt/tools/exiftool');
    });

    test(
      'only the first on the PATH is tried, then the usual folders',
      () async {
        final finder = machine(
          files: {
            '/usr/local/bin/ffmpeg',
            '/opt/tools/ffmpeg',
            '/opt/homebrew/bin/ffmpeg',
          },
          working: {'/opt/tools/ffmpeg', '/opt/homebrew/bin/ffmpeg'},
        );
        expect(await finder.find('ffmpeg'), '/opt/homebrew/bin/ffmpeg');
      },
    );

    test('ffprobe beside ffmpeg', () async {
      final finder = machine(
        files: {'/custom/ffmpeg', '/custom/ffprobe', '/Users/x/bin/ffprobe'},
      );
      expect(
        await finder.find('ffprobe', knownFfmpegDir: '/custom'),
        '/custom/ffprobe',
      );
      expect(await finder.find('ffprobe'), '/Users/x/bin/ffprobe');
      // That folder is for ffprobe only.
      expect(await finder.find('exiftool', knownFfmpegDir: '/custom'), isNull);
    });

    test(
      'Windows: the .exe, the PATH with semicolons, WinGet\'s folders',
      () async {
        final finder = machine(
          os: EngineOs.windows,
          path: r'C:\bin;D:\tools',
          files: {r'D:\tools\ffmpeg.exe', r'C:\w\ffmpeg-7\bin\ffprobe.exe'},
        );
        expect(await finder.find('ffmpeg'), r'D:\tools\ffmpeg.exe');
        expect(await finder.find('ffprobe'), r'C:\w\ffmpeg-7\bin\ffprobe.exe');
        expect(await finder.find('exiftool'), isNull);
      },
    );

    test(
      'the path set on the Settings page, while the file is there',
      () async {
        final finder = machine(
          files: {'/my/ffmpeg', '/my/ffprobe', '/usr/local/bin/ffmpeg'},
          working: {'/usr/local/bin/ffmpeg', '/my/ffprobe'},
        );
        // The set path is taken as it is: whether it runs is asked when it
        // is set.
        expect(
          await finder.resolve('ffmpeg', {
            'ffmpeg_path': '/my/ffmpeg',
          }, 'ffmpeg_path'),
          '/my/ffmpeg',
        );
        expect(
          await finder.resolve('ffmpeg', {
            'ffmpeg_path': '/gone',
          }, 'ffmpeg_path'),
          '/usr/local/bin/ffmpeg',
        );
        expect(
          await finder.resolve('ffmpeg', {'ffmpeg_path': null}, 'ffmpeg_path'),
          '/usr/local/bin/ffmpeg',
        );
        expect(await finder.findAll({'ffmpeg_path': '/my/ffmpeg'}), {
          'ffmpeg': '/my/ffmpeg',
          'ffprobe': '/my/ffprobe',
        });
        expect(await finder.isValidFfmpeg('/my/ffmpeg'), isFalse);
        expect(await finder.isValidFfmpeg('/usr/local/bin/ffmpeg'), isTrue);
        expect(await finder.isValidFfmpeg(null), isFalse);
        expect(await finder.isValidExiftool('/nowhere/exiftool'), isFalse);
      },
    );
  });
}
