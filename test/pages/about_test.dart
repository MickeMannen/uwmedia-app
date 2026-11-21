// The About page (lib/pages/about/about_page.dart): versions compared as
// Python's _version_tuple and tuple comparison do, the update check's
// answers, the tools found, and the page on screen with a made-up release
// and a made-up machine (no network).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/pages/about/about_page.dart';

void main() {
  test('versions as Python compares them', () {
    expect(versionParts('v1.2.3'), [1, 2, 3]);
    expect(versionParts('0.7.20-beta.1'), [0, 7, 20]);
    expect(versionParts('1.0.0+1'), [1, 0, 0, 1]);
    expect(versionParts('dev'), isEmpty);
    expect(isNewer([0, 7, 21], [0, 7, 20]), isTrue);
    expect(isNewer([0, 8], [0, 7, 99]), isTrue);
    expect(isNewer([1, 0, 0], [1, 0]), isTrue);
    expect(isNewer([1, 0], [1, 0]), isFalse);
    expect(isNewer([0, 9], [1]), isFalse);
  });

  test('the update check says', () {
    expect(updateNote(null, '1.0.0').text, 'No releases found on GitHub yet.');
    expect(
      updateNote('v1.1.0', '1.0.0').text,
      'A new version is available: v1.1.0 (you have 1.0.0)',
    );
    expect(updateNote('v1.0.0', '1.0.0').text, "You're up to date (1.0.0).");
  });

  test('a tool: the shipped one with its version, else where it is', () {
    final manifest = File(toolManifest).readAsStringSync();
    expect(shippedVersion(manifest, 'ffmpeg', EngineOs.macos), '9.0.2-uwmedia');
    expect(shippedVersion(manifest, 'exiftool', EngineOs.windows), '13.59');
    expect(shippedVersion('no json', 'ffmpeg', EngineOs.linux), isNull);
    expect(shippedVersion(manifest, 'perl', EngineOs.linux), isNull);
    expect(
      toolLine('FFmpeg', '/a/bin/ffmpeg', shipped: true, version: 'n8.1.2'),
      'FFmpeg n8.1.2 — packaged with this app',
    );
    expect(
      toolLine('FFmpeg', '/usr/bin/ffmpeg', shipped: false, version: 'n8'),
      'FFmpeg — using local install (/usr/bin/ffmpeg)',
    );
    expect(toolLine('ExifTool', null, shipped: false), 'ExifTool — not found');
    // The licences of what is shipped are in the bundle.
    for (final file in toolLicenses.values) {
      expect(File('assets/licenses/$file').existsSync(), isTrue);
    }
    // And the app's own, as an asset.
    expect(File(appLicense).readAsStringSync(), contains('MIT License'));
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('    - $appLicense\n'),
    );
  });

  testWidgets('on screen', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tmp = Directory.systemTemp.createTempSync('uwmedia_about_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    var asked = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: AboutPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: ConfigStore(() => Directory(p.join(tmp.path, 'c'))),
                home: '/Users/x',
              ),
              version: '1.0.0',
              log: AppLog(File(p.join(tmp.path, 'uwmedia.log')))
                ..add('Color', 'Reef.MP4: Could not analyze any frames.'),
              latestTag: () async {
                asked++;
                return 'v1.2.0';
              },
              finder: () => ToolFinder(
                os: EngineOs.macos,
                env: const {'HOME': '/Users/x', 'PATH': '/usr/local/bin'},
                fileExists: {'/usr/local/bin/ffmpeg'}.contains,
                runs: (file, args, timeout) async => true,
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Version 1.0.0'), findsOneWidget);
    expect(
      find.text('FFmpeg — using local install (/usr/local/bin/ffmpeg)'),
      findsOneWidget,
    );
    expect(find.text('ExifTool — not found'), findsOneWidget);
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(
      find.text('A new version is available: v1.2.0 (you have 1.0.0)'),
      findsOneWidget,
    );

    // A report (spec §10.76): the version, the system and the log's last
    // lines, copied for the user to send.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.ensureVisible(find.text(copyReportLabel));
    await tester.tap(find.text(copyReportLabel));
    await tester.pumpAndSettle();
    expect(copied, startsWith('UWMedia problem report\nVersion: 1.0.0\n'));
    expect(copied, contains('[Color] Reef.MP4: Could not analyze any frames.'));
    expect(copied, contains('FFmpeg: FFmpeg — using local install'));
    expect(find.textContaining('Copied.'), findsOneWidget);
  });
}
