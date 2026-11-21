/// Where a page's results go: a "Save to…" button and under it the place
/// chosen (owner, 2026-11-17; the place stood on the button before, which
/// made it wide). [SaveToPlace] is the desktop's, with the page's own
/// places; [SaveToButton] a phone's Color and Resize pages', with a new
/// album in Photos or a folder of the phone's files, kept in the settings
/// so that both pages and the next start have it (owner, 2026-11-16).
library;

import 'package:flutter/material.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const saveToLabel = 'Save to…';
const saveToFolderChoice = 'A folder in Files…';
const saveToAlbumChoice = 'An album in Photos…';

/// What a phone's button says while neither an album nor a folder is
/// chosen: a run then makes an album named for when it started.
const noPlaceChosenText = 'No album chosen yet: a new one for each run';

/// What stands under the button for [folder], else for [album].
String saveToText(ResultFolder? folder, [String? album]) => folder != null
    ? 'The folder "${folder.name}"'
    : album != null
    ? 'The album "$album" in Photos'
    : noPlaceChosenText;

/// The desktop's "An album in Photos…": the album chosen or typed in
/// [AlbumDialog], kept for every page as a phone's is (owner, 2026-11-19:
/// the desktop's entry asked nothing, and a second press did nothing);
/// `null` when the dialog was cancelled.
Future<String?> chooseResultAlbum(
  BuildContext context,
  ConfigStore config, {
  Future<List<String>> Function() albums = photoAlbums,
}) async {
  final album = await showDialog<String>(
    context: context,
    builder: (_) =>
        AlbumDialog(album: keptResultAlbum(config) ?? '', albums: albums),
  );
  if (album == null || album.trim().isEmpty) {
    return null;
  }
  keepResultAlbum(config, album);
  return keptResultAlbum(config);
}

/// The desktop's button with its [places], and under it [location]
/// (`null`: none chosen yet).
class SaveToPlace extends StatelessWidget {
  const SaveToPlace({
    super.key,
    required this.location,
    required this.places,
    this.enabled = true,
  });

  final String? location;
  final List<PlaceEntry> places;

  /// Off during a run.
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [
      PlaceMenuButton(
        label: saveToLabel,
        icon: Icons.save_alt_outlined,
        enabled: enabled,
        places: places,
      ),
      if (location case final place?)
        SelectableText(place, style: const TextStyle(fontSize: 12))
      else
        const MutedText(noOutputText),
    ],
  );
}

class SaveToButton extends StatefulWidget {
  const SaveToButton({
    super.key,
    required this.config,
    this.folders = const PlatformResultFolders(),
    this.albums = photoAlbums,
    this.enabled = true,
  });

  final ConfigStore config;
  final ResultFolders folders;

  /// The library's albums by name, to choose one from.
  final Future<List<String>> Function() albums;

  /// Off during a run.
  final bool enabled;

  @override
  State<SaveToButton> createState() => _SaveToButtonState();
}

class _SaveToButtonState extends State<SaveToButton> {
  late ResultFolder? _folder = keptResultFolder(widget.config);
  late String? _album = keptResultAlbum(widget.config);

  void _keep(ResultFolder? folder) {
    keepResultFolder(widget.config, folder);
    setState(() => _folder = folder);
  }

  // An album of the user's choosing ("a new album each run" is no
  // longer offered: owner, 2026-11-17, it did not work on the iPhone).
  void _keepAlbum(String album) {
    keepResultAlbum(widget.config, album);
    setState(() {
      _folder = null;
      _album = keptResultAlbum(widget.config);
    });
  }

  Future<void> _pickAlbum() async {
    final album = await showDialog<String>(
      context: context,
      builder: (_) => AlbumDialog(album: _album ?? '', albums: widget.albums),
    );
    if (album != null && album.trim().isNotEmpty && mounted) {
      _keepAlbum(album);
    }
  }

  Future<void> _pickFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final folder = await widget.folders.pick();
      if (folder != null && mounted) {
        _keep(folder);
      }
    } on Exception catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open the folder: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [
      MenuAnchor(
        menuChildren: [
          MenuItemButton(
            leadingIcon: const Icon(Icons.photo_album_outlined),
            onPressed: _pickAlbum,
            child: const Text(saveToAlbumChoice),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.folder_outlined),
            onPressed: _pickFolder,
            child: const Text(saveToFolderChoice),
          ),
        ],
        builder: (context, menu, _) => OutlinedButton.icon(
          icon: const Icon(Icons.save_alt_outlined),
          label: const Text(saveToLabel),
          onPressed: widget.enabled
              ? () => menu.isOpen ? menu.close() : menu.open()
              : null,
        ),
      ),
      Text(saveToText(_folder, _album), style: const TextStyle(fontSize: 12)),
    ],
  );
}

/// The album the results go into: its name typed (one that is not there
/// is made at the first save), or one of the library's own tapped.
class AlbumDialog extends StatefulWidget {
  const AlbumDialog({super.key, required this.album, required this.albums});

  /// The album kept now; empty for none.
  final String album;
  final Future<List<String>> Function() albums;

  @override
  State<AlbumDialog> createState() => _AlbumDialogState();
}

class _AlbumDialogState extends State<AlbumDialog> {
  late final _name = TextEditingController(text: widget.album);
  late final Future<List<String>> _albums = widget.albums();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Album in Photos'),
    content: SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Album name'),
            onSubmitted: (name) => Navigator.of(context).pop(name),
          ),
          FutureBuilder(
            future: _albums,
            builder: (context, read) {
              final albums = read.data ?? const <String>[];
              return albums.isEmpty
                  ? const MutedText(
                      'An album that is not there yet is made at the first '
                      'save.',
                      size: 11,
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final album in albums)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.photo_album_outlined),
                              title: Text(album),
                              onTap: () => Navigator.of(context).pop(album),
                            ),
                        ],
                      ),
                    );
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_name.text),
        child: const Text('OK'),
      ),
    ],
  );
}
