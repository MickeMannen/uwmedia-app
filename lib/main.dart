import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/shell.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/app_paths.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/window/window_placement.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/desktop_window.dart';
import 'package:uwmedia_app/engine/file_picks.dart';
import 'package:uwmedia_app/engine/opened_files.dart';
import 'package:uwmedia_app/engine/start_folders.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Working folders a run left behind more than a day ago.
  (await initAppPaths()).pruneTempDirs();
  final capabilities = Capabilities.ofPlatform();
  _startLog();
  if (capabilities.desktop) {
    // Hidden until placed where the last run left it (spec §13.6); shown
    // also when that fails.
    unawaited(
      startDesktopWindow(
        File(p.join(userConfigDir().path, windowStateFilename)),
      ),
    );
  }
  if (appSandboxed) {
    // In the App Sandbox (the Mac App Store build): the files and folders
    // picked before are opened again (spec §10.74).
    final access = FileAccess.instance = FileAccess(
      File(p.join(userConfigDir().path, bookmarksFilename)),
    );
    await access.restore();
  }
  final home = homeFromEnvironment(Platform.environment);
  final services = AppServices(
    capabilities: capabilities,
    config: ConfigStore(
      userConfigDir,
      startFolders: capabilities.desktop
          ? await findStartFolders(home)
          : const {},
    ),
    home: home,
  );
  runApp(UwmediaApp(services: services));
}

class UwmediaApp extends StatelessWidget {
  const UwmediaApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'UWMedia',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    home: AppShell(
      services: services,
      openedFiles: services.capabilities.desktop ? null : PlatformOpenedFiles(),
    ),
  );
}

// The app's log, and what nothing caught written into it (spec §10.76).
void _startLog() {
  final log = AppLog.instance = AppLog(
    File(p.join(userCacheDir().path, appLogFilename)),
  );
  log.add(
    'App',
    'Started on ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
  );
  final shown = FlutterError.onError;
  FlutterError.onError = (details) {
    log.add('Error', '${details.exceptionAsString()}\n${details.stack ?? ''}');
    shown?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.add('Error', '$error\n$stack');
    // Not handled here: the framework reports it as before.
    return false;
  };
}
