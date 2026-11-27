/// The desktop's [WindowHost]: the app's window through `window_manager`,
/// the screens' work areas through `screen_retriever` (spec §13.6). The
/// runners start the window hidden (`MainFlutterWindow.swift`,
/// `flutter_window.cpp`, `my_application.cc`); [startDesktopWindow]
/// places it and shows it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:uwmedia_app/core/window/window_placement.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/app_window.dart';
import 'package:window_manager/window_manager.dart';

class DesktopWindowHost with WindowListener implements WindowHost {
  void Function()? _changed;
  Future<void> Function()? _closing;
  AppLifecycleListener? _lifecycle;

  @override
  Future<List<WindowRect>> workAreas() async {
    WindowRect area(Display display) {
      final position = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      return WindowRect(position.dx, position.dy, size.width, size.height);
    }

    final main = await screenRetriever.getPrimaryDisplay();
    final all = await screenRetriever.getAllDisplays();
    return [
      area(main),
      for (final display in all)
        if (display.id != main.id) area(display),
    ];
  }

  @override
  Future<WindowRect> bounds() async {
    final rect = await windowManager.getBounds();
    return WindowRect(rect.left, rect.top, rect.width, rect.height);
  }

  @override
  Future<WindowMode> mode() async {
    if (await windowManager.isMinimized()) {
      return WindowMode.minimized;
    }
    if (await windowManager.isFullScreen()) {
      return WindowMode.fullScreen;
    }
    return await windowManager.isMaximized()
        ? WindowMode.maximized
        : WindowMode.normal;
  }

  @override
  Future<void> place(
    WindowState state,
    double minWidth,
    double minHeight,
  ) async {
    await windowManager.setMinimumSize(Size(minWidth, minHeight));
    final b = state.bounds;
    await windowManager.setBounds(
      Rect.fromLTWH(b.left, b.top, b.width, b.height),
    );
    if (state.maximized) {
      await windowManager.maximize();
    }
  }

  @override
  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> listen({
    required void Function() changed,
    required Future<void> Function() closing,
  }) async {
    _changed = changed;
    _closing = closing;
    windowManager.addListener(this);
    // The close button waits for [closing] (onWindowClose); quitting the
    // app (Cmd+Q on the Mac) asks the app instead.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        AppLog.note('App', 'Asked to quit');
        await _saveQuietly();
        return AppExitResponse.exit;
      },
    );
    await windowManager.setPreventClose(true);
  }

  Future<void> _saveQuietly() async {
    try {
      await _closing?.call();
    } on Object catch (e) {
      debugPrint('Window state not saved: $e');
    }
  }

  // The close button: the window's state is saved, the window is taken
  // off the screen and the app is told to end. Hidden first, because
  // the runners keep the window until the engine has shut down, which
  // took more than ten seconds on Windows (spec §10.109); the log says
  // how long each step took.
  @override
  void onWindowClose() {
    unawaited(() async {
      final clock = Stopwatch()..start();
      await _saveQuietly();
      final saved = clock.elapsedMilliseconds;
      try {
        await windowManager.hide();
      } on Object catch (e) {
        debugPrint('Window not hidden: $e');
      }
      final going = AppLog.underWay();
      AppLog.note(
        'App',
        'Closing: the window\'s state saved after $saved ms, the window '
            'hidden after ${clock.elapsedMilliseconds} ms. '
            '${going.isEmpty ? 'Nothing under way' : 'Still under way: ${going.join('; ')}'}',
      );
      _lifecycle?.dispose();
      await windowManager.destroy();
    }());
  }

  @override
  void onWindowResized() => _changed?.call();

  @override
  void onWindowMoved() => _changed?.call();

  @override
  void onWindowMaximize() => _changed?.call();

  @override
  void onWindowUnmaximize() => _changed?.call();

  @override
  void onWindowEnterFullScreen() => _changed?.call();

  @override
  void onWindowLeaveFullScreen() => _changed?.call();
}

/// Places the hidden window from [stateFile] (`window.json` in the config
/// folder), shows it and keeps the file up to date. A file that cannot
/// be read is a first launch; one that cannot be written is left as it
/// is.
Future<void> startDesktopWindow(File stateFile) async {
  try {
    await _startDesktopWindow(stateFile);
  } on Object catch (e) {
    // The runners start the window hidden: it is shown whatever failed.
    debugPrint('Window not placed: $e');
    try {
      await windowManager.show();
    } on Object catch (e) {
      debugPrint('Window not shown: $e');
    }
  }
}

Future<void> _startDesktopWindow(File stateFile) async {
  final clock = Stopwatch()..start();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow();
  final keeper = WindowKeeper(
    host: DesktopWindowHost(),
    read: () {
      try {
        return stateFile.existsSync() ? stateFile.readAsStringSync() : null;
      } on FileSystemException {
        return null;
      } on FormatException {
        // Not text: a damaged file, a first launch.
        return null;
      }
    },
    write: (text) {
      try {
        stateFile.writeAsStringSync(text);
      } on FileSystemException catch (e) {
        debugPrint('Window state not saved: ${e.message}');
      }
    },
  );
  await keeper.start();
  AppLog.note(
    'App',
    'The window placed and shown after ${clock.elapsedMilliseconds} ms',
  );
}
