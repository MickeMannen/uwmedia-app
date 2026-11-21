/// Photos and videos from the phone's files (spec §9.2, §12): what a
/// camera card, a drive or a cable copy left in Files on iOS or in a
/// folder on Android, where the photo library does not reach.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/engine/media_library.dart';

/// What a phone's pick button says where photos and videos are picked.
const pickMediaLabel = 'Pick photos and videos';

/// The two places a phone's pick button offers.
const fromLibraryLabel = 'Photo library';
const fromFilesLabel = 'Files';

/// A phone's one button for picking photos and videos (owner,
/// 2026-11-16): it opens the choice of the photo library or the phone's
/// files, the system having no picker that shows both.
class PickMediaButton extends StatelessWidget {
  const PickMediaButton({
    super.key,
    required this.label,
    required this.onPick,
    this.icon = Icons.photo_library_outlined,
    this.enabled = true,
    this.filled = true,
  });

  final String label;
  final IconData icon;

  /// Called with whether the phone's files were chosen (not the library).
  final void Function({required bool fromFiles}) onPick;

  /// Off during a run.
  final bool enabled;

  /// The page's main button; outlined otherwise.
  final bool filled;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      MenuItemButton(
        leadingIcon: const Icon(Icons.photo_library_outlined),
        onPressed: () => onPick(fromFiles: false),
        child: const Text(fromLibraryLabel),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.folder_outlined),
        onPressed: () => onPick(fromFiles: true),
        child: const Text(fromFilesLabel),
      ),
    ],
    builder: (context, menu, _) {
      final open = enabled
          ? () => menu.isOpen ? menu.close() : menu.open()
          : null;
      return filled
          ? FilledButton.icon(
              icon: Icon(icon),
              label: Text(label),
              onPressed: open,
            )
          : OutlinedButton.icon(
              icon: Icon(icon),
              label: Text(label),
              onPressed: open,
            );
    },
  );
}

/// The files picked in the system's document picker, as copies the app
/// may move or delete; empty when none was picked. Without [photos] only
/// videos are offered; without [multiple] one file. Throws a
/// [LibraryException] when the picker could not hand a file over.
Future<List<String>> pickFromFiles({
  bool photos = true,
  bool multiple = true,
}) async {
  final types = [
    fs.XTypeGroup(
      label: photos ? 'Photos and videos' : 'Videos',
      uniformTypeIdentifiers: [if (photos) 'public.image', 'public.movie'],
      mimeTypes: [if (photos) 'image/*', 'video/*'],
    ),
  ];
  try {
    if (!multiple) {
      final file = await fs.openFile(acceptedTypeGroups: types);
      return [?file?.path];
    }
    return [
      for (final file in await fs.openFiles(acceptedTypeGroups: types))
        file.path,
    ];
  } on PlatformException catch (e) {
    throw LibraryException(e.message ?? 'The file could not be read');
  }
}
