// The desktop window kept between runs (lib/engine/app_window.dart, spec
// §13.6) on a made-up window: placed from the kept text before it is
// shown, shown also when placing fails, saved a moment after the last
// change and at once on closing, a maximised window keeping the frame it
// had before, a minimised or full-screen one changing nothing.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/window/window_placement.dart';
import 'package:uwmedia_app/engine/app_window.dart';

class FakeHost implements WindowHost {
  List<WindowRect> areas = const [WindowRect(0, 0, 2560, 1392)];
  WindowRect frame = const WindowRect(0, 0, 1280, 800);
  WindowMode current = WindowMode.normal;
  final calls = <String>[];
  WindowState? placed;
  (double, double)? minimum;
  bool failPlacing = false;
  void Function()? changed;
  Future<void> Function()? closing;

  @override
  Future<List<WindowRect>> workAreas() async => areas;

  @override
  Future<WindowRect> bounds() async => frame;

  @override
  Future<WindowMode> mode() async => current;

  @override
  Future<void> place(
    WindowState state,
    double minWidth,
    double minHeight,
  ) async {
    calls.add('place');
    if (failPlacing) {
      throw StateError('no window');
    }
    placed = state;
    minimum = (minWidth, minHeight);
    frame = state.bounds;
  }

  @override
  Future<void> show() async => calls.add('show');

  @override
  Future<void> listen({
    required void Function() changed,
    required Future<void> Function() closing,
  }) async {
    calls.add('listen');
    this.changed = changed;
    this.closing = closing;
  }
}

void main() {
  late FakeHost host;
  String? kept;
  var writes = 0;

  WindowKeeper keeper() => WindowKeeper(
    host: host,
    read: () => kept,
    write: (text) {
      kept = text;
      writes++;
    },
  );

  setUp(() {
    host = FakeHost();
    kept = null;
    writes = 0;
  });

  test('the first launch: placed, then shown', () async {
    await keeper().start();
    expect(host.calls, ['place', 'listen', 'show']);
    expect(host.placed, WindowState(firstBounds(host.areas.first)));
    expect(host.minimum, (minWindowWidth, minWindowHeight));
    expect(writes, 0);
  });

  test('the kept window put back, maximised', () async {
    const state = WindowState(WindowRect(50, 60, 1500, 900), maximized: true);
    kept = encodeWindowState(state);
    await keeper().start();
    expect(host.placed, state);
  });

  test('a damaged file is a first launch', () async {
    kept = '{"x": ';
    await keeper().start();
    expect(host.placed, WindowState(firstBounds(host.areas.first)));
  });

  test('shown and kept even when placing fails', () async {
    host.failPlacing = true;
    await expectLater(keeper().start(), throwsStateError);
    expect(host.calls, ['place', 'listen', 'show']);
  });

  test('no saves after closing', () {
    fakeAsync((async) {
      keeper().start();
      async.flushMicrotasks();
      host.closing!();
      async.flushMicrotasks();
      expect(writes, 1);
      host.changed!();
      async.elapse(const Duration(seconds: 2));
      expect(writes, 1);
    });
  });

  test('saved half a second after the last change', () {
    fakeAsync((async) {
      keeper().start();
      async.flushMicrotasks();
      host.frame = const WindowRect(10, 20, 1300, 850);
      host.changed!();
      async.elapse(const Duration(milliseconds: 300));
      host.frame = const WindowRect(30, 40, 1400, 900);
      host.changed!();
      async.elapse(const Duration(milliseconds: 300));
      expect(writes, 0);
      async.elapse(const Duration(milliseconds: 300));
      expect(writes, 1);
      expect(
        decodeWindowState(kept!),
        const WindowState(WindowRect(30, 40, 1400, 900)),
      );
    });
  });

  test('saved at once on closing, the pending save dropped', () {
    fakeAsync((async) {
      keeper().start();
      async.flushMicrotasks();
      host.frame = const WindowRect(10, 20, 1300, 850);
      host.changed!();
      host.closing!();
      async.flushMicrotasks();
      expect(writes, 1);
      async.elapse(const Duration(seconds: 2));
      expect(writes, 1);
      expect(decodeWindowState(kept!)!.bounds, host.frame);
    });
  });

  test('maximised: the frame of before kept, with the flag', () async {
    await keeper().start();
    host.frame = const WindowRect(100, 100, 1300, 850);
    await host.closing!();
    host.current = WindowMode.maximized;
    host.frame = const WindowRect(0, 0, 2560, 1392);
    await host.closing!();
    expect(
      decodeWindowState(kept!),
      const WindowState(WindowRect(100, 100, 1300, 850), maximized: true),
    );
    // Back to a window: the flag goes.
    host.current = WindowMode.normal;
    host.frame = const WindowRect(100, 100, 1300, 850);
    await host.closing!();
    expect(decodeWindowState(kept!)!.maximized, isFalse);
  });

  test('minimised or full screen: the state of before', () async {
    const state = WindowState(WindowRect(50, 60, 1500, 900), maximized: true);
    kept = encodeWindowState(state);
    await keeper().start();
    for (final mode in [WindowMode.minimized, WindowMode.fullScreen]) {
      host.current = mode;
      host.frame = const WindowRect(-32000, -32000, 160, 28);
      await host.closing!();
      expect(decodeWindowState(kept!), state, reason: '$mode');
    }
  });
}
