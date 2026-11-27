// The Convertion page (lib/pages/convertion/) on a made-up engine: what it
// shows for a picked video, the names it will write, a run with its steps,
// Stop, a failure, the batch gate, the settings it keeps (in a temporary
// folder) and the page itself in the app's frame.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/shell.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/pages/convertion/convertion_controller.dart';
import 'package:uwmedia_app/pages/convertion/convertion_page.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';

/// An engine that answers from a script: the video's size, and a run that
/// reports its steps and waits for [release] (or a Stop) before each end.
class FakeEngine implements ConvertionEngine {
  (int, int)? size = (1280, 720);

  /// The size of single paths, where it is not [size].
  final Map<String, (int, int)> sizes = {};

  /// Videos whose run breaks.
  final List<String> broken = [];

  /// Per path, a probe that answers only when completed.
  final Map<String, Completer<(int, int)>> slow = {};
  final List<String> failing = [];
  final calls = <Map<String, Object?>>[];
  Completer<void> release = Completer<void>();

  @override
  Future<(int, int)> dimensions(String path) async =>
      slow[path]?.future ??
      sizes[path] ??
      size ??
      (throw const EngineException('ffprobe failed'));

  /// The video's length; `null` for one that gives none.
  double? seconds = 60;

  @override
  Future<double> duration(String path) async =>
      seconds ?? (throw const EngineException('no duration'));

  @override
  Future<ConvertResult> convert({
    required String source,
    required String outputDir,
    required List<String> resolutions,
    required bool hwAccel,
    required RunControl control,
    List<ShareCopy> shares = const [],
    List<HudLayerSource> watermarks = const [],
    void Function(ConvertStep step)? onStep,
    void Function(double percent)? onProgress,
  }) async {
    calls.add({
      'source': source,
      'out': outputDir,
      'resolutions': resolutions,
      'hw': hwAccel,
      if (watermarks.isNotEmpty)
        'watermarks': [for (final mark in watermarks) mark.layout],
      if (shares.isNotEmpty)
        'shares': [
          for (final copy in shares)
            '${copy.label} ${copy.shape.name} ${copy.cropAt}',
        ],
    });
    // A copy for sharing is one more encode, named by its label.
    resolutions = [...resolutions, for (final copy in shares) copy.label];
    if (broken.contains(source)) {
      throw const EngineException('no video stream');
    }
    final total = resolutions.length;
    onStep?.call((done: 0, total: total, target: null));
    final failed = <String>[];
    for (var i = 0; i < total; i++) {
      final name = 'x ${resolutions[i]}.mp4';
      onStep?.call((done: i, total: total, target: name));
      onProgress?.call(50);
      control.runningWith(() async {
        if (!release.isCompleted) {
          release.complete();
        }
      });
      await release.future;
      release = Completer<void>();
      if (control.stopped) {
        throw const RunStopped();
      }
      if (failing.contains(resolutions[i])) {
        failed.add(resolutions[i]);
      }
      onStep?.call((
        done: i + 1,
        total: total,
        target: i + 1 < total ? name : null,
      ));
    }
    return (
      failed: failed,
      messages: [for (final f in failed) 'Error converting to $f: broken'],
    );
  }
}

void main() {
  late Directory tmp;
  late ConfigStore config;
  late BatchGate gate;
  late FakeEngine engine;
  var now = 0.0;

  ConvertionController controller() => ConvertionController(
    config: config,
    gate: gate,
    home: '/Users/diver',
    engine: () async => engine,
    clock: () => now,
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_convertion_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    gate = BatchGate();
    engine = FakeEngine();
    now = 0;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'a picked video: its size, the resolutions up to it, the names',
    () async {
      final c = controller();
      expect(c.statusText, noBatchText);
      expect(c.outputPreviewText, outputPreviewHint);
      expect(c.resolutionNames, ['1080p', '720p', '480p', '360p']);
      c.setChecked('1080p', true);

      await c.chooseSource('/Users/diver/Dives/Reef 4K.MP4');
      expect(c.displayPath(c.sourceText), '~/Dives/Reef 4K.MP4');
      expect(c.sourceResolutionText, '1280x720 (up to 720p)');
      expect(c.isEnabled('1080p'), isFalse);
      expect(c.isChecked('1080p'), isFalse, reason: 'unchecked when too big');
      expect(c.isEnabled('720p'), isTrue);
      expect(c.outputPreviewText, outputPreviewHint);
      // A minute at each preset's bit rate; none for a size it cannot have.
      expect(c.sizeText('1080p'), '');
      expect(c.sizeText('720p'), 'about 90 MB');
      expect(c.sizeText('360p'), 'about 30 MB');
      expect(sizeEstimateText(0.1, '4M'), 'under 1 MB');
      expect(sizeEstimateText(600, '24M'), 'about 1.8 GB');

      c
        ..setChecked('720p', true)
        ..setChecked('360p', true);
      expect(c.outputPreviewText, 'Reef 720p.mp4\nReef 360p.mp4');
      c.chooseDest('/Users/diver/Out');
      expect(
        c.outputPreviewText,
        // Joined as the platform joins (a backslash on Windows).
        '${p.join('/Users/diver/Out', 'Reef 720p.mp4')}\n'
        '${p.join('/Users/diver/Out', 'Reef 360p.mp4')}',
      );
      // A phone's page lists the names alone (owner, 2026-11-24).
      expect(c.outputNamesText, 'Reef 720p.mp4\nReef 360p.mp4');

      // A file ffprobe cannot read: every resolution may be picked.
      engine.size = null;
      await c.chooseSource('/elsewhere/clip.mov');
      expect(
        c.sourceResolutionText,
        'Could not detect resolution: ffprobe failed',
      );
      expect(c.resolutionNames.every(c.isEnabled), isTrue);

      // Smaller than every resolution: its own size alone.
      engine.size = (320, 240);
      await c.chooseSource('/elsewhere/tiny.mp4');
      expect(c.sourceResolutionText, '320x240');
      expect(c.resolutionNames.where(c.isEnabled), isEmpty);
      c.dispose();
    },
  );

  test('a probe that ends after the next pick is not shown', () async {
    final c = controller();
    engine.slow['/v/a.mp4'] = Completer();
    final first = c.chooseSource('/v/a.mp4');
    await c.chooseSource('/v/b.mp4');
    expect(c.sourceResolutionText, '1280x720 (up to 720p)');
    engine.slow['/v/a.mp4']!.complete((320, 240));
    await first;
    expect(c.sourceResolutionText, '1280x720 (up to 720p)');
    expect(c.isEnabled('720p'), isTrue);
    c.dispose();
  });

  test('the dialog folders and the hardware switch are kept', () async {
    Directory(p.join(tmp.path, 'videos')).createSync();
    final c = controller();
    expect(c.hwAccel, isTrue);
    expect(c.sourceDialogDir, '/Users/diver');
    c.hwAccel = false;
    await c.chooseSource(p.join(tmp.path, 'videos', 'a.mp4'));
    c.chooseDest('/gone/away');
    c.dispose();

    final next = controller();
    expect(next.hwAccel, isFalse);
    expect(next.sourceDialogDir, p.join(tmp.path, 'videos'));
    // A folder that is no longer there: home.
    expect(next.destDialogDir, '/Users/diver');
    // The fields themselves are not kept, as in Python.
    expect(next.sourceText, '');
    expect(config.fields()[hwAccelField], isFalse);
    next.dispose();
  });

  test('a run: steps, progress, the gate, the time', () async {
    final c = controller();
    await c.startOrStop();
    expect(c.statusText, nothingToRunText);
    expect(engine.calls, isEmpty);

    await c.chooseSource('/v/Reef.mp4');
    c
      ..chooseDest('/out')
      ..setChecked('720p', true)
      ..setChecked('480p', true);
    final run = c.startOrStop();
    await pumpEventQueue();
    expect(c.isRunning, isTrue);
    expect(gate.owner, convertionPage);
    expect(engine.calls.single, {
      'source': '/v/Reef.mp4',
      'out': '/out',
      'resolutions': ['720p', '480p'],
      'hw': true,
    });
    expect(c.statusText, 'Processing: x 720p.mp4 — 50%');
    expect(c.progressFraction, 0.25);
    expect(c.progressFractionText, '0/2 · 25%');
    now = 10;
    expect(c.timingText, 'Elapsed 0:10 · about 0:30 left');

    engine.release.complete();
    await pumpEventQueue();
    expect(c.statusText, 'Processing: x 480p.mp4 — 50%');
    expect(c.progressFraction, 0.75);

    now = 20;
    engine.release.complete();
    await run;
    expect(c.isRunning, isFalse);
    expect(c.statusText, 'Finished');
    expect(c.timingText, 'Finished in 0:20');
    expect(c.progressFractionText, '');
    expect(gate.owner, isNull);
    c.dispose();
  });

  test('several videos: each to the sizes up to its own', () async {
    engine.sizes.addAll({
      '/v/big.mp4': (3840, 2160),
      '/v/small.mp4': (640, 360),
    });
    final c = controller();
    await c.chooseSources(['/v/big.mp4', '/v/small.mp4']);
    expect(c.sourceText, '/v/big.mp4');
    expect(c.sourceDisplay, '2 videos in /v');
    expect(
      c.sourceResolutionText,
      '2 videos, the largest 3840x2160 (up to 1080p)',
    );
    c
      ..chooseDest('/out')
      ..setChecked('720p', true)
      ..setChecked('360p', true);
    // A minute each: 720p of the big one alone, 360p of both.
    expect(c.sizeText('720p'), 'about 90 MB');
    expect(c.sizeText('360p'), 'about 60 MB');
    expect(c.outputPreviewText.split('\n'), hasLength(3));

    final run = c.startOrStop();
    await pumpEventQueue();
    expect(c.progressFractionText, '0/3 · 17%');
    engine.release.complete();
    await pumpEventQueue();
    engine.release.complete();
    await pumpEventQueue();
    expect(c.progressFractionText, '2/3 · 83%');
    engine.release.complete();
    await run;
    expect(
      [
        for (final call in engine.calls)
          '${call['source']}: ${(call['resolutions']! as List).join(' ')}',
      ],
      ['/v/big.mp4: 720p 360p', '/v/small.mp4: 360p'],
    );
    expect(c.statusText, 'Finished');

    // One video's failure is that video's.
    engine.broken.add('/v/big.mp4');
    final again = c.startOrStop();
    await pumpEventQueue();
    engine.release.complete();
    await again;
    expect(
      c.statusText,
      'Failed: big.mp4\nError converting big.mp4: no video stream',
    );
    c.dispose();
  });

  test('sizes named for an app: names, megabytes, the run', () async {
    engine.size = (3840, 2160);
    final c = controller();
    await c.chooseSource('/v/Dive 4K.MOV');
    c.chooseDest('/out');
    expect(
      [for (final key in shareKeys) c.shareTitle(key)],
      ['WhatsApp', 'WeChat', 'Instagram / Facebook'],
    );
    expect(c.shareText(shareWhatsAppKey), '1280x720, about 23 MB');
    expect(c.shareText(shareWeChatKey), '1280x720, about 15 MB');
    expect(c.shareText(shareInstagramKey), '1920x1080, about 60 MB');

    c
      ..setShareChecked(shareWhatsAppKey, true)
      ..setShareChecked(shareInstagramKey, true);
    expect(c.outputPreviewText.split('\n'), [
      p.join('/out', 'Dive WhatsApp.mp4'),
      p.join('/out', 'Dive Instagram.mp4'),
    ]);

    final run = c.startOrStop();
    await pumpEventQueue();
    expect(c.progressFractionText, '0/2 · 25%');
    engine.release.complete();
    await pumpEventQueue();
    engine.release.complete();
    await run;
    expect(c.statusText, 'Finished');
    expect(engine.calls.single['resolutions'], isEmpty);
    // As the video was shot: a crop to portrait is the Color page's.
    expect(engine.calls.single['shares'], [
      'WhatsApp asShot 0.5',
      'Instagram / Facebook asShot 0.5',
    ]);

    // A portrait video stays portrait.
    engine.size = (1080, 1920);
    await c.chooseSource('/v/phone.mp4');
    expect(c.shareText(shareWhatsAppKey), '720x1280, about 23 MB');
    c.dispose();
  });

  test('a watermark: the one chosen goes with the run', () async {
    final store = WatermarkStore(
      config,
      Directory(p.join(tmp.path, 'data', 'watermarks')),
    )..addText('© Diver');
    final c = ConvertionController(
      config: config,
      gate: gate,
      home: '/Users/diver',
      engine: () async => engine,
      watermarkStore: store,
    );
    expect(controller().watermarkList, isEmpty, reason: 'no store, none');
    expect(c.watermarkList, ['© Diver']);
    expect(c.isWatermarkOn('© Diver'), isFalse);
    await c.chooseSource('/v/a.mp4');
    c
      ..chooseDest('/out')
      ..setChecked('480p', true);

    var run = c.startOrStop();
    await pumpEventQueue();
    engine.release.complete();
    await run;
    expect(engine.calls.last.containsKey('watermarks'), isFalse);

    c.setWatermark('© Diver', true);
    expect(
      store.selected.single.name,
      '© Diver',
      reason: 'the Color page\'s too',
    );
    run = c.startOrStop();
    await pumpEventQueue();
    engine.release.complete();
    await run;
    expect(
      jsonEncode(engine.calls.last['watermarks']),
      contains('custom:© Diver'),
    );
    // A second one goes with it; the order is the list's.
    store.addText('Second');
    c
      ..watermarksChanged()
      ..setWatermark('Second', true);
    expect(c.watermarkList, ['© Diver', 'Second']);
    run = c.startOrStop();
    await pumpEventQueue();
    engine.release.complete();
    await run;
    final both = jsonEncode(engine.calls.last['watermarks']);
    expect(engine.calls.last['watermarks'], hasLength(2));
    expect(
      both.indexOf('custom:© Diver'),
      lessThan(both.indexOf('custom:Second')),
    );
    c.dispose();
  });

  test('a folder as the source stands for its videos', () async {
    final folder = Directory(p.join(tmp.path, 'clips'))..createSync();
    for (final name in ['b.MP4', 'a.mov', 'notes.txt', '.hidden.mp4']) {
      File(p.join(folder.path, name)).writeAsStringSync('');
    }
    final c = controller();
    await c.chooseSources([folder.path]);
    expect([for (final s in c.sources) p.basename(s)], ['a.mov', 'b.MP4']);
    c.dispose();
  });

  test('Stop, a failure, another page running', () async {
    final c = controller();
    await c.chooseSource('/v/Reef.mp4');
    c
      ..chooseDest('/out')
      ..setChecked('480p', true)
      ..setChecked('360p', true);

    final run = c.startOrStop();
    await pumpEventQueue();
    now = 3;
    final stopping = c.startOrStop();
    expect(c.statusText, 'Stopping…');
    await stopping;
    await run;
    expect(c.statusText, 'Stopped');
    expect(c.timingText, 'Stopped after 0:03');
    expect(gate.owner, isNull);

    engine.failing.add('360p');
    final failing = c.startOrStop();
    await pumpEventQueue();
    engine.release.complete();
    await pumpEventQueue();
    engine.release.complete();
    await failing;
    expect(c.statusText, 'Failed: 360p\nError converting to 360p: broken');

    expect(gate.enter('Color'), isTrue);
    await c.startOrStop();
    expect(c.isRunning, isFalse);
    expect(engine.calls.length, 2);
    c.dispose();
  });

  test('missing tools are said, not thrown', () async {
    final c = ConvertionController(
      config: config,
      gate: gate,
      home: '/Users/diver',
      engine: () async => throw const EngineException('Install FFmpeg'),
    );
    await c.chooseSource('/v/Reef.mp4');
    expect(
      c.sourceResolutionText,
      'Could not detect resolution: Install FFmpeg',
    );
    c
      ..chooseDest('/out')
      ..setChecked('480p', true);
    await c.startOrStop();
    expect(c.statusText, 'Install FFmpeg');
    expect(gate.owner, isNull);
    c.dispose();
  });

  group('on screen', () {
    AppServices services({bool desktop = true}) => AppServices(
      capabilities: Capabilities(desktop: desktop),
      config: config,
      home: '/Users/diver',
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );

    test('the pages per device (spec §0)', () {
      expect(
        [
          for (final page in pagesFor(const Capabilities(desktop: true)))
            page.title,
        ],
        [
          'Color',
          'Overlay Generator',
          'Resize',
          'Color Tuning',
          'Tag Editor',
          'Log Viewer',
          'Overlay Designer',
          'Dive Profile Builder',
          // The logs kept in the app, on the desktop too (spec §10.57).
          'Dive Logs',
          'Settings',
          'About',
        ],
      );
      expect(
        [
          for (final page in pagesFor(const Capabilities(desktop: false)))
            page.title,
        ],
        [
          'Color',
          'Resize',
          'Color Tuning',
          'Tag Editor',
          'Dive Logs',
          'Settings',
          'About',
        ],
      );
    });

    testWidgets('the frame: a rail when wide, a menu when narrow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: AppShell(services: services(), pages: _lightPages(services())),
        ),
      );
      expect(find.text('Dive Profile Builder'), findsOneWidget);
      expect(find.text('Dive Logs'), findsOneWidget);
      await tester.tap(find.text('Resize'));
      await tester.pumpAndSettle();
      expect(find.text('Output resolutions'), findsOneWidget);

      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: AppShell(
            services: services(desktop: false),
            pages: _lightPages(services(desktop: false)),
          ),
        ),
      );
      expect(find.byType(AppBar), findsOneWidget);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tag Editor'));
      await tester.pumpAndSettle();
      expect(find.text('Tag Editor'), findsWidgets);
      expect(find.text('Resize'), findsNothing);
    });

    testWidgets('a resize does not end a run', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      engine.release = Completer<void>();
      final app = services();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: AppShell(services: app, pages: _lightPages(app)),
        ),
      );
      await tester.tap(find.text('Resize'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(ConvertionPage));
      app.batches.enter('test');
      tester.view.physicalSize = const Size(600, 800);
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(tester.state(find.byType(ConvertionPage)), same(state));
      app.batches.leave('test');
    });

    testWidgets('picking, switching, running', (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dialogs = _Dialogs();
      // Made in the test's own clock zone, or its future would wait for
      // the real one.
      engine.release = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ConvertionPage(
              services: services(),
              dialogs: dialogs,
              engine: () async => engine,
            ),
          ),
        ),
      );
      expect(find.text(outputPreviewHint), findsOneWidget);
      // Nothing is typed: the source and the destination are buttons.
      expect(find.byType(TextField), findsNothing);
      // One place each (no Photos here): the buttons open the dialogs.
      await tester.tap(find.text(chooseVideosLabel));
      await tester.pumpAndSettle();
      expect(dialogs.asked, ['video in /Users/diver']);
      expect(find.text('~/Dives/Reef.mp4'), findsOneWidget);
      expect(find.text('1280x720 (up to 720p)'), findsOneWidget);
      expect(find.text('about 90 MB'), findsOneWidget);
      await tester.tap(find.text(saveToLabel));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, saveToLabel), findsOneWidget);
      expect(find.text('/out'), findsOneWidget);
      await tester.tap(find.text('480p'));
      await tester.pumpAndSettle();
      expect(find.text(p.join('/out', 'Reef 480p.mp4')), findsOneWidget);

      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(find.text('Stop'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      engine.release.complete();
      await tester.pumpAndSettle();
      expect(find.text('Finished'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('a portrait copy: the window is dragged on the preview', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      engine.size = (3840, 2160);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ConvertionPage(
              services: services(),
              dialogs: _Dialogs(),
              engine: () async => engine,
            ),
          ),
        ),
      );
      await tester.tap(find.text(chooseVideosLabel));
      await tester.pumpAndSettle();
      // One list of sizes: the resolutions and those named for an app.
      expect(find.text('For sharing'), findsNothing);
      expect(find.text('1280x720, about 23 MB'), findsWidgets);
      expect(find.text('Cropped'), findsNothing);

      await tester.ensureVisible(find.text('Instagram / Facebook'));
      await tester.tap(find.text('Instagram / Facebook'));
      await tester.pumpAndSettle();
      expect(find.text('~/Dives/Reef Instagram.mp4'), findsNothing);
      expect(find.text('Reef Instagram.mp4'), findsOneWidget);
    });
    testWidgets('on a phone: a video from the library, into an album', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dialogs = _Dialogs();
      engine.release = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ConvertionPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: false),
                config: config,
                home: '/Users/diver',
                dataDir: () => Directory(p.join(tmp.path, 'data')),
                tempDir: (prefix) => tmp.createTempSync(prefix),
              ),
              dialogs: dialogs,
              engine: () async => engine,
              phone: true,
            ),
          ),
        ),
      );
      // No folders on a phone, nor the hardware switch.
      expect(find.text(saveToLabel), findsNothing);
      expect(find.text(chooseVideosLabel), findsNothing);
      expect(find.text('Hardware acceleration'), findsNothing);
      // One button, which asks where from.
      Future<void> pickFrom(String place) async {
        await tester.tap(find.text('Pick a video'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, place));
        await tester.pumpAndSettle();
      }

      await pickFrom(fromLibraryLabel);
      expect(find.text('Reef.mp4'), findsOneWidget);
      // Or one from the phone's files, where a camera card's clips are.
      await pickFrom(fromFilesLabel);
      expect(dialogs.asked.last, 'video in Files');
      expect(find.text('Wreck.mp4'), findsOneWidget);
      await pickFrom(fromLibraryLabel);
      expect(find.text('Reef.mp4'), findsOneWidget);
      // The sizes stand in two columns.
      expect(
        tester.getTopLeft(find.text('720p')).dy,
        closeTo(tester.getTopLeft(find.text('1080p')).dy, 12),
      );
      expect(
        tester.getTopLeft(find.text('720p')).dx,
        greaterThan(tester.getTopLeft(find.text('1080p')).dx + 150),
      );
      await tester.tap(find.text('480p'));
      await tester.pumpAndSettle();
      // Start is at the foot of the screen (900 high), not at the end of
      // the page's scroll; nothing of a run is shown before the first one.
      expect(
        tester.getBottomLeft(find.text('Start')).dy,
        inInclusiveRange(840, 900),
      );
      expect(find.text('Progress'), findsNothing);
      expect(find.text(noBatchText), findsNothing);
      await tester.tap(find.text('Start'));
      await tester.pump();
      // While the run goes: the video, what is made and the progress.
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Progress'), findsOneWidget);
      expect(find.text('Output files'), findsOneWidget);
      expect(find.text('Pick a video'), findsNothing);
      expect(find.text('For sharing'), findsNothing);
      engine.release.complete();
      await tester.pumpAndSettle();
      // Ended: the page as it was, how the run ended above Start.
      expect(find.text('Pick a video'), findsOneWidget);
      expect(find.text('Progress'), findsNothing);
      // The results waited in a working folder of the app.
      final out = engine.calls.single['out']! as String;
      expect(p.isWithin(tmp.path, out), isTrue);
      expect(p.basename(out), startsWith('uwmedia_convert_out_'));
      expect(find.text('Finished'), findsOneWidget);
    });
  });
}

class _Dialogs implements ConvertionDialogs {
  final asked = <String>[];

  @override
  Future<List<String>> pickVideos(String initialDirectory) async {
    asked.add('video in $initialDirectory');
    return ['/Users/diver/Dives/Reef.mp4'];
  }

  @override
  Future<List<String>> pickVideoFiles() async {
    asked.add('video in Files');
    return ['/Users/diver/Card/Wreck.mp4'];
  }

  @override
  Future<String?> pickFolder(String initialDirectory) async => '/out';
}

/// The device's pages with the ones that load assets or tools when built
/// (Color) as a plain page, so that the frame settles in a test.
List<AppPage> _lightPages(AppServices services) => [
  for (final page in pagesFor(services.capabilities))
    const {
          'Color',
          'Overlay Generator',
          'Settings',
          'About',
        }.contains(page.title)
        ? AppPage(
            title: page.title,
            icon: page.icon,
            build: (_) => Text(page.title),
          )
        : page,
];
