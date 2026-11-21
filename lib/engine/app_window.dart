/// The desktop window's size and place kept between runs (spec §13.6):
/// placed before it is first shown, saved a moment after each move or
/// resize and when it closes. What it asks of the window is behind
/// [WindowHost], so that it can be tested without one; the desktop's
/// host is `lib/engine/desktop/desktop_window.dart`. Phones have no
/// window to place and use none of this.
library;

import 'dart:async';

import 'package:uwmedia_app/core/window/window_placement.dart';

/// What the window is doing besides being a plain window.
enum WindowMode { normal, maximized, minimized, fullScreen }

/// The app's one window, as [WindowKeeper] needs it.
abstract interface class WindowHost {
  /// The work areas of the connected screens, the main screen first.
  Future<List<WindowRect>> workAreas();

  /// The window's frame now.
  Future<WindowRect> bounds();

  Future<WindowMode> mode();

  /// Places the hidden window: the smallest size it may be made, its
  /// frame, maximised or not.
  Future<void> place(WindowState state, double minWidth, double minHeight);

  /// Shows the window and gives it the focus.
  Future<void> show();

  /// Calls [changed] after each move, resize, maximise and the like, and
  /// [closing] before the window closes or the app quits (both wait for
  /// it).
  Future<void> listen({
    required void Function() changed,
    required Future<void> Function() closing,
  });
}

/// Places the window from the kept state and keeps it up to date.
class WindowKeeper {
  WindowKeeper({
    required this.host,
    required this.read,
    required this.write,
    this.delay = const Duration(milliseconds: 500),
  });

  final WindowHost host;

  /// The text of the kept state; `null` when there is none.
  final String? Function() read;

  /// Keeps the text of the state.
  final void Function(String text) write;

  /// How long after the last change the state is saved.
  final Duration delay;

  // The frame of the window when last neither maximised, minimised nor
  // full screen: what a maximised window goes back to.
  WindowRect? _normal;
  bool _maximized = false;
  Timer? _timer;
  bool _closing = false;

  /// Places the window, keeps what becomes of it from then on, and shows
  /// it; it is shown, and kept, also when placing it failed (the error
  /// is passed on after).
  Future<void> start() async {
    try {
      final saved = decodeWindowState(read() ?? '');
      final placed = placeWindow(saved, await host.workAreas());
      _normal = placed.state.bounds;
      _maximized = placed.state.maximized;
      await host.place(placed.state, placed.minWidth, placed.minHeight);
    } finally {
      try {
        await host.listen(changed: _changed, closing: _close);
      } finally {
        await host.show();
      }
    }
  }

  Future<void> _close() async {
    // Nothing more after this save: the window is going.
    _closing = true;
    await save();
  }

  void _changed() {
    if (_closing) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(save()));
  }

  /// Saves the window as it is now (at once; a pending save is dropped).
  /// A minimised or full-screen window keeps the state of before, a
  /// maximised one the frame it had before it was maximised (a move made
  /// less than [delay] before going full screen or minimised is lost when
  /// the app quits in that state).
  Future<void> save() async {
    _timer?.cancel();
    _timer = null;
    switch (await host.mode()) {
      case WindowMode.minimized || WindowMode.fullScreen:
        break;
      case WindowMode.maximized:
        _maximized = true;
      case WindowMode.normal:
        _maximized = false;
        _normal = await host.bounds();
    }
    final normal = _normal;
    if (normal != null) {
      write(encodeWindowState(WindowState(normal, maximized: _maximized)));
    }
  }
}
