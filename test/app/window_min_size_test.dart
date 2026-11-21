// Every desktop page in the app's frame at the smallest window
// (lib/core/window/window_placement.dart, spec §13.6) with nothing
// overflowing. The window's minimum is its frame; what the pages get is
// less the title bar and borders, taken here as at most 40 x 60 px
// (Windows' invisible borders and title bar; 0 x 28 on the Mac). Probed
// 2026-11-15 with empty pages: the Tag Editor and the Dive Profile
// Builder are the first to overflow, below about 1045 px of width;
// heights hold down to about 640 px.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/shell.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/window/window_placement.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/pages/about/about_page.dart';
import 'package:uwmedia_app/pages/advanced/advanced_page.dart';

/// The most a window's frame takes from its content.
const frameWidth = 40.0;
const frameHeight = 60.0;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_minsize_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // A machine with no tools on it: the pages that look for them find
  // none, and nothing is started.
  ToolFinder noTools() => ToolFinder(
    os: EngineOs.macos,
    env: const {},
    fileExists: (_) => false,
    runs: (_, _, _) async => false,
  );

  testWidgets('every desktop page fits the smallest window', (tester) async {
    tester.view.physicalSize = const Size(
      minWindowWidth - frameWidth,
      minWindowHeight - frameHeight,
    );
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
      tempDir: (prefix) => tmp.createTempSync(prefix),
      toolFinder: noTools,
    );
    final pages = [
      for (final page in pagesFor(services.capabilities))
        switch (page.title) {
          // The two pages that look for the tools themselves, and About
          // without asking GitHub.
          'Settings' => AppPage(
            title: page.title,
            icon: page.icon,
            build: (s) => AdvancedPage(services: s, finder: noTools),
          ),
          'About' => AppPage(
            title: page.title,
            icon: page.icon,
            build: (s) => AboutPage(
              services: s,
              version: '1.0.0',
              finder: noTools,
              latestTag: () async => null,
            ),
          ),
          _ => page,
        },
    ];
    expect(pages.length, greaterThanOrEqualTo(9));

    // Each overflow by the page it happened on, instead of the first one
    // alone.
    final problems = <String>[];
    var current = '';
    final reported = FlutterError.onError;
    FlutterError.onError = (details) => problems.add(
      '$current: ${details.exceptionAsString().split('\n').first}',
    );
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: AppShell(services: services, pages: pages),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      for (final page in pages) {
        current = page.title;
        await tester.tap(find.text(page.title).first);
        // What the page loads when it is first shown (templates, fonts).
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.getSize(find.byType(AppShell)), tester.view.physicalSize);
      }
    } finally {
      FlutterError.onError = reported;
    }
    expect(problems, isEmpty);
  });
}
