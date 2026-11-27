/// The screen kept on while a run goes on a phone: a lock ends an export
/// on iOS at once, and the app must stay in the foreground (spec §9.2).
///
/// On a Mac the same call tells the system that a run is going on (spec
/// §10.98): an app behind other windows is slowed by it (App Nap), which
/// made the app's own share of a run, the overlay pictures it draws and
/// the files it writes, take up to five times as long; and the Mac does
/// not go to sleep in the middle of a run.
library;

import 'dart:async';

import 'package:flutter/services.dart';

const _channel = MethodChannel('uwmedia/screen');

/// Runs [work] with the screen kept on, where the runner can do that.
/// One run at a time (the pages' batch gate sees to that): the end of one
/// lets the screen go, whatever else is going. [onStop] ends the run when
/// the user asks for that outside the app (Stop in Android's
/// notification of the run).
Future<T> withScreenOn<T>(
  Future<T> Function() work, {
  Future<void> Function()? onStop,
}) async {
  _channel.setMethodCallHandler(
    onStop == null
        ? null
        : (call) async {
            if (call.method == 'stopRun') {
              await onStop();
            }
          },
  );
  await _keepAwake(true);
  try {
    return await work();
  } finally {
    _channel.setMethodCallHandler(null);
    await _keepAwake(false);
  }
}

/// Tells the runner how many of the run's files are done, for what it
/// shows of the run outside the app (Android's notification). With
/// [percent], how far the file going on is, as the page shows it: the
/// whole of its work (the analysis and the overlay's pictures too), where
/// the runner by itself knows only the writing of the video (owner,
/// 2026-11-26: the app showed progress, the notification only that it
/// was running).
Future<void> reportRunProgress(int done, int total, {int? percent}) async {
  try {
    await _channel.invokeMethod<void>('runProgress', {
      'done': done,
      'total': total,
      'percent': ?percent,
    });
  } on MissingPluginException {
    // No runner that shows it.
  } on PlatformException {
    // Only not shown.
  }
}

/// Passes on a run's files done and the percent of the file going on
/// ([reportRunProgress]), a whole percent at a time: the pages hear of
/// progress twice a second, the runner needs it when it changes.
class RunProgressReporter {
  int _done = 0;
  int _total = 0;
  int? _percent;

  /// [done] of [total] files are finished; the next starts at nothing.
  void files(int done, int total) {
    _done = done;
    _total = total;
    _percent = null;
    unawaited(reportRunProgress(done, total));
  }

  /// The file going on is [percent] done (0 to 100).
  void file(double percent) {
    final whole = percent.clamp(0, 100).floor();
    if (whole == _percent) {
      return;
    }
    _percent = whole;
    unawaited(reportRunProgress(_done, _total, percent: whole));
  }
}

Future<void> _keepAwake(bool on) async {
  try {
    await _channel.invokeMethod<void>('keepAwake', on);
  } on MissingPluginException {
    // No runner that does it (a test, Windows, Linux).
  } on PlatformException {
    // The run goes on without it.
  }
}
