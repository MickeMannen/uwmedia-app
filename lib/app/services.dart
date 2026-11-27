/// What the pages share: what the app may do on this device, the config
/// files, the external tools on the desktop and the one batch allowed at
/// a time.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/app_paths.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/hud/sidemount_tanks.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/log_store.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/native_tools.dart';
import 'package:uwmedia_app/engine/template_import.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';

/// What became of files opened with UWMedia: how many went to the dive
/// logs, the overlays added, and the overlay zips that could not be.
typedef ReceivedFiles = ({
  int logs,
  List<String> overlays,
  List<String> problems,
});

/// Why a phone takes no overlay page zip.
const phoneOverlayRefused = 'overlays are added on a computer, not on a phone';

/// What a phone says after [received]'s overlays; '' when there were none.
String receivedOverlaysText(ReceivedFiles received) => [
  if (received.overlays.isNotEmpty)
    'Overlay added: ${received.overlays.join(', ')}. Choose it under '
        '"+ Add Overlay…" on the Color page.',
  for (final problem in received.problems) 'Could not add $problem',
].join(' ');

/// What the app may do where it runs (spec §0, §9). Pages and features
/// ask this, not the platform.
class Capabilities {
  const Capabilities({
    required this.desktop,
    this.mobileEngine = false,
    this.photos = false,
    this.resultFolders = false,
    this.nativeVideo = false,
    this.updateCheck = true,
    bool? externalTools,
  }) : externalTools = externalTools ?? desktop;

  /// The capabilities of the system the app runs on.
  factory Capabilities.ofPlatform() => Capabilities(
    desktop: Platform.isMacOS || Platform.isWindows || Platform.isLinux,
    mobileEngine: Platform.isAndroid || Platform.isIOS,
    photos: Platform.isMacOS,
    resultFolders: Platform.isIOS || Platform.isAndroid,
    nativeVideo: Platform.isMacOS,
    externalTools:
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux) &&
        !(storeBuild && Platform.isMacOS),
    updateCheck: !Platform.isIOS && !(storeBuild && Platform.isMacOS),
  );

  /// The full app: external ffmpeg and exiftool, source and output
  /// folders, the editing pages. Phones and tablets get the subset.
  final bool desktop;

  /// The phone's own media engine (`MediaEngine.kt` on Android,
  /// `MediaEngine` in the iOS runner): videos colour corrected, overlaid
  /// and converted on the phone.
  final bool mobileEngine;

  /// Apple Photos beside the folders on a desktop (the Mac): a source to
  /// pick from and an album to save into (spec §10.50).
  final bool photos;

  /// A phone's results into a folder of its files instead of an album
  /// (the runner's folder picker on iOS, the system's document tree on
  /// Android; `lib/engine/result_folder.dart`).
  final bool resultFolders;

  /// A desktop whose runner has the phones' media engine beside ffmpeg
  /// (the Mac, `apple/MediaEngine.swift`): the videos of Color and Resize
  /// can be written by it ([videoEngineKey], `docs/design/macos-remove-ffmpeg.md`).
  final bool nativeVideo;

  /// ffmpeg and exiftool as programs the app starts: every desktop
  /// build but the Mac App Store's ([storeBuild]), which has only the
  /// runner's media engine and the app's own readers (spec §10.74).
  final bool externalTools;

  /// "Check for updates" on the About page (it asks GitHub for the
  /// latest release): not where the app comes from Apple's stores, the
  /// iPhone and the Mac App Store build, whose updates are the store's
  /// and whose sandbox on the Mac has no network (spec §10.110).
  final bool updateCheck;
}

/// The build for the Mac App Store (`--dart-define=UWMEDIA_STORE=true`):
/// no ffmpeg and no exiftool (`docs/design/macos-remove-ffmpeg.md` step 7).
const storeBuild = bool.fromEnvironment('UWMEDIA_STORE');

/// The setting that says which engine writes the videos on a desktop
/// that has both ([Capabilities.nativeVideo]): [videoEngineFfmpeg] (also
/// when nothing is set) or [videoEngineNative].
const videoEngineKey = 'video_engine';
const videoEngineFfmpeg = 'ffmpeg';
const videoEngineNative = 'native';

/// What the Settings page calls the two.
const videoEngineLabels = {
  videoEngineFfmpeg: 'FFmpeg',
  videoEngineNative: 'macOS (AVFoundation)',
};

/// Only one of Color, Overlay Generator and Convertion runs at a time:
/// they would all compete for ffmpeg and the processor.
class BatchGate extends ChangeNotifier {
  String? _owner;

  /// The page whose batch is running, `null` when none is.
  String? get owner => _owner;

  /// Whether [page] may start a batch now.
  bool isFreeFor(String page) => _owner == null || _owner == page;

  /// Takes the gate for [page]; false when another page holds it.
  bool enter(String page) {
    if (!isFreeFor(page)) {
      return false;
    }
    _owner = page;
    notifyListeners();
    return true;
  }

  void leave(String page) {
    if (_owner == page) {
      _owner = null;
      notifyListeners();
    }
  }
}

/// ffmpeg, ffprobe and exiftool, found.
typedef DesktopTools = ({FfmpegTools ffmpeg, Exiftool exiftool});

/// The page of kept dive logs, where an opened log and a page's "Dive
/// Logs…" button lead.
const diveLogsTitle = 'Dive Logs';

class AppServices {
  AppServices({
    required this.capabilities,
    required this.config,
    required this.home,
    ToolFinder Function()? toolFinder,
    Directory Function(String prefix)? tempDir,
    Directory Function()? dataDir,
    MobileMediaEngine Function()? nativeEngine,
  }) : _toolFinder = toolFinder ?? ToolFinder.forThisMachine,
       _nativeEngine = nativeEngine ?? PlatformMediaEngine.new,
       tempDir = tempDir ?? appTempDir,
       dataDir = dataDir ?? userDataDir;

  final Capabilities capabilities;
  final ConfigStore config;

  /// The user's home folder: where the file dialogs start the first time,
  /// and what the path fields write as `~`.
  final String home;
  final ToolFinder Function() _toolFinder;
  final MobileMediaEngine Function() _nativeEngine;
  final BatchGate batches = BatchGate();

  /// The runner's media engine when this desktop has one and the user
  /// chose it for the videos ([videoEngineKey]); `null` for ffmpeg.
  MobileMediaEngine? get nativeVideoEngine =>
      capabilities.nativeVideo &&
          (!capabilities.externalTools ||
              config.settings()[videoEngineKey] == videoEngineNative)
      ? _nativeEngine()
      : null;

  /// Counts the unit system's changes (Advanced): the open pages that show
  /// numbers listen and show them again (Python's `unitsChanged`).
  final ValueNotifier<int> unitsRevision = ValueNotifier(0);

  /// Counts the saves of the Overlay Designer: the pages that offer
  /// templates list them again (Python's `templatesChanged`).
  final ValueNotifier<int> templatesRevision = ValueNotifier(0);

  /// The diver's watermarks (spec §10.45).
  WatermarkStore get watermarks => WatermarkStore(
    config,
    Directory(p.join(dataDir().path, watermarksFolder)),
  );

  /// Counts the changes of the watermarks (Settings): the pages that offer
  /// them list them again.
  final ValueNotifier<int> watermarksRevision = ValueNotifier(0);

  /// The page a page asks the shell to show, by its title (the Dive Logs
  /// page from a page that needs logs); the shell shows it and clears
  /// this.
  final ValueNotifier<String?> pageAsked = ValueNotifier(null);

  /// Asks the shell for the page [title].
  void openPage(String title) => pageAsked.value = title;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;

  /// The app's data folder (`userDataDir` in the app).
  final Directory Function() dataDir;

  /// What draws overlays, with the saved sides and sidemount names of the
  /// tanks for the overlays that show two (spec §10.104).
  Future<HudKit> hudKit() async {
    final kit = await HudKit.load();
    kit.renderer.sidemount = SidemountTanks(config.tankConfig().tanks);
    return kit;
  }

  /// The Tank Sensor Names were saved: the overlays drawn from now on
  /// follow them. (A dive read before keeps the names it was read with
  /// until its page reads the logs again.)
  void tankNamesSaved() {
    final loading = HudKit.loading;
    if (loading != null) {
      unawaited(
        loading.then<void>((kit) {
          kit.renderer.sidemount = SidemountTanks(config.tankConfig().tanks);
        }, onError: (Object _) {}),
      );
    }
  }

  /// The dive logs kept in the app on a phone (spec §12.3).
  LogStore get logStore =>
      LogStore(Directory(p.join(dataDir().path, logStoreFolder)));

  /// Counts the logs kept from outside the Dive Logs page (a log opened
  /// with UWMedia): the page lists them again and shows [logsMessage].
  final ValueNotifier<int> logsRevision = ValueNotifier(0);

  /// What the last of those imports did.
  String logsMessage = '';

  /// Counts the changes to the logs kept in [logStore] (imported, opened
  /// with UWMedia, removed): the pages that match dives read them again.
  final ValueNotifier<int> keptLogsRevision = ValueNotifier(0);

  /// The user's own overlay pages (a phone lists them under Settings).
  List<UserOverlay> userOverlayPages() =>
      userOverlays(DiskTemplateFolder(userTemplatesDir));

  /// Removes one of the user's own overlay pages, and tells the pages
  /// that offer them. Throws a [FileSystemException] when it cannot.
  void removeUserOverlayPage(UserOverlay overlay) {
    removeUserOverlay(userTemplatesDir, overlay);
    templatesRevision.value++;
  }

  /// The files of [paths] (opened with UWMedia on a phone) taken in as
  /// dive logs kept in [logStore], with the Dive Logs page told. An
  /// overlay page zip is refused (spec §10.81). Says how many were
  /// treated as logs and which overlays were refused.
  Future<ReceivedFiles> receiveFiles(List<String> paths) async {
    final logs = <String>[];
    final overlays = <String>[];
    final problems = <String>[];
    for (final path in paths) {
      final name = p.basename(path);
      var page = false;
      if (p.extension(path).toLowerCase() == '.zip') {
        try {
          page = isPageZip(File(path).readAsBytesSync());
        } on FileSystemException {
          // The log store says what is wrong with it.
        }
      }
      if (!page) {
        logs.add(path);
        continue;
      }
      // No overlays of the user's own on a phone (owner, 2026-11-19):
      // there is no way there to remove one again.
      problems.add('$name: $phoneOverlayRefused');
    }
    if (logs.isNotEmpty) {
      final names = logs.map(p.basename).join(', ');
      logsMessage = 'Opened $names. ${importSummary(logStore.import(logs))}';
      logsRevision.value++;
      keptLogsRevision.value++;
    }
    return (logs: logs.length, overlays: overlays, problems: problems);
  }

  /// The folder of the user's own templates: the one set on the Advanced
  /// page, else `templates` in the data folder (Python
  /// `user_templates_dir`, which also makes it; here it is only read).
  String get userTemplatesDir =>
      userTemplatesFolder(config.settings(), dataDir());

  /// The tools as the settings and the machine have them now (a path set
  /// on the Advanced page counts from the next run on). Throws an
  /// [EngineException] that says how to install the missing ones.
  Future<DesktopTools> desktopTools() async {
    if (!capabilities.externalTools) {
      // A build without them: the engine and the app's own readers
      // answer in their place.
      return storeDesktopTools(_nativeEngine(), currentEngineOs());
    }
    final finder = _toolFinder();
    final found = await AppLog.timed(
      'Tools',
      'Looking for ffmpeg, ffprobe and exiftool',
      () => finder.findAll(config.settings()),
    );
    final missing = [
      for (final tool in [toolFfmpeg, toolFfprobe, toolExiftool])
        if (!found.containsKey(tool)) tool,
    ];
    if (missing.isNotEmpty) {
      throw EngineException(installationInstructions(missing, finder.os));
    }
    return (
      ffmpeg: FfmpegTools(
        ffmpeg: found[toolFfmpeg]!,
        ffprobe: found[toolFfprobe],
        os: finder.os,
      ),
      exiftool: Exiftool(found[toolExiftool]!),
    );
  }
}

/// The user's templates folder for [settings]: the one set on the Advanced
/// page, else `templates` in [dataDir] (Python `user_templates_dir`, which
/// also makes it; here it is only read).
String userTemplatesFolder(Map<String, dynamic> settings, Directory dataDir) {
  final set = settings['templates_dir'];
  return set is String && set.isNotEmpty
      ? set
      : p.join(dataDir.path, 'templates');
}

/// The home folder from the environment ('' when it says none).
String homeFromEnvironment(Map<String, String> env) =>
    env['HOME'] ?? env['USERPROFILE'] ?? '';
