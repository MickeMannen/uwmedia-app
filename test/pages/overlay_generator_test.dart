// The Overlay Generator page (lib/pages/overlay_generator/) on a made-up
// engine, the bundled template tree and a temporary config folder: the
// fields kept under the Python app's names, the overlay list from the
// picker and from a layout file, the runs over a folder (one per overlay,
// with the settings each gets and the two progress bars) and from a log
// file, a failed overlay, Stop, and the page on screen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/pages/dive_matches.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_batch.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_controller.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_page.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';
import 'package:uwmedia_app/pages/shared/template_picker.dart';

class FakeEngine implements OverlayGeneratorEngine {
  /// Each file's tags by its name; a file not here has none.
  final tagsOf = <String, MediaTags>{};
  final read = <String>[];

  @override
  Future<MediaTags?> metadata(String path) async {
    read.add(p.basename(path));
    return tagsOf[p.basename(path)];
  }

  final folderRuns = <OverlayFolderSettings>[];
  final logRuns = <(String, String, OverlayLook)>[];
  final seen = <String>[];
  OverlayGeneratorController? watch;
  String? failing;
  Completer<void>? hold;
  bool stopped = false;

  @override
  Future<List<FileResult>> runFolder(
    OverlayFolderSettings settings,
    ColorBatchListener listener,
  ) async {
    folderRuns.add(settings);
    listener
      ..started(2)
      ..active('a.mp4');
    seen.add('${watch!.currentProgressText} | ${watch!.totalProgressText}');
    listener.finished(1, 2, (
      file: 'a.mp4',
      status: FileStatus.done,
      error: null,
    ));
    seen.add('${watch!.currentProgress} ${watch!.totalProgress}');
    await hold?.future;
    if (stopped) {
      throw const RunStopped();
    }
    final failed = p.basename(settings.layoutPath) == failing;
    final last = (
      file: 'b.jpg',
      status: failed ? FileStatus.error : FileStatus.done,
      error: failed ? 'Broken' : null,
    );
    listener.finished(2, 2, last);
    return [(file: 'a.mp4', status: FileStatus.done, error: null), last];
  }

  @override
  Future<String> runLog({
    required String logPath,
    required String output,
    required String layoutPath,
    required OverlayLook look,
    bool hwAccel = true,
    void Function(double percent)? onProgress,
    void Function(String line)? onMessage,
  }) async {
    logRuns.add((logPath, layoutPath, look));
    onProgress?.call(40);
    seen.add(watch!.currentProgressText);
    return p.join(output, 'dive_x.mov');
  }

  @override
  Future<void> stop() async {
    stopped = true;
    hold?.complete();
  }
}

void main() {
  late Directory tmp;
  late ConfigStore config;
  late BatchGate gate;
  late FakeEngine engine;

  OverlayGeneratorController controller({String? keptLogsDir}) {
    final c = OverlayGeneratorController(
      keptLogsDir: keptLogsDir,
      config: config,
      gate: gate,
      home: '/Users/diver',
      engine: () async => engine,
      picker: TemplatePicker(
        TemplateTree(bundled: DiskTemplateFolder('assets/overlays/templates')),
        tempDir: (prefix) => tmp.createTempSync(prefix),
        templateBytes: (path) async => File(path).readAsBytesSync(),
      ),
      clock: () => 0,
    );
    engine.watch = c;
    return c;
  }

  // A folder of kept logs with one log in it.
  String keptLogs() {
    final kept = Directory(p.join(tmp.path, 'kept_logs'))..createSync();
    File(p.join(kept.path, 'dive.uddf')).writeAsStringSync('<uddf/>');
    return kept.path;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_generator_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    gate = BatchGate();
    engine = FakeEngine();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('the fields: kept under the Python names, legacy labels', () {
    config.updateSettings({
      'fields': {
        hudSourceField: '/media',
        hudLogFileModeField: true,
        hudFilenameFormatField: 'source_filename_hudname',
        hudOverlaySizeField: 'Full frame 4K',
        hudOutputFormatField: 'Video on black (HEVC .mp4)',
        'no_overwrite_switch': true,
      },
    });
    final c = controller();
    expect(c.sourceText, '/media');
    expect(c.logFileMode, isTrue);
    expect(c.filenameFormat, renderLogFormatPresets.first.$1);
    expect(c.overlaySize, 'Full frame 4K');
    expect(c.outputFormat, 'Video on black (HEVC .mp4)');
    expect(c.skipExisting, isTrue);
    expect(c.picker.selectedBrand, isNotNull);

    c
      ..outputText = '/out'
      ..overlaySize = '1080p (template size)';
    expect(config.fields()[hudOutputField], '/out');
    expect(config.fields()[hudOverlaySizeField], '1080p (template size)');
    c.dispose();
  });

  test('the overlay list: a template page, a layout file', () async {
    final c = controller();
    c
      ..selectBrand('garmin')
      ..picker.selectComputer('mk3i')
      ..picker.selectPage('main');
    await c.addOverlay();
    expect(c.overlays.single.label, 'garmin mk3i main single tank');
    expect(File(c.overlays.single.layoutPath).existsSync(), isTrue);
    // The copy is drawn at the watch's real size beside the other
    // computers (spec §10.100): its picture, 692 wide, is 62 mm where a
    // Perdix's 81 mm are a quarter of a 1920 frame. The bundled template
    // keeps its 0.5.
    final copy = jsonDecode(
      File(c.overlays.single.layoutPath).readAsStringSync(),
    ) as Map<String, dynamic>;
    final scale = (copy['hud_skin'] as Map<String, dynamic>)['scale'] as num;
    expect(692 * scale, closeTo(480 * 62 / 81, 1e-6));
    // The picker of the next start is on the overlay added last.
    final next = controller();
    expect(next.picker.selectedBrand, 'garmin');
    expect(next.picker.selectedComputer, 'mk3i');
    expect(next.picker.selectedPage, 'main');
    next.dispose();

    c
      ..selectBrand(layoutCustom)
      ..customPathText = '/my/notes.txt';
    expect(c.isCustom, isTrue);
    await c.addOverlay();
    expect(c.overlays, hasLength(1));
    expect(
      c.statusText,
      'Only a layout file (.json) or a HUD package (.zip) can be added here.',
    );
    // An older HUD package goes in as it is; the run reads it.
    c.customPathText = '/my/Garmin_x50_simple.ZIP';
    await c.addOverlay();
    expect(c.overlays.last, (
      label: 'Garmin_x50_simple',
      layoutPath: '/my/Garmin_x50_simple.ZIP',
    ));
    c.customPathText = '/my/Reef cam.json';
    await c.addOverlay();
    expect(c.overlays.last, (
      label: 'Reef cam',
      layoutPath: '/my/Reef cam.json',
    ));
    c
      ..removeOverlayAt(0)
      ..removeOverlayAt(0);
    expect(c.overlays.single.label, 'Reef cam');
    c.dispose();
  });

  test('the source: a folder, one file, several picked', () {
    final c = controller()..sourceText = '/media';
    expect(c.sourceSummary, '/media');
    c.setSourceFiles(['/media/a.mp4', '/media/b.jpg']);
    expect(c.sourceText, '');
    expect(c.sourceFiles, ['/media/a.mp4', '/media/b.jpg']);
    expect(c.sourceSummary, '2 files in /media');
    expect(c.hasSource, isTrue);
    // Kept for the next start.
    expect(controller().sourceFiles, ['/media/a.mp4', '/media/b.jpg']);
    // One picked file is the source itself; a folder takes the list away.
    c.setSourceFiles(['/media/a.mp4']);
    expect(c.sourceText, '/media/a.mp4');
    expect(c.sourceFiles, isEmpty);
    expect(controller().sourceFiles, isEmpty);
    c.dispose();
  });

  test('a folder run per overlay, with its progress and a failure', () async {
    final c = controller(keptLogsDir: keptLogs());
    await c.startOrStop();
    expect(
      c.statusText,
      startsWith('Nothing to run: choose photos and videos'),
    );
    c
      ..sourceText = '/media'
      ..outputText = '/out'
      ..skipExisting = true
      ..filenameFormat = renderLogFormatPresets.first.$1
      ..outputFormat = 'PNG sequence (folder of frames with alpha)'
      ..overlaySize = 'Full frame 1080p'
      ..overlays.addAll([
        (label: 'one', layoutPath: '/l/one.json'),
        (label: 'two', layoutPath: '/l/two.json'),
      ]);
    engine.failing = 'two.json';
    await c.startOrStop();
    expect(engine.folderRuns, hasLength(2));
    final first = engine.folderRuns.first;
    expect(first.source, '/media');
    expect(first.logsDir, '');
    expect(first.keptLogsDir, keptLogs());
    expect(first.layoutPath, '/l/one.json');
    expect(first.filenameFormat, '{filename}_{hud}');
    expect(first.noOverwrite, isTrue);
    expect(first.look, (
      format: overlayFormatPng,
      size: '1080p',
      fullFrame: true,
    ));
    expect(engine.seen, [
      'Video 1 of 2: a.mp4 | 0 of 4 video renders (2 × 2 overlays)',
      '0.5 0.25',
      'Video 1 of 2: a.mp4 | 2 of 4 video renders (2 × 2 overlays)',
      '0.5 0.75',
    ]);
    expect(c.statusText, 'Done - 1 of 2 overlays failed: two (b.jpg: Broken)');
    expect(c.isRunning, isFalse);
    expect(gate.owner, isNull);
    c.dispose();
  });

  test('the logs kept in the app are what a run reads', () async {
    final kept = Directory(p.join(tmp.path, 'dive_logs'));
    final c = controller(keptLogsDir: kept.path)
      ..sourceText = '/media'
      ..outputText = '/out'
      ..overlays.add((label: 'one', layoutPath: '/l/one.json'));
    expect(c.keptLogsCount, 0);
    await c.startOrStop();
    expect(c.statusText, contains('import dive logs on the Dive Logs page'));
    expect(engine.folderRuns, isEmpty);

    kept.createSync();
    File(p.join(kept.path, 'dive.uddf')).writeAsStringSync('<uddf/>');
    expect(c.keptLogsCount, 1);
    await c.startOrStop();
    expect(engine.folderRuns.single.logsDir, '');
    expect(engine.folderRuns.single.keptLogsDir, kept.path);
    c.dispose();
  });

  test('a whole dive alone, and Stop', () async {
    final log = File(p.join(tmp.path, 'dive.fit'))..writeAsStringSync('x');
    final c = controller(keptLogsDir: keptLogs())
      ..logFileMode = true
      ..outputText = '/out'
      ..overlays.add((label: 'one', layoutPath: '/l/one.json'));
    await c.startOrStop();
    expect(c.statusText, startsWith('Nothing to run: select a dive'));
    c.logFileText = p.join(tmp.path, 'gone.fit');
    await c.startOrStop();
    expect(c.statusText, 'Log file not found: ${p.join(tmp.path, 'gone.fit')}');
    c.logFileText = log.path;
    await c.startOrStop();
    expect(engine.logRuns.single.$1, log.path);
    expect(engine.seen.single, 'Rendering dive.fit - 40 %');
    expect(c.statusText, 'Done');

    c
      ..logFileMode = false
      ..setSourceFiles(['/media/a.mp4', '/media/b.mp4']);
    engine.hold = Completer<void>();
    final run = c.startOrStop();
    await pumpEventQueue();
    await c.startOrStop();
    await run;
    expect(engine.stopped, isTrue);
    expect(engine.folderRuns.single.sourceFiles, [
      '/media/a.mp4',
      '/media/b.mp4',
    ]);
    expect(c.statusText, 'Aborted');
    c.dispose();
  });

  testWidgets('on screen', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: OverlayGeneratorPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: config,
                home: '/Users/diver',
              ),
              setup: (_) async => controller(),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Overlay Generator'), findsOneWidget);
    expect(find.text('Select overlay'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('+ Add'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    // Nothing of the source and output is typed, and no logs folder.
    expect(find.text(chooseMediaLabel), findsOneWidget);
    expect(find.text(saveToLabel), findsOneWidget);
    expect(find.text('Log directory'), findsNothing);
    expect(find.text(noLogsHint), findsOneWidget);
    expect(find.text(diveLogsButtonLabel), findsOneWidget);
    // A whole dive is chosen from the kept logs' dives.
    await tester.tap(find.text('A whole dive'));
    await tester.pumpAndSettle();
    expect(find.text(chooseMediaLabel), findsNothing);
    expect(find.text('No dive logs kept yet'), findsOneWidget);
  });

  test('a whole dive: the kept logs with their first dive', () async {
    final kept = Directory(p.join(tmp.path, 'kept'))..createSync();
    // A Garmin log of the parity fixtures.
    final sources =
        (jsonDecode(
              utf8.decode(
                gzip.decode(
                  File(
                    'test/fixtures/python_reference/dives/'
                    'fit_edit_cases.json.gz',
                  ).readAsBytesSync(),
                ),
              ),
            ) as Map<String, dynamic>)['sources']
            as Map<String, dynamic>;
    File(
      p.join(kept.path, 'reef.fit'),
    ).writeAsBytesSync(base64.decode(sources['nitrox_30_min_later'] as String));
    final c = controller(keptLogsDir: kept.path);
    expect(c.logChoices, isEmpty);
    await c.loadLogChoices();
    expect(c.logChoices.single.path, p.join(kept.path, 'reef.fit'));
    expect(
      c.logChoices.single.label,
      matches(r'^\d{4}-\d\d-\d\d \d\d:\d\d · \d+ min · reef\.fit$'),
    );
    // The picked files are matched to the kept logs' dives before a run
    // (spec §10.67(c)): one taken in the dive, one with no date.
    expect(engine.read, isEmpty);
    final start = c.logChoices.single.label.substring(0, 16);
    engine.tagsOf['in.jpg'] = {
      'EXIF:DateTimeOriginal': '${start.replaceAll('-', ':')}:59',
    };
    final picked = [p.join(tmp.path, 'in.jpg'), p.join(tmp.path, 'out.jpg')];
    for (final file in picked) {
      File(file).writeAsStringSync('x');
    }
    c.setSourceFiles(picked);
    await pumpEventQueue();
    expect(
      diveMatchText(c.diveMatches!),
      'Dive log: $start (reef.fit). 1 of 2 files match no dive log.',
    );
    // A whole dive has no files to match.
    c.logFileMode = true;
    expect(c.diveMatches, isNull);
    c.logFileMode = false;
    expect(c.diveMatches!.unmatched, 1);

    // A kept log stays chosen; one that is not kept (typed in an older
    // version, removed since) is no longer chosen, as the list shows.
    c.logFileText = p.join(kept.path, 'reef.fit');
    await c.loadLogChoices();
    expect(c.logFileText, p.join(kept.path, 'reef.fit'));
    c.logFileText = p.join(tmp.path, 'elsewhere.fit');
    await c.loadLogChoices();
    expect(c.logFileText, '');
    c.dispose();
  });
}
