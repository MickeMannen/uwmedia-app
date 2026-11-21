/// Dive logs opened with UWMedia or shared to it on a phone (spec §12.3
/// step 1): the platform copies each file into its own temporary folder
/// and says so; the app takes the copies, keeps the logs among them in the
/// log store, and hands the copies back to be removed.
library;

import 'package:flutter/services.dart';

/// The files the platform hands the app.
abstract interface class OpenedFiles {
  /// Calls [onFiles] with each batch of files handed over: the ones that
  /// opened the app first, then the ones that come while it runs.
  void listen(void Function(List<String> paths) onFiles);

  /// The copies [paths] are no longer needed.
  Future<void> done(List<String> paths);
}

/// The phones' [OpenedFiles], over the `uwmedia/opened_files` channel
/// (`OpenedFiles.kt` on Android, `OpenedFiles` in `AppDelegate.swift`).
class PlatformOpenedFiles implements OpenedFiles {
  PlatformOpenedFiles([this._channel = const MethodChannel(channelName)]);

  static const channelName = 'uwmedia/opened_files';

  final MethodChannel _channel;
  void Function(List<String> paths)? _onFiles;

  @override
  void listen(void Function(List<String> paths) onFiles) {
    _onFiles = onFiles;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'available') {
        await _take();
      }
    });
    _take();
  }

  Future<void> _take() async {
    final List<String> paths;
    try {
      paths =
          (await _channel.invokeListMethod<String>('take')) ?? const <String>[];
    } on MissingPluginException {
      return;
    }
    if (paths.isNotEmpty) {
      _onFiles?.call(paths);
    }
  }

  @override
  Future<void> done(List<String> paths) async {
    try {
      await _channel.invokeMethod<void>('done', paths);
    } on MissingPluginException {
      // Nothing to hand back to.
    }
  }
}
