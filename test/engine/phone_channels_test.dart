// The phones' small channels on a made-up runner: the screen kept on for
// a run (lib/engine/keep_awake.dart), and the library's picker
// (lib/engine/media_library.dart) with its own picker where the runner
// has one and `image_picker` where it has not.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/engine/keep_awake.dart';
import 'package:uwmedia_app/engine/media_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const screen = MethodChannel('uwmedia/screen');
  const library = MethodChannel('uwmedia/media_library');

  test(
    'the screen is on for the run and let go after, a failure too',
    () async {
      final calls = <Object?>[];
      messenger.setMockMethodCallHandler(screen, (call) async {
        calls.add(call.arguments);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(screen, null));
      expect(await withScreenOn(() async => 7), 7);
      expect(calls, [true, false]);
      await expectLater(
        withScreenOn<void>(() async => throw const FormatException('x')),
        throwsFormatException,
      );
      expect(calls, [true, false, true, false]);
    },
  );

  test('Stop from the runner ends the run; the files done are told', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(screen, (call) async {
      calls.add('${call.method} ${call.arguments}');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(screen, null));
    final stopped = Completer<void>();
    final run = withScreenOn(() async {
      await reportRunProgress(2, 7);
      await stopped.future;
      return 'stopped';
    }, onStop: () async => stopped.complete());
    await pumpEventQueue();
    // The runner's notification says Stop.
    await messenger.handlePlatformMessage(
      'uwmedia/screen',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('stopRun')),
      (_) {},
    );
    expect(await run, 'stopped');
    expect(calls, [
      'keepAwake true',
      'runProgress {done: 2, total: 7}',
      'keepAwake false',
    ]);
    // After the run a late Stop finds nobody.
    await messenger.handlePlatformMessage(
      'uwmedia/screen',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('stopRun')),
      (_) {},
    );
  });

  test('a run goes on without a runner, or one that refuses', () async {
    expect(await withScreenOn(() async => 1), 1);
    messenger.setMockMethodCallHandler(
      screen,
      (call) async => throw PlatformException(code: 'no'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(screen, null));
    expect(await withScreenOn(() async => 2), 2);
  });

  test("the runner's picker: what is asked, the files, a refusal", () async {
    final asked = <Object?>[];
    Object? answer = ['/tmp/picked/IMG_0001.HEIC'];
    messenger.setMockMethodCallHandler(library, (call) async {
      asked.add(call.arguments);
      final given = answer;
      if (given is PlatformException) {
        throw given;
      }
      return answer;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(library, null));
    const picker = PlatformMediaLibrary();
    expect(await picker.pick(videos: false, multiple: false), [
      '/tmp/picked/IMG_0001.HEIC',
    ]);
    expect(asked.single, {'photos': true, 'videos': false, 'multiple': false});
    // Nothing picked.
    answer = <Object?>[];
    expect(await picker.pick(), isEmpty);
    answer = PlatformException(code: 'library', message: '1 of 2 not read');
    await expectLater(
      picker.pick(),
      throwsA(
        isA<LibraryException>().having(
          (e) => e.message,
          'message',
          '1 of 2 not read',
        ),
      ),
    );
  });

  test(
    'without a picker of its own the runner leaves it to image_picker',
    () async {
      // The Android runner answers "not implemented"; image_picker's own
      // channel has nobody in a test, which shows it was the one asked.
      messenger.setMockMethodCallHandler(library, null);
      await expectLater(
        const PlatformMediaLibrary().pick(photos: false, multiple: false),
        throwsA(isNot(isA<LibraryException>())),
      );
    },
  );
}
