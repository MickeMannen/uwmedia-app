/// A button that opens a short menu of places: where a page's photos and
/// videos come from (files, the photo library) or where its results go
/// (a folder, an album). The desktop's pages pick their source and output
/// with it, as the phones' do (owner, 2026-11-16; spec §10.65). With one
/// place only there is no menu: the button goes there.
library;

import 'package:flutter/material.dart';

/// One place of the menu.
typedef PlaceEntry = ({IconData icon, String label, VoidCallback onPressed});

/// What the desktop's source button says, and its places.
const chooseMediaLabel = 'Choose photos and videos…';
const chooseVideosLabel = 'Choose videos…';
const filesPlaceLabel = 'Files…';
const folderPlaceLabel = 'A folder…';
const photoLibraryPlaceLabel = 'Photo library…';

/// The place of the dive logs kept in the app (the Dive Logs page), on
/// the pages that open logs.
const importedLogsPlaceLabel = 'The imported logs';

/// What stands under the desktop's "Save to…" button before a place is
/// chosen.
const noOutputText = 'No place chosen yet';

class PlaceMenuButton extends StatelessWidget {
  const PlaceMenuButton({
    super.key,
    required this.label,
    required this.icon,
    required this.places,
    this.enabled = true,
    this.filled = false,
  });

  final String label;
  final IconData icon;
  final List<PlaceEntry> places;

  /// Off during a run.
  final bool enabled;

  /// The page's main button; outlined otherwise.
  final bool filled;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final place in places)
        MenuItemButton(
          leadingIcon: Icon(place.icon),
          onPressed: place.onPressed,
          child: Text(place.label),
        ),
    ],
    builder: (context, menu, _) {
      final open = !enabled
          ? null
          : places.length == 1
          ? places.single.onPressed
          : () => menu.isOpen ? menu.close() : menu.open();
      final text = Text(label, overflow: TextOverflow.ellipsis);
      return filled
          ? FilledButton.icon(icon: Icon(icon), label: text, onPressed: open)
          : OutlinedButton.icon(icon: Icon(icon), label: text, onPressed: open);
    },
  );
}

/// "3 files" for several picked files, without their names (owner,
/// 2026-11-22: hundreds of picked photos made a long line); for one file
/// its name.
String pickedFilesText(List<String> names) =>
    names.length == 1 ? names.single : '${names.length} files';
