/// The user's Pictures and Downloads folders on a computer, where the file
/// dialogs of photos and videos and of dive logs start the first time
/// ([StartFolder], owner 2026-11-20). Each is the system's own: Windows'
/// known folders (moved into OneDrive, or to another drive, they are
/// found there), the XDG user folders on Linux, and the folders in the
/// home folder on macOS. Only read, never written.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:uwmedia_app/core/config/app_settings.dart';
import 'package:xdg_directories/xdg_directories.dart' as xdg;

/// Windows' id of the Pictures folder (`FOLDERID_Pictures`); the package's
/// `WindowsKnownFolder.Pictures`, but that the analyzer sees only its stub
/// off Windows.
const _picturesFolderId = '{33E28130-4E1E-4676-835A-98395C3BC3BB}';

/// The start folders found; one the system has not, or that cannot be
/// asked, is left out, and its dialogs start in [home].
Future<Map<StartFolder, String>> findStartFolders(String home) async {
  final folders = <StartFolder, String>{};
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      folders[StartFolder.downloads] = downloads.path;
    }
  } on Object {
    // None: home.
  }
  try {
    final pictures = Platform.isWindows
        ? await PathProviderWindows().getPath(_picturesFolderId)
        : Platform.isLinux
        ? xdg.getUserDirectory('PICTURES')?.path
        : home.isEmpty
        ? null
        : p.join(home, 'Pictures');
    if (pictures != null && pictures.isNotEmpty) {
      folders[StartFolder.pictures] = pictures;
    }
  } on Object {
    // None: home.
  }
  return folders;
}
