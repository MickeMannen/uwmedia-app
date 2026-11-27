// The Color page (lib/pages/color/) on a made-up engine, the bundled
// template tree and a temporary folder: the fields it keeps under the
// Python app's names, the source count, the preview of a clip with the
// invented FIT dive of the FIT edit fixture matched to it, the clock offset
// and "Set" from a dive time, adding an overlay from the picker and moving
// and resizing it on the preview, and the settings a run is started with,
// with its progress and the batch gate; then the page on screen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/pages/dive_matches.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/pages/color/color_controller.dart';
import 'package:uwmedia_app/pages/color/color_page.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';

import '../helpers/menus.dart';
import 'photos_test.dart' show FakePhotos;

/// Answers from a script: the clip's tags, size and frames; draws nothing;
/// a run hands its settings over and plays back [script].
class FakeEngine implements ColorPageEngine {
  MediaTags? tags;
  final frames = <double>[];
  final drawn = <List<HudLayerSource>>[];
  final waypoints = <Waypoint?>[];
  ColorBatchSettings? ran;
  void Function(ColorBatchListener listener)? script;
  List<FileResult> results = const [];
  bool stopped = false;

  /// A run ends only when this does.
  Future<void>? hold;

  /// A file's own tags, by its name; the others have [tags].
  final tagsOf = <String, MediaTags?>{};

  /// The files whose tags were asked for.
  final read = <String>[];

  @override
  Future<MediaTags?> metadata(String path) async {
    read.add(p.basename(path));
    return tagsOf.containsKey(p.basename(path))
        ? tagsOf[p.basename(path)]
        : tags;
  }

  @override
  Future<({double fps, int frames})> videoFacts(String path) async =>
      (fps: 25.0, frames: 250);

  @override
  Future<(int, int)> dimensions(String path) async => (1280, 720);

  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds,
    int width,
    int height,
  ) async {
    frames.add(seconds);
    return RgbImage(width, height, Uint8List(width * height * 3));
  }

  @override
  Future<ui.Image> overlaid(
    ui.Image base,
    List<HudLayerSource> layers,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) async {
    drawn.add(layers);
    this.waypoints.add(waypoint);
    return base.clone();
  }

  @override
  Future<List<FileResult>> run(
    ColorBatchSettings settings,
    ColorBatchListener listener,
  ) async {
    ran = settings;
    script?.call(listener);
    await hold;
    return results;
  }

  @override
  Future<void> stop() async => stopped = true;
}

/// Waits until [done] (at most five seconds). The preview is reshaped
/// through `dart:ui`'s pixel decoding, which answers from the engine and
/// not the event queue, so `pumpEventQueue` alone can return before it,
/// as it did under the whole suite's load.
Future<void> _settled(bool Function() done) async {
  final until = DateTime.timestamp().add(const Duration(seconds: 5));
  while (!done() && DateTime.timestamp().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

// The page's work on real files takes real time, which the test's clock
// does not pass: while a frame is still asked for (a spinner turning),
// wait in real time, then settle. With the whole suite running, a fixed
// 300 ms was not always enough and pumpAndSettle timed out on the spinner.
Future<void> _settleReal(WidgetTester tester) async {
  for (var i = 0; i < 100 && tester.binding.hasScheduledFrame; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  final fixture = jsonDecode(
    utf8.decode(
      gzip.decode(
        File('test/fixtures/python_reference/dives/fit_edit_cases.json.gz')
            .readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;
  final fit = base64.decode(
    (fixture['sources'] as Map<String, dynamic>)['air'] as String,
  );
  final dive = parseLogFile('/x/dive.fit', fit)!.single;
  final profiles = mergedColorProfiles(
    File('assets/color.yaml').readAsStringSync(),
    null,
  );

  late Directory tmp;
  late ConfigStore config;
  late BatchGate gate;
  late FakeEngine engine;
  late String media;
  late String logs;
  late String clip;

  ColorController controller({
    Future<RgbImage> Function((ColorProfile, RgbImage) job)? correct,
    WatermarkStore? watermarks,
    bool compareOffered = false,
    Future<int?> Function(String dir)? freeSpace,
  }) => ColorController(
    compareOffered: compareOffered,
    freeSpace: freeSpace,
    correct: correct,
    watermarkStore: watermarks,
    config: config,
    gate: gate,
    home: '/Users/diver',
    engine: () async => engine,
    profiles: profiles,
    templates: TemplateTree(
      bundled: DiskTemplateFolder('assets/overlays/templates'),
    ),
    tempDir: (prefix) => (Directory(
      p.join(tmp.path, 'work'),
    )..createSync()).createTempSync(prefix),
    templateBytes: (path) async => File(path).readAsBytesSync(),
    clock: () => 0,
    now: () => naive(2026, 1, 1),
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_color_page_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    gate = BatchGate();
    engine = FakeEngine();
    media = (Directory(p.join(tmp.path, 'media'))..createSync()).path;
    logs = (Directory(p.join(tmp.path, 'logs'))..createSync()).path;
    File(p.join(logs, 'dive.fit')).writeAsBytesSync(fit);
    // First by name: the clip the preview shows.
    clip = p.join(media, 'Abyss.MP4');
    File(clip).writeAsStringSync('not decoded here');
    File(p.join(media, 'Fish.jpg')).writeAsStringSync('x');
    File(p.join(media, 'Crab.JPG')).writeAsStringSync('x');
    File(p.join(media, '.hidden')).writeAsStringSync('x');
    // The clip begins two minutes into the dive, on the camera's clock.
    final start = dive.startTime.add(const Duration(minutes: 2));
    engine.tags = {
      'QuickTime:CreationDate':
          '${pyStrftime(start, '%Y:%m:%d %H:%M:%S')}+00:00',
    };
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('the fields: kept under the Python names, restored, legacy', () {
    config.updateSettings({
      'fields': {
        sourceField: media,
        outputField: '/out',
        colorSwitchField: false,
        noOverwriteField: true,
        colorProfileField: 'vivid',
        offsetHoursField: 2,
        offsetSecondsField: -12.5,
        filenameFormatField: 'Date taken',
        overlaysField: [
          {'layout_path': '/gone.json', 'label': 'gone'},
        ],
      },
    });
    final c = controller();
    expect(c.sourceText, media);
    expect(c.outputText, '/out');
    expect(c.colorChecked, isFalse);
    expect(c.hwAccel, isTrue);
    expect(c.skipExisting, isTrue);
    expect(c.colorProfile, 'vivid');
    expect(c.offsetHours, 2);
    expect(c.offsetSeconds, -12.5);
    expect(c.filenameFormat, 'Date + time (20260905_143000)');
    expect(c.overlays, isEmpty);
    expect(c.sourceCountText, '1 video, 2 photos found');
    expect(
      c.offsetText,
      "+1 h 59 min 48 s added to every file's time before it is matched to "
      'the log',
    );

    c
      ..colorChecked = true
      ..skipExisting = false
      ..filenameFormat = c.filenameFormatList[1];
    expect(config.fields()[colorSwitchField], isTrue);
    expect(config.fields()[noOverwriteField], isFalse);
    expect(config.fields()[filenameFormatField], c.filenameFormatList[1]);
    c.dispose();
  });

  testWidgets('the preview shows the colour correction', (tester) async {
    await tester.runAsync(() async {
      Future<List<int>> firstPixel(ui.Image image) async {
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        return data!.buffer.asUint8List(0, 3);
      }

      final asked = <String>[];
      final c = controller(
        correct: (job) async {
          final (profile, image) = job;
          asked.add('${image.width}x${image.height}');
          return RgbImage(
            image.width,
            image.height,
            Uint8List.fromList([
              for (var i = 0; i < image.width * image.height; i++) ...[
                10,
                200,
                30,
              ],
            ]),
          );
        },
      );
      await c.setSource(media);
      expect(c.colorChecked, isTrue);
      expect(await firstPixel(c.previewImage!), [10, 200, 30]);
      final original = await firstPixel(c.originalImage!);
      expect(original, isNot([10, 200, 30]));

      // The same frame and profile: corrected once, however often drawn.
      final corrections = asked.length;
      await c.nudgeOffset(60);
      expect(asked, hasLength(corrections));

      // Switched off: the frame as it is.
      c.colorChecked = false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await firstPixel(c.previewImage!), original);
      c.dispose();
    });
  });

  test('the dives of all the files, and those with none', () async {
    // The matches only: the preview's colour correction (seconds a frame,
    // past the time limit on the Windows runner) left out.
    final c = controller(correct: (job) async => job.$2);
    await c.setSource(media);
    // No log read: nothing to say of the files, and only the preview's
    // is read.
    await pumpEventQueue();
    expect(c.diveMatches, isNull);
    expect(engine.read, ['Abyss.MP4']);
    expect(c.divesLoading, isFalse);

    // While the logs are read the page says so, and the matches wait
    // (spec §10.89: a phone shows the page before its kept logs are read).
    final reading = c.setLogs(logs);
    expect(c.divesLoading, isTrue);
    expect(c.diveMatchesPending, isTrue);
    await reading;
    expect(c.divesLoading, isFalse);
    await pumpEventQueue();
    expect(c.diveMatches!.dives, [c.matchedDive!]);
    expect((c.diveMatches!.files, c.diveMatches!.unmatched), (3, 0));
    expect(
      diveMatchText(c.diveMatches!),
      'Dive log: ${pyStrftime(dive.startTime, '%Y-%m-%d %H:%M')} (dive.fit)',
    );

    // A photo of the day before, and one with no date to be had: neither
    // has a dive. Only the files not read before are read.
    final before = dive.startTime.subtract(const Duration(days: 1));
    engine.tagsOf['Old.jpg'] = {
      'EXIF:DateTimeOriginal': pyStrftime(before, '%Y:%m:%d %H:%M:%S'),
    };
    engine.tagsOf['Blank.jpg'] = null;
    final picked = [clip, p.join(media, 'Old.jpg'), p.join(media, 'Blank.jpg')];
    for (final file in picked.skip(1)) {
      File(file).writeAsStringSync('x');
    }
    await c.setSourceFiles(picked);
    await pumpEventQueue();
    final matches = c.diveMatches!;
    expect((matches.files, matches.unmatched), (3, 2));
    expect(
      diveMatchText(matches),
      endsWith('(dive.fit). 2 of 3 files match no dive log.'),
    );

    // The clock offset moves every file: a day on, the old photo is in
    // the dive and the clip is not.
    await c.setOffsetHours(24);
    expect(c.diveMatches!.unmatched, 2);
    expect(c.matchedDive, isNull);
    c.dispose();
  });

  test('several photos: the slider goes through them', () async {
    final c = controller(correct: (job) async => job.$2);
    await c.setLogs(logs);
    final inDive = dive.startTime.add(const Duration(minutes: 2));
    final before = dive.startTime.subtract(const Duration(days: 1));
    engine.tagsOf['One.jpg'] = {
      'EXIF:DateTimeOriginal': pyStrftime(before, '%Y:%m:%d %H:%M:%S'),
    };
    engine.tagsOf['Two.jpg'] = {
      'EXIF:DateTimeOriginal': pyStrftime(inDive, '%Y:%m:%d %H:%M:%S'),
    };
    final photos = [p.join(media, 'One.jpg'), p.join(media, 'Two.jpg')];
    for (final file in photos) {
      File(file).writeAsStringSync('x');
    }
    await c.setSourceFiles(photos);
    await pumpEventQueue();
    expect((c.scrubEnabled, c.scrubMaximum, c.scrubValue), (true, 1, 0));
    expect((c.scrubFrom, c.scrubUntil), (0, 1));
    expect(c.scrubTimeText, 'One.jpg · 1 of 2');
    expect(c.matchedDive, isNull);

    // The second photo: its own date, and so its dive.
    await c.scrubTo(1);
    expect(c.scrubValue, 1);
    expect(c.scrubTimeText, 'Two.jpg · 2 of 2');
    expect(c.matchedDive, isNotNull);
    expect(c.matchTime, inDive);

    // It stays the one shown when the preview is read again.
    await c.refreshPreview();
    expect(c.scrubTimeText, 'Two.jpg · 2 of 2');

    // A video first: the slider is the video's.
    await c.setSourceFiles([clip, ...photos]);
    await pumpEventQueue();
    expect(c.scrubTimeText, isNot(contains(' of ')));
    c.dispose();
  });

  test('the room the results take, and too little of it', () async {
    int? free = 500000000000;
    final asked = <String>[];
    final c = controller(
      correct: (job) async => job.$2,
      freeSpace: (dir) async {
        asked.add(dir);
        return free;
      },
    );
    final photos = [p.join(media, 'One.jpg'), p.join(media, 'Two.jpg')];
    for (final file in photos) {
      File(file).writeAsBytesSync(Uint8List(3000000));
    }
    await c.setSourceFiles(photos);
    await pumpEventQueue();
    // No output yet: nothing to say.
    expect(c.spaceText, '');

    // An output that is not there yet: the disk of the folder above it.
    c.setOutput(p.join(tmp.path, 'results', 'today'));
    await pumpEventQueue();
    expect(asked.last, tmp.path);
    expect(c.spaceText, 'About 7 MB needed, 500.0 GB free');
    expect(c.spaceShort, isFalse);

    // Without the colour correction the photos are copied.
    c.colorChecked = false;
    expect(c.spaceText, 'About 6 MB needed, 500.0 GB free');
    c.colorChecked = true;

    // Too little room, then a disk that does not tell.
    free = 2000000;
    c.setOutput(p.join(tmp.path, 'elsewhere'));
    await pumpEventQueue();
    expect(c.spaceText, 'About 7 MB needed, only 2 MB free on this disk');
    expect(c.spaceShort, isTrue);
    free = null;
    c.setOutput(p.join(tmp.path, 'results'));
    await pumpEventQueue();
    expect(c.spaceText, 'About 7 MB needed');
    expect(c.spaceShort, isFalse);
    c.dispose();
  });

  testWidgets('the preview: a frame, the dive, the offset, Set', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final c = controller();
      await c.setLogs(logs);
      await c.setSource(media);
      expect(c.scrubEnabled, isTrue);
      expect(c.scrubValue, 10);
      expect(c.scrubMaximum, 249);
      expect(c.scrubTimeText, '0:00:00');
      expect(engine.frames.single, 10 / 25);
      expect(c.viewWidth, 1920);
      expect(c.viewHeight, 1080);
      expect(c.previewImage, isNotNull);
      expect(c.matchedDive?.startTime, dive.startTime);
      final at = c.matchedWaypoint!.timestamp;
      expect(
        at.difference(dive.startTime).inSeconds,
        inInclusiveRange(120, 150),
      );
      expect(c.canSync, isTrue);

      // A minute on: a later sample.
      await c.nudgeOffset(60);
      expect(c.matchedWaypoint!.timestamp.isAfter(at), isTrue);
      await c.resetOffset();

      // The computer in this frame shows 4:00: the clip is two minutes
      // ahead of the file's time (it began at 2:00 into the dive).
      expect(await c.syncToDiveTime('4:00'), isTrue);
      expect(c.offsetSeconds, closeTo(120 - 0.4, 1e-6));
      expect(c.statusText, startsWith('Synced: this frame is dive time 4:00'));
      expect(await c.syncToDiveTime('soon'), isFalse);
      expect(c.statusText, "Not a dive time: 'soon' (use mm:ss)");

      await c.scrubTo(100);
      expect(engine.frames.last, 4.0);
      expect(c.scrubTimeText, '0:00:04');

      // Far from any dive: no match, the overlays drawn for a made-up
      // sample.
      await c.setOffsetHours(-12);
      expect(c.matchedDive, isNull);
      c.dispose();
    });
  });

  testWidgets('an overlay: picked, placed, moved, resized, kept', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final c = controller();
      await c.setSource(media);
      expect(c.picker.brandChoices, containsPair('Garmin', 'garmin'));
      c.picker.reset();
      expect(c.picker.selectedBrand, isNotNull);
      c.picker.selectBrand('garmin');
      // Two Garmin computers in the bundled tree: the picker asks which.
      expect(c.picker.computerVisible, isTrue);
      c.picker
        ..selectComputer('mk3i')
        ..selectPage('main');
      expect(c.picker.variantChoices.values, contains('single_tank'));
      expect(c.picker.selectedVariant, 'single_tank');
      expect(await c.addPickedOverlay(), isTrue);
      final overlay = c.overlays.single;
      expect(overlay.label, startsWith('Garmin'));
      expect(
        p.basename(overlay.layoutPath),
        'garmin_mk3i_main_single_tank.json',
      );
      expect(File(overlay.layoutPath).existsSync(), isTrue);
      // The skin travels with the copy.
      final copied = jsonDecode(
        File(overlay.layoutPath).readAsStringSync(),
      ) as Map<String, dynamic>;
      final skin =
          (copied['hud_skin'] as Map<String, dynamic>)['path'] as String;
      expect(
        File(p.join(p.dirname(overlay.layoutPath), skin)).existsSync(),
        isTrue,
      );
      // Bottom left.
      final (x0, y0, x1, y1) = c.boxOf(overlay)!;
      expect(x0, 0);
      expect(y1, closeTo(1080, 1));
      expect(engine.drawn.last, hasLength(1));

      // Click inside: selected and moved by a tenth of the frame.
      c.pressAt(x0 + 10.0, y0 + 10.0, 16);
      expect(c.selectedOverlay, same(overlay));
      final drawnBefore = engine.drawn.length;
      c.dragTo(x0 + 10.0 + 192, y0 + 10.0 - 108);
      expect(overlay.x, closeTo(0.1, 1e-9));
      expect(overlay.y, closeTo(y0 / 1080 - 0.1, 1e-9));
      // Drawn again while it is dragged, not only when let go: the box
      // and the overlay go together.
      await pumpEventQueue();
      expect(engine.drawn.length, greaterThan(drawnBefore));
      await c.release();

      // It started at the watch's own size beside the other computers
      // (spec §10.100): 62 mm where a Perdix's 81 mm are a quarter of the
      // frame, on a picture 692 wide drawn at the template's 0.5.
      final start = overlay.scale;
      expect(start, closeTo(62 * 0.25 / 81 * 1920 / (692 * 0.5), 1e-9));

      // The bottom-right handle: twice as far from the top left.
      final box = c.boxOf(overlay)!;
      c.pressAt(box.$3.toDouble(), box.$4.toDouble(), 16);
      c.dragTo(
        box.$1 + 2.0 * (box.$3 - box.$1),
        box.$2 + 2.0 * (box.$4 - box.$2),
      );
      expect(overlay.scale, closeTo(2 * start, 0.01));
      expect(overlay.x, closeTo(box.$1 / 1920, 1e-9));
      await c.release();

      // Kept and restored by the next page.
      final next = controller();
      expect(next.overlays.single.layoutPath, overlay.layoutPath);
      expect(next.overlays.single.scale, closeTo(2 * start, 0.01));

      // "Add Overlay" opens on the page added last, in the next page too
      // (spec §10.62); what is no longer there gives way to the first.
      final added = Map<String, String>.of(c.picker.choice);
      expect(added['brand'], 'garmin');
      c.picker.reset();
      c.openPicker();
      expect(c.picker.choice, added);
      next.openPicker();
      expect(next.picker.choice, added);
      next.picker.restore({...added, 'variant': 'gone'});
      expect(next.picker.selectedPage, added['page']);
      expect(next.picker.selectedVariant, 'single_tank');
      next.picker.restore({...added, 'brand': 'gone'});
      expect(next.picker.selectedBrand, next.picker.brandChoices.values.first);
      next.picker.restore('nothing kept');
      expect(next.picker.selectedBrand, next.picker.brandChoices.values.first);

      // A click outside every overlay clears the selection.
      c.pressAt(1900, 10, 16);
      expect(c.selectedOverlay, isNull);
      await c.removeOverlayAt(0);
      expect(c.overlays, isEmpty);
      c.dispose();
      next.dispose();
    });
  });

  test('a shape, a window and a part: with one file only', () async {
    final c = controller(correct: (job) async => job.$2);
    await c.setSource(clip);
    expect(c.canShape, isTrue);
    expect(c.canTrim, isTrue);
    c.pictureShape = ShareShape.portraitCropped;
    c.setPart(2, 6);
    await pumpEventQueue();
    expect(c.cropFrame, isNotNull);
    expect(c.outputSizeChoice, isNotNull);
    // With bars there is nothing to place.
    c.pictureShape = ShareShape.portraitBars;
    expect(c.cropFrame, isNull);
    expect(c.canCrop, isFalse);
    c.pictureShape = ShareShape.portraitCropped;

    // A second file (owner, 2026-11-19): each is written as it is.
    final read = c.setSource(media);
    expect(c.previewLoading, isTrue);
    await read;
    expect(c.canShape, isFalse);
    expect(c.canCrop, isFalse);
    expect(c.canTrim, isFalse);
    expect(c.trimmed, isFalse);
    expect(c.pictureShape, ShareShape.asShot);
    expect(c.cropFrame, isNull);
    expect(c.outputCropped, isFalse);
    expect(c.outputSizeChoice, isNull);
    expect(c.previewLoading, isFalse);
    c.dispose();
  });

  test('before and after: on a computer, one file, with the color', () async {
    // Spec §10.94.
    final phone = controller(correct: (job) async => job.$2);
    expect(phone.compareOffered, isFalse);
    expect(phone.canCompare, isFalse);
    expect(phone.compareChoice, isNull);
    phone.dispose();

    final c = controller(correct: (job) async => job.$2, compareOffered: true);
    await c.setSource(clip);
    c.colorChecked = true;
    expect(c.canCompare, isTrue);
    expect(c.compare, compareOffLabel);
    expect(c.compareChoice, isNull);
    // A video is split; the wipe videos are a photo's.
    expect(c.compareList, [
      compareOffLabel,
      'Split, left and right',
      'Split, above and below',
      'Split, diagonal',
    ]);
    c.compare = 'Wipe video, diagonal';
    expect(c.compare, compareOffLabel);
    c.compare = 'Split, diagonal';
    await pumpEventQueue();
    expect(c.compareChoice, const Compare(CompareKind.diagonal));
    expect(c.previewImage, isNotNull);
    // Nothing to compare without the correction.
    c.colorChecked = false;
    expect(c.canCompare, isFalse);
    expect(c.compare, compareOffLabel);
    expect(c.compareChoice, isNull);
    c.colorChecked = true;
    expect(c.compareChoice, const Compare(CompareKind.diagonal));
    // Several files: each is written as it is.
    await c.setSource(media);
    expect(c.canCompare, isFalse);
    expect(c.compareChoice, isNull);
    c.dispose();
  });

  test('an output size: the preview shows the crop, the run gets it', () async {
    final c = controller(correct: (job) async => job.$2);
    await c.setSource(clip);
    expect(c.outputSize, originalSizeLabel);
    expect(c.outputSizeChoice, isNull);
    expect(c.outputSizeList, [
      originalSizeLabel,
      '1080p',
      '720p',
      '480p',
      '360p',
      'WhatsApp',
      'WeChat',
      'Instagram / Facebook',
    ]);
    expect(c.outputSizeText, originalSizeLabel);
    expect(c.pictureShape, ShareShape.asShot);
    expect(c.pictureText, 'As shot, the whole picture');
    expect(c.outputCropped, isFalse);
    final (wideW, wideH) = (c.viewWidth, c.viewHeight);
    expect(wideW / wideH, closeTo(16 / 9, 0.01));

    // A resolution changes nothing on the preview.
    c.outputSize = '720p';
    await pumpEventQueue();
    expect((c.viewWidth, c.viewHeight), (wideW, wideH));
    expect(c.outputPortrait, isFalse);

    // Zoomed in as shot (spec §10.75): the preview is the window, of the
    // picture's own shape; the videos' own size then has a size to give.
    c.outputSize = originalSizeLabel;
    c.setCrop(size: 0.5);
    await _settled(() => c.viewWidth < wideW);
    expect(c.viewWidth / c.viewHeight, closeTo(16 / 9, 0.01));
    expect(c.viewWidth, closeTo(wideW / 2, 2));
    expect(c.outputCropped, isTrue);
    expect(c.pictureText, 'As shot, 50 % of the picture');
    final zoomed = c.outputSizeChoice!;
    expect((zoomed.resolution, zoomed.share), (null, null));
    final cut = zoomed.frameFor(3840, 2160, sourceBitrate: 80000000)!;
    expect((cut.crop!.width, cut.crop!.height), (1920, 1080));
    expect((cut.width, cut.height, cut.bitrate), (1920, 1080, 20000000));
    c.clearCrop();
    await _settled(() => c.viewWidth == wideW);
    expect(c.outputSizeChoice, isNull);

    // Portrait, cropped: the preview is the 9:16 window of the frame,
    // whatever the size.
    bool portrait() => (c.viewWidth / c.viewHeight - 9 / 16).abs() < 0.01;
    c.pictureShape = ShareShape.portraitCropped;
    await _settled(portrait);
    expect(c.outputSizeChoice!.cut.shape, ShareShape.portraitCropped);
    c.outputSize = instagramSizeLabel;
    expect(c.outputCropped, isTrue);
    // The window is placed on the whole frame, as it was grabbed.
    expect(c.cropFrame!.width / c.cropFrame!.height, closeTo(16 / 9, 0.01));
    expect(c.outputSizeText, instagramSizeLabel);
    expect(c.pictureText, 'Portrait, cut out of the picture');
    expect(c.viewHeight, wideH);
    expect(c.viewWidth / c.viewHeight, closeTo(9 / 16, 0.01));
    c.setCrop(at: 0.1);
    await pumpEventQueue();
    // Scrubbed, the new frame is cropped the same.
    await c.scrubTo(100);
    await _settled(portrait);
    expect(c.viewWidth / c.viewHeight, closeTo(9 / 16, 0.01));

    // With bars the whole frame is back.
    c.pictureShape = ShareShape.portraitBars;
    await _settled(() => (c.viewWidth, c.viewHeight) == (wideW, wideH));
    expect((c.viewWidth, c.viewHeight), (wideW, wideH));
    expect(c.cropFrame, isNull);
    expect(c.pictureText, 'Portrait, the whole picture between bars');
    // A landscape or a square window out of the picture (owner,
    // 2026-11-19).
    c.pictureShape = ShareShape.squareCropped;
    expect(c.canCrop, isTrue);
    expect(c.cropAspect, 1);
    expect(c.outputCropped, isTrue);
    expect(c.outputPortrait, isFalse);
    expect(c.pictureText, 'Square, cut out of the picture');
    c.pictureShape = ShareShape.landscapeCropped;
    expect(c.cropAspect, landscapeAspect);
    expect(c.pictureText, 'Landscape, cut out of the picture');
    c.pictureShape = ShareShape.portraitCropped;
    c.setCrop(at: 0.1);

    // A part of the video (spec §10.71): ten seconds long here, never
    // shorter than a second, and the preview goes to the end that moved.
    expect(c.canTrim, isTrue);
    expect(c.videoSeconds, 10);
    expect(c.trimmed, isFalse);
    expect(c.partText, 'The whole video');
    c.setPart(0, 6);
    await pumpEventQueue();
    expect(c.scrubValue, 150);
    c.setPart(2, 6);
    expect(c.part, (start: 2.0, end: 6.0));
    expect(c.partText, '0:02.0 to 0:06.0 (4.0 s)');
    await pumpEventQueue();
    expect(c.scrubValue, 50);
    // The scrub slider goes over the part alone, and the part is set to
    // the frame shown, which stays (spec §10.75).
    expect((c.scrubFrom, c.scrubUntil), (50, 150));
    await c.scrubTo(80);
    c.partStartHere();
    expect(c.part, (start: 3.2, end: 6.0));
    expect(c.scrubValue, 80);
    await c.scrubTo(120);
    c.partEndHere();
    expect(c.part, (start: 3.2, end: 4.8));
    expect(c.partText, '0:03.2 to 0:04.8 (1.6 s)');
    expect(c.scrubValue, 120);
    // A second more at an end: the frame there is shown.
    c.extendPart(atStart: false);
    expect(c.part.end, closeTo(5.8, 1e-9));
    await pumpEventQueue();
    expect(c.scrubValue, 145);
    c.extendPart(atStart: true);
    expect(c.part.start, closeTo(2.2, 1e-9));
    c.setPart(2, 2.2);
    expect(c.part, (start: 2.0, end: 3.0));
    // The part's slider shows the whole video until an end is let go,
    // then the part with five seconds around it; an end dragged into
    // those makes the part longer, and the slider follows when it is
    // let go again.
    expect((c.partFrom, c.partUntil), (0.0, 10.0));
    c.setPart(6, 7.5);
    c.settlePartView();
    expect((c.partFrom, c.partUntil), (1.0, 10.0));
    c.setPart(1.5, 7.5);
    expect(c.partFrom, 1.0);
    c.settlePartView();
    expect(c.partFrom, 0.0);
    c.setPart(0, 10);
    expect(c.trimmed, isFalse);
    c.setPart(2, 6);

    c.setOutput('/out');
    await c.startOrStop();
    expect(engine.ran!.parts.values.single, (start: 2.0, end: 6.0));
    expect(partOf(engine.ran!, engine.ran!.parts.keys.single), (
      start: 2.0,
      end: 6.0,
    ));
    expect(partOf(engine.ran!, '/other.mp4'), isNull);
    final size = engine.ran!.outputSize!;
    expect(size.share!.size, shareInstagram);
    expect(size.share!.shape, ShareShape.portraitCropped);
    expect(size.share!.cropAt, 0.1);

    // The file gone: no part, and the slider's ends read without a frame
    // (they threw "Invalid argument(s): 0" while the page was laid out).
    await c.setSource('');
    await pumpEventQueue();
    expect(c.scrubMaximum, 0);
    expect(c.trimmed, isFalse);
    expect((c.scrubFrom, c.scrubUntil), (0, 0));
    c.dispose();
  });

  test('the watermark: chosen, kept, on the preview and in the run', () async {
    final store = WatermarkStore(
      config,
      Directory(p.join(tmp.path, 'data', 'watermarks')),
    )..addText('© Diver');
    final c = controller(watermarks: store, correct: (job) async => job.$2);
    expect(c.watermarkList, ['© Diver']);
    expect(c.isWatermarkOn('© Diver'), isFalse);
    expect(controller().watermarkList, isEmpty, reason: 'no store, none');

    await c.setSource(media);
    c.setOutput(p.join(tmp.path, 'out'));
    final before = engine.drawn.length;
    c.setWatermark('© Diver', true);
    for (var i = 0; i < 100 && engine.drawn.length == before; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(config.fields()[watermarkSelectField], ['© Diver']);
    expect(c.isWatermarkOn('© Diver'), isTrue);
    // Drawn on the preview with no overlay and no dive.
    expect(engine.drawn.length, before + 1);
    expect(engine.drawn.last.single.always, isTrue);

    await c.startOrStop();
    expect(engine.ran!.watermarks.single.always, isTrue);
    expect(engine.ran!.overlays, isEmpty);

    // A second one with it (owner, 2026-11-16): both on the preview and
    // in the run, in the list's order.
    store.addText('Second');
    c
      ..watermarksChanged()
      ..setWatermark('Second', true);
    for (var i = 0; i < 100 && engine.drawn.last.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.drawn.last, hasLength(2));
    await c.startOrStop();
    expect(
      [
        for (final mark in engine.ran!.watermarks)
          jsonEncode(mark.layout).contains('custom:Second'),
      ],
      [false, true],
    );
    c.setWatermark('Second', false);
    await c.startOrStop();
    expect(engine.ran!.watermarks, hasLength(1));

    // Taken away on the Settings page: none again.
    store.remove('© Diver');
    c.watermarksChanged();
    expect(c.isWatermarkOn('© Diver'), isFalse);
    await c.startOrStop();
    expect(engine.ran!.watermarks, isEmpty);
    c.dispose();
  });

  test('a watermark dragged on the preview: for the session only', () async {
    final store = WatermarkStore(
      config,
      Directory(p.join(tmp.path, 'data', 'watermarks')),
    )..addText('© Diver');
    final c = controller(watermarks: store, correct: (job) async => job.$2);
    await c.setSource(media);
    c
      ..setOutput(p.join(tmp.path, 'out'))
      ..setWatermark('© Diver', true);
    await pumpEventQueue();
    final mark = store.selected.single;
    expect(mark.place, (x: 1.0, y: 1.0));
    final (w, h) = (c.viewWidth, c.viewHeight);
    final (shareW, shareH) = watermarkShare(mark);
    final (x0, y0) = watermarkCorner(mark.place, w, h, shareW * w, shareH * w);

    // Pressed on the mark: taken, its box drawn while it moves.
    c.pressAt(x0 + 5, y0 + 5, 16);
    expect(c.dragging, isTrue);
    expect(c.selectedOverlay, isNull);
    expect(c.markDragBox!.$1, x0.round());
    final drawn = engine.drawn.length;
    // To the left edge, and taken onto it.
    c.dragTo(x0 + 5 - w, y0 + 5);
    await pumpEventQueue();
    expect(engine.drawn.length, greaterThan(drawn));
    expect(c.markDragBox!.$1, (watermarkMargin * w).round());
    await c.release();
    expect(c.dragging, isFalse);
    expect(c.markDragBox, isNull);
    expect(c.watermarksMoved, isTrue);

    // The run puts it where it was dragged; Settings keeps its own.
    await c.startOrStop();
    expect(
      jsonEncode(engine.ran!.watermarks.single.layout),
      contains('BOTTOM_LEFT'),
    );
    expect(store.selected.single.place, (x: 1.0, y: 1.0));

    // A press beside it moves nothing.
    c.pressAt(w / 2, h / 2, 16);
    expect(c.dragging, isFalse);

    // Put back.
    c.resetWatermarkPlaces();
    expect(c.watermarksMoved, isFalse);
    await c.startOrStop();
    expect(
      jsonEncode(engine.ran!.watermarks.single.layout),
      contains('BOTTOM_RIGHT'),
    );
    c.dispose();
  });

  test('a run: its settings, progress, the end, Stop, the gate', () async {
    // The preview's colour as it comes: the real correction of a 1080p
    // frame took 19 s on the Windows runner (roadmap E18), and the run's
    // settings are what is checked here.
    final c = controller(correct: (job) async => job.$2);
    await c.startOrStop();
    expect(
      c.statusText,
      'Nothing to run: select a source file or folder and an output first.',
    );
    await c.setSource(media);
    c
      ..setOutput(p.join(tmp.path, 'out'))
      ..filenameFormat = 'Date + time + color (20260905_143000_color)'
      ..colorProfile = 'vivid';
    await c.setLogs(logs);
    await c.setOffsetHours(1);
    final seen = <String>[];
    engine.script = (listener) {
      listener
        ..started(3)
        ..active('a.mp4')
        ..progress('a.mp4', 50);
      seen.add('${c.filesTotal} ${c.activeFiles} ${c.currentFraction}');
      listener
        ..finished(1, 3, (file: 'a.mp4', status: FileStatus.done, error: null))
        ..message('Warning: something');
      seen.add(c.statusText);
    };
    engine.results = const [
      (file: 'a.mp4', status: FileStatus.done, error: null),
      (file: 'b.jpg', status: FileStatus.skipped, error: null),
      (file: 'c.jpg', status: FileStatus.done, error: null),
    ];
    await c.startOrStop();
    final s = engine.ran!;
    expect(s.source, media);
    expect(s.logsDir, logs);
    expect(s.filenameFormat, '%Y%m%d_%H%M%S_color');
    expect(s.colorProfileName, 'vivid');
    expect(s.colorProfile, isNotNull);
    expect(s.mediaShiftSeconds, 3600);
    expect(s.hwAccel, isTrue);
    expect(seen, ['3 [a.mp4] ${50 / 300}', 'Processing — 1 of 3 files done…']);
    expect(c.statusText, 'Finished: 2 done, 1 skipped');
    expect(c.messages, ['Warning: something']);
    expect(gate.owner, isNull);

    // "Original" keeps the names; colour off sends no profile.
    c
      ..filenameFormat = c.filenameFormatList.first
      ..colorChecked = false;
    engine
      ..script = null
      ..results = const [
        (file: 'a.mp4', status: FileStatus.error, error: 'Broken'),
      ];
    await c.startOrStop();
    expect(engine.ran!.filenameFormat, isNull);
    expect(engine.ran!.colorProfile, isNull);
    expect(c.statusText, '1 of 1 file failed: a.mp4 (Broken)');

    // Another page holds the gate: nothing starts.
    expect(gate.enter('Resize'), isTrue);
    engine.ran = null;
    await c.startOrStop();
    expect(engine.ran, isNull);
    c.dispose();
  });

  test('Stop while the tools are still being found', () async {
    final found = Completer<ColorPageEngine>();
    final c = ColorController(
      config: config,
      gate: gate,
      home: '/Users/diver',
      engine: () => found.future,
      profiles: profiles,
      templates: TemplateTree(),
      tempDir: (prefix) => tmp.createTempSync(prefix),
      clock: () => 0,
    );
    // The preview waits for the tools too.
    final preview = c.setSource(media);
    c.setOutput(p.join(tmp.path, 'out'));
    final run = c.startOrStop();
    final stop = c.startOrStop();
    expect(c.statusText, 'Stopping…');
    found.complete(engine);
    await stop;
    await run;
    expect(engine.ran, isNull);
    expect(engine.stopped, isTrue);
    expect(c.statusText, 'Stopped');
    expect(gate.owner, isNull);
    await preview;
    c.dispose();
  });

  testWidgets('the scrub slider follows at once; frames one at a time', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final c = controller();
      await c.setSource(media);
      final asked = engine.frames.length;
      final first = c.scrubTo(50);
      final second = c.scrubTo(60);
      final third = c.scrubTo(70);
      // The slider and its time are there before any frame.
      expect(c.scrubValue, 70);
      expect(c.scrubTimeText, '0:00:02');
      await Future.wait([first, second, third]);
      // The first frame, then only the last one asked for.
      expect(engine.frames.sublist(asked), [2.0, 2.8]);
      c.dispose();
    });
  });

  testWidgets('Apple Photos as the source and the output (spec §10.50)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    config.updateSettings({
      'fields': {sourceField: media, outputField: '/out'},
    });
    final library = Directory(p.join(tmp.path, 'library'))..createSync();
    final photos = FakePhotos()
      ..offered = [
        (File(p.join(library.path, 'IMG_7.JPG'))..writeAsStringSync('x')).path,
      ];
    late ColorController made;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ColorPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: config,
                home: '/Users/diver',
                tempDir: (prefix) => tmp.createTempSync(prefix),
              ),
              // The places only: the preview's colour correction (seconds on a
              // busy runner, which pumpAndSettle waited out) left out.
              setup: (_) async =>
                  made = controller(correct: (job) async => job.$2),
              photos: photos,
              dialogs: _PickedDialogs([
                p.join(media, 'Abyss.MP4'),
                p.join(media, 'Fish.jpg'),
              ]),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settleReal(tester);
    // Nothing is typed: the source and the output are buttons, the
    // output's place under its own.
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(OutlinedButton, saveToLabel), findsOneWidget);
    expect(find.text('/out'), findsOneWidget);
    await choosePlace(
      tester,
      find.text(chooseMediaLabel),
      photoLibraryPlaceLabel,
      real: true,
    );
    expect(find.text('1 item from Photos'), findsOneWidget);
    expect(p.basename(made.sourceText), startsWith('uwmedia_picked_'));

    await choosePlace(tester, find.text(saveToLabel), saveToAlbumChoice);
    // The album asked for, as on a phone (owner, 2026-11-19).
    await tester.enterText(find.byType(TextField), 'Dives');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('The album "Dives" in Photos'), findsOneWidget);
    expect(p.basename(made.outputText), startsWith('uwmedia_photos_out_'));
    // The settings keep the folders of before, not the working ones.
    expect(config.fields()[sourceField], media);
    expect(config.fields()[outputField], '/out');

    // A run into Photos: its result goes into an album, and the run's
    // folder is the working one (owner, 2026-11-19: a run on the Mac
    // wrote into the folder of before).
    engine.script = (_) =>
        File(p.join(engine.ran!.output, 'IMG_7_color.jpg'))
            .writeAsStringSync('x');
    await tester.runAsync(() async {
      await made.startOrStop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settleReal(tester);
    expect(p.basename(engine.ran!.output), startsWith('uwmedia_photos_out_'));
    expect(photos.saved, [('IMG_7_color.jpg', 'Dives')]);
    engine.script = null;

    // A folder picked takes the output out of Photos again.
    await choosePlace(tester, find.text(saveToLabel), folderPlaceLabel);
    expect(made.outputText, '/picked/out');
    expect(find.text('/picked/out'), findsOneWidget);

    // Several files picked one by one are the source, by name.
    await choosePlace(
      tester,
      find.text(chooseMediaLabel),
      filesPlaceLabel,
      real: true,
    );
    expect(made.sourceFiles, [
      p.join(media, 'Abyss.MP4'),
      p.join(media, 'Fish.jpg'),
    ]);
    expect(find.textContaining('2 files in '), findsOneWidget);
    expect(find.text('1 video, 1 photo found'), findsOneWidget);
    expect(config.fields()[sourceFilesField], made.sourceFiles);
    // The files dialog takes one or several: no folder as a source.
    expect(
      [
        for (final place
            in tester
                .widget<PlaceMenuButton>(
                  find.widgetWithText(PlaceMenuButton, chooseMediaLabel),
                )
                .places)
          place.label,
      ],
      [filesPlaceLabel, photoLibraryPlaceLabel],
    );
  });

  testWidgets('on screen: the preview, the picker, the controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    config.updateSettings({
      'fields': {sourceField: clip},
    });
    late ColorController made;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ColorPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: config,
                home: '/Users/diver',
              ),
              setup: (_) async {
                made = controller();
                await made.setLogs(logs);
                return made;
              },
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settleReal(tester);
    expect(find.text('Live preview'), findsOneWidget);
    // No logs folder of the user's own: the way to the Dive Logs page.
    expect(find.text('Dive logs'), findsNothing);
    expect(find.text(diveLogsButtonLabel), findsOneWidget);
    expect(find.text('1 video found'), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    expect(made.matchedDive, isNotNull);

    // A press held on the picture shows the original; let go, and the
    // corrected one is back.
    final hold = await tester.startGesture(
      tester.getCenter(find.byType(RawImage)),
    );
    await tester.pump(originalHold ~/ 2);
    expect(made.showOriginal, isFalse);
    await tester.pump(originalHold);
    expect(made.showOriginal, isTrue);
    expect(find.text('Original'), findsOneWidget);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(made.originalImage),
    );
    await hold.up();
    await tester.pumpAndSettle();
    expect(made.showOriginal, isFalse);
    expect(find.text('Original'), findsNothing);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(made.previewImage),
    );

    await tester.tap(find.text('+ Add Overlay…'));
    await tester.pumpAndSettle();
    expect(find.text('Add Overlay'), findsOneWidget);
    expect(find.text('Overlay brand'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settleReal(tester);
    expect(made.overlays, hasLength(1));
    final label = made.overlays.single.label;
    expect(find.text(label), findsOneWidget);
    // Each row has its own way out; no "Remove Selected".
    expect(find.text('Remove Selected'), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Remove this overlay'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(made.overlays, isEmpty);
    expect(find.text(label), findsNothing);
    // The preview's card starts level with the first card beside it.
    expect(
      tester.getTopLeft(find.text('Live preview')).dy,
      tester.getTopLeft(find.text('Color correction')).dy,
    );
    // On a computer too the clock offset is one row, opened to its
    // controls.
    expect(find.text('+1m'), findsNothing);
    await tester.ensureVisible(find.text('Clock offset'));
    await tester.tap(find.text('Clock offset'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('+1m'));
    await tester.tap(find.text('+1m'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(made.offsetSeconds, 60);

    // The size is a list of sizes alone; the shape is with the preview
    // (spec §10.75), and the picture is moved and zoomed on the preview
    // itself (spec §10.78).
    expect(find.byKey(const ValueKey('output size')), findsOneWidget);
    // On a computer too a part of the video can be chosen.
    expect(find.byKey(const ValueKey('video part')), findsOneWidget);
    // The picture at its own shape, as wide as its card holds it: the box
    // and the pointer are scaled by that width (owner, 2026-11-19: the
    // column's width squeezed the picture, and the box went off it more
    // the further right it was).
    final shown = tester.getSize(find.byKey(const ValueKey('preview')));
    expect(
      shown.width / shown.height,
      closeTo(made.viewWidth / made.viewHeight, 0.01),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('picture shape')));
    await tester.tap(find.byKey(const ValueKey('picture shape')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portrait 9:16').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(made.pictureShape, ShareShape.portraitCropped);
    expect(made.cropFrame, isNotNull);
    expect(made.cropAt, 0.5);
    // The picture dragged to the right: the window is at its left end.
    final preview = find.byKey(const ValueKey('preview'));
    await tester.ensureVisible(preview);
    await tester.drag(preview, const Offset(900, 0));
    await tester.pump();
    expect(made.cropAt, 0);
    // Smaller with the slider, and then it goes up and down too.
    expect(made.cropSize, 1);
    await tester.ensureVisible(find.byKey(const ValueKey('crop zoom')));
    await tester.drag(
      find.byKey(const ValueKey('crop zoom')),
      const Offset(120, 0),
    );
    await tester.pump();
    expect(made.cropSize, lessThan(0.9));
    expect(made.cropAtY, 0.5);
    await tester.ensureVisible(preview);
    await tester.drag(preview, const Offset(0, -900));
    await tester.pump();
    expect(made.cropAtY, 1);
    // Two fingers apart: further in.
    final sizeBefore = made.cropSize;
    final middle = tester.getCenter(preview);
    final one = await tester.startGesture(
      middle - const Offset(20, 0),
      pointer: 91,
    );
    final two = await tester.startGesture(
      middle + const Offset(20, 0),
      pointer: 92,
    );
    await one.moveBy(const Offset(-20, 0));
    await two.moveBy(const Offset(20, 0));
    await one.up();
    await two.up();
    await tester.pump();
    expect(made.cropSize, lessThan(sizeBefore));
    expect(made.outputSizeChoice!.cut.size, made.cropSize);
    made.outputSize = instagramSizeLabel;
    expect(made.outputSizeChoice!.share!.cropSize, made.cropSize);
    // The bars keep the whole picture: no window.
    await tester.ensureVisible(find.byKey(const ValueKey('picture shape')));
    await tester.tap(find.byKey(const ValueKey('picture shape')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portrait with bars').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crop zoom')), findsNothing);
    expect(
      find.textContaining('Portrait, the whole picture between bars'),
      findsOneWidget,
    );
  });
  test('the preview\'s height: more of a phone on its side', () {
    // Upright, 42 % of the height (owner, 2026-11-18); on its side that
    // left 164 points of 390, now 80 % (owner, 2026-11-24).
    expect(previewRoom(const Size(390, 844), phone: true), 844 * 0.42);
    expect(previewRoom(const Size(844, 390), phone: true), 390 * 0.8);
    expect(previewRoom(const Size(1400, 1000), phone: false), 700);
  });

  testWidgets('on a phone: picked from the library, no folders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // What the library's picker hands over: copies in its own cache, two
    // of them with the same name.
    final picked = [
      for (final (folder, name) in [
        ('a', 'Reef.MP4'),
        ('a', 'Fish.jpg'),
        ('b', 'Fish.jpg'),
      ])
        (File(p.join(tmp.path, 'cache', folder, name))
              ..createSync(recursive: true)
              ..writeAsStringSync('x'))
            .path,
    ];
    final fromCard =
        (File(p.join(tmp.path, 'inbox', 'Wreck.mp4'))
              ..createSync(recursive: true)
              ..writeAsStringSync('x'))
            .path;
    late ColorController made;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ColorPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: false),
                config: config,
                home: '/Users/diver',
                tempDir: (prefix) => tmp.createTempSync(prefix),
                dataDir: () => Directory(p.join(tmp.path, 'data')),
              ),
              setup: (_) async =>
                  made = controller()..setOutput(p.join(tmp.path, 'out')),
              phone: true,
              pickMedia: () async => picked,
              pickFiles: () async => [fromCard],
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settleReal(tester);
    expect(find.text('Source'), findsNothing);
    expect(find.text('Output filename'), findsNothing);
    expect(find.text('Hardware acceleration'), findsNothing);
    expect(find.textContaining('No dive logs kept yet'), findsOneWidget);
    // The pick comes first on a phone, above the preview.
    expect(
      tester.getTopLeft(find.text(pickMediaLabel)).dy,
      lessThan(tester.getTopLeft(find.text('Live preview')).dy),
    );
    // The clock offset is one row that says what is set, opened to its
    // controls.
    expect(find.text('Clock offset'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    expect(find.text('+1m'), findsNothing);
    await tester.tap(find.text('Clock offset'));
    await tester.pumpAndSettle();
    expect(find.text('Clock offset'), findsOneWidget);
    expect(find.text('+1m'), findsOneWidget);
    expect(find.text('Computer shows'), findsOneWidget);
    await tester.tap(find.text('Clock offset'));
    await tester.pumpAndSettle();
    expect(find.text('+1m'), findsNothing);

    // One button, which asks where from.
    Future<void> pickFrom(String place) async {
      await tester.tap(find.text(pickMediaLabel));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(MenuItemButton, place));
        // The choice is acted on once the menu has closed.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await _settleReal(tester);
    }

    await pickFrom(fromLibraryLabel);
    // Moved into a working folder of the app, which is the source now.
    expect(p.basename(made.sourceText), startsWith('uwmedia_picked_'));
    expect(Directory(made.sourceText).listSync(), hasLength(3));
    expect(find.text('1 video, 2 photos found'), findsOneWidget);

    // Or from the phone's files, where a camera card's clips are.
    await pickFrom(fromFilesLabel);
    expect(p.basename(made.sourceText), startsWith('uwmedia_picked_'));
    expect(
      [
        for (final f in Directory(made.sourceText).listSync())
          p.basename(f.path),
      ],
      ['Wreck.mp4'],
    );
    expect(find.text('1 video found'), findsOneWidget);

    // Start is at the foot of the screen (1800 high), not at the end of
    // the page's scroll; nothing of a run is shown before the first one.
    expect(
      tester.getBottomLeft(find.text('Start')).dy,
      inInclusiveRange(1740, 1800),
    );
    expect(find.text('Progress'), findsNothing);
    expect(find.text(idleStatus), findsNothing);

    // While a run goes: the picture, the progress and Stop only.
    final end = Completer<void>();
    engine
      ..hold = end.future
      ..script = (listener) {
        listener
          ..started(1)
          ..active('Wreck.mp4')
          ..message('Warning: something');
      }
      ..results = const [
        (file: 'Wreck.mp4', status: FileStatus.done, error: null),
      ];
    await tester.runAsync(() async {
      await tester.tap(find.text('Start'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Progress'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.textContaining('Now: Wreck.mp4'), findsOneWidget);
    expect(find.text(pickMediaLabel), findsNothing);
    expect(find.text('Color correction'), findsNothing);

    // Ended: the page as it was, how the run ended above Start and what
    // it said in a card at the end.
    await tester.runAsync(() async {
      end.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settleReal(tester);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Finished: 1 done'), findsOneWidget);
    expect(find.text(pickMediaLabel), findsOneWidget);
    expect(find.text('Progress'), findsNothing);
    expect(find.text('Last run'), findsOneWidget);
    expect(find.text('1 messages'), findsOneWidget);
  });
}

/// The file dialogs answered: [files] for the files, a folder of its own.
class _PickedDialogs implements ColorDialogs {
  _PickedDialogs(this.files);

  final List<String> files;

  @override
  Future<List<String>> pickFiles(String initialDirectory) async => files;

  @override
  Future<String?> pickFolder(String initialDirectory) async => '/picked/out';
}
