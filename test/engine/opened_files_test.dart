// "Open with UWMedia" on a phone (lib/engine/opened_files.dart, the shell):
// the files the platform hands over taken at the start and whenever it
// says more are there, the logs among them kept in the log store, the
// copies handed back, and the Dive Logs page shown saying what was kept.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/shell.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/engine/opened_files.dart';

final Map<String, dynamic> _sources =
    (jsonDecode(
          utf8.decode(
            gzip.decode(
              File(
                'test/fixtures/python_reference/dives/fit_edit_cases.json.gz',
              ).readAsBytesSync(),
            ),
          ),
        ) as Map<String, dynamic>)['sources']
        as Map<String, dynamic>;

class FakeOpenedFiles implements OpenedFiles {
  void Function(List<String> paths)? onFiles;
  final List<List<String>> released = [];

  @override
  void listen(void Function(List<String> paths) onFiles) =>
      this.onFiles = onFiles;

  @override
  Future<void> done(List<String> paths) async => released.add(paths);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_opened_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the channel: taken at the start, again when more are there', () async {
    const channel = MethodChannel(PlatformOpenedFiles.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final waiting = [
      ['/cache/opened/a/dive.fit'],
      <String>[],
      ['/cache/opened/b/one.uddf', '/cache/opened/b/two.uddf'],
    ];
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'take' ? waiting.removeAt(0) : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final got = <List<String>>[];
    PlatformOpenedFiles().listen(got.add);
    await pumpEventQueue();
    expect(got, [
      ['/cache/opened/a/dive.fit'],
    ]);

    // The platform says more are there: nothing yet, then two.
    Future<void> available() => messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('available')),
      (_) {},
    );
    await available();
    await available();
    await pumpEventQueue();
    expect(got, hasLength(2));
    expect(got.last, ['/cache/opened/b/one.uddf', '/cache/opened/b/two.uddf']);

    await PlatformOpenedFiles().done(got.last);
    expect(calls.last.method, 'done');
    expect(calls.last.arguments, got.last);
  });

  test('no platform side (the desktop, a test): nothing, no error', () async {
    final files = PlatformOpenedFiles(const MethodChannel('uwmedia/none'));
    final got = <List<String>>[];
    files.listen(got.add);
    await pumpEventQueue();
    await files.done(['x']);
    expect(got, isEmpty);
  });

  testWidgets('an opened log is kept and the Dive Logs page shown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
      tempDir: (prefix) => (Directory(
        p.join(tmp.path, 'work'),
      )..createSync()).createTempSync(prefix),
    );
    final opened = FakeOpenedFiles();
    final inbox = Directory(p.join(tmp.path, 'opened', 'a'))
      ..createSync(recursive: true);
    final fit = p.join(inbox.path, 'dive.fit');
    File(fit).writeAsBytesSync(base64.decode(_sources['air'] as String));
    final note = p.join(inbox.path, 'note.txt');
    File(note).writeAsStringSync('hello');

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: AppShell(services: services, openedFiles: opened),
      ),
    );
    expect(find.widgetWithText(AppBar, 'Color'), findsOneWidget);

    await tester.runAsync(() async {
      opened.onFiles!([fit, note]);
      // The files are taken in first, then the page is shown.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, diveLogsTitle), findsOneWidget);
    expect(services.logStore.files().map(p.basename), ['dive.fit']);
    expect(opened.released, [
      [fit, note],
    ]);
    expect(
      find.text(
        'Opened dive.fit, note.txt. Kept 1 log(s). '
        'note.txt: not a dive log UWMedia reads',
      ),
      findsOneWidget,
    );
    expect(find.text('dive.fit'), findsOneWidget);

    // Another while the page is open: listed too.
    final later = p.join(inbox.path, 'later.fit');
    File(later).writeAsBytesSync(
      base64.decode(_sources['nitrox_30_min_later'] as String),
    );
    await tester.runAsync(() async {
      opened.onFiles!([later]);
      // The files are taken in first, then the page is shown.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('later.fit'), findsOneWidget);
    expect(find.text('Opened later.fit. Kept 1 log(s).'), findsOneWidget);

    // An overlay page from the desktop's Overlay Designer, as its zip:
    // refused on a phone (spec §10.81), and no dive log.
    List<int> json(Object value) => utf8.encode(jsonEncode(value));
    final archive = Archive();
    for (final MapEntry(:key, :value) in {
      'normal.json': json({
        'design_width': 1920,
        'hud_skin': {
          'type': 'shape',
          'width': 400,
          'height': 200,
          'linked_elements': <Object>[],
        },
      }),
      'template.json': json({
        'brand': 'custom',
        'computer': 'my_cam',
        'page': 'main',
        'page_name': 'Main',
        'manufacturer': 'Mine',
        'model': 'My Cam',
      }),
    }.entries) {
      archive.addFile(ArchiveFile(key, value.length, value));
    }
    final zip = p.join(inbox.path, 'my_cam_main.zip');
    File(zip).writeAsBytesSync(ZipEncoder().encode(archive));
    var relisted = 0;
    services.templatesRevision.addListener(() => relisted++);
    await tester.runAsync(() async {
      opened.onFiles!([zip]);
      // The files are taken in first, then the page is shown.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    expect(
      find.text('Could not add my_cam_main.zip: $phoneOverlayRefused'),
      findsOneWidget,
    );
    expect(relisted, 0);
    expect(
      File(
        p.join(
          services.userTemplatesDir,
          'custom',
          'my_cam',
          'main',
          'normal.json',
        ),
      ).existsSync(),
      isFalse,
    );
    expect(services.logStore.files().map(p.basename), [
      'dive.fit',
      'later.fit',
    ]);
    expect(find.text('Opened later.fit. Kept 1 log(s).'), findsOneWidget);

    // A page asks the shell for another one the same way (the "Dive
    // Logs…" button of a page that reads logs).
    services.openPage('About');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'About'), findsOneWidget);
    expect(services.pageAsked.value, isNull);
  });
}
