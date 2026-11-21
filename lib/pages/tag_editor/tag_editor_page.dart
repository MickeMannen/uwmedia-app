/// The Tag Editor page on the desktop (Python `qml/TagEditorPage.qml`):
/// the folder's files on the left, the file's date tags, the batch
/// timezone and the actions on the right.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/engine/file_picks.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/tag_editor/tag_editor_controller.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The folder dialog, so that a test can answer for it.
typedef PickFolder = Future<String?> Function(String initialDirectory);

Future<String?> _systemPickFolder(String initialDirectory) => getDirectoryPath(
  initialDirectory: initialDirectory,
  confirmButtonText: 'Select',
);

Future<List<String>> _systemPickFiles(String initialDirectory) async => [
  for (final file in await openFiles(initialDirectory: initialDirectory))
    file.path,
];

class TagEditorPage extends StatefulWidget {
  const TagEditorPage({
    super.key,
    required this.services,
    this.pickFolder = _systemPickFolder,
    this.pickFiles = _systemPickFiles,
    this.engine,
    this.systemOffset,
    this.photos,
  });

  final AppServices services;
  final PickFolder pickFolder;

  /// Photos and videos, several at once; empty when none was picked.
  final Future<List<String>> Function(String initialDirectory) pickFiles;

  /// Apple Photos beside the folders (spec §10.50); by default the
  /// Mac's, where the app runs on one.
  final MediaLibrary? photos;

  /// exiftool; by default as found.
  final Future<TagEditorEngine> Function()? engine;

  /// The system clock's offset from UTC; by default the system's now.
  final Duration? systemOffset;

  @override
  State<TagEditorPage> createState() => _TagEditorPageState();
}

class _TagEditorPageState extends State<TagEditorPage> {
  late final TagEditorController controller = TagEditorController(
    config: widget.services.config,
    home: widget.services.home,
    engine:
        widget.engine ??
        () async => DesktopTagEditorEngine(
          (await widget.services.desktopTools()).exiftool,
        ),
    systemOffset: widget.systemOffset ?? DateTime.now().timeZoneOffset,
  );
  final Map<String, TextEditingController> _fields = {
    for (final g in tagGuide) g.tag: TextEditingController(),
  };
  final _shiftHours = TextEditingController(text: '0');
  final _shiftMinutes = TextEditingController(text: '0');
  bool _shiftSetsTz = false;
  String? _shiftTz;

  @override
  void initState() {
    super.initState();
    controller.addListener(_syncFields);
  }

  // The fields follow the controller when it changes them (a file shown,
  // a revert); while the user types they are the same text already.
  void _syncFields() {
    for (final MapEntry(:key, :value) in _fields.entries) {
      final text = controller.tagValue(key);
      if (value.text != text) {
        value.text = text;
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    _shiftHours.dispose();
    _shiftMinutes.dispose();
    super.dispose();
  }

  // Apple Photos: the working folder of what was picked there. Its files
  // are copies, changed where they lie and then saved into an album.
  String? _photosDir;
  bool _saving = false;

  MediaLibrary? get _photos =>
      widget.photos ??
      (widget.services.capabilities.photos
          ? const PlatformMediaLibrary()
          : null);

  void _say(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _selectFiles() async {
    final files = await widget.pickFiles(controller.mediaDialogDir);
    if (files.isNotEmpty) {
      setState(() => _photosDir = null);
      await controller.chooseFiles(files);
    }
  }

  Future<void> _selectDirectory() async {
    final path = await widget.pickFolder(controller.mediaDialogDir);
    if (path != null) {
      setState(() => _photosDir = null);
      await controller.chooseDirectory(path);
    }
  }

  Future<void> _fromPhotos() async {
    final String? dir;
    try {
      dir = await pickFromPhotos(
        _photos!,
        widget.services.tempDir,
        page: 'Tag Editor',
      );
    } on Exception catch (e) {
      _say('Could not pick from Photos: $e');
      return;
    }
    if (dir == null || !mounted) {
      return;
    }
    setState(() => _photosDir = dir);
    await controller.chooseDirectory(
      dir,
      remember: false,
      label: fromPhotosText(mediaIn(dir).length),
    );
  }

  // The copies as they now are, into a new album; the originals stay in
  // the library as they were.
  Future<void> _saveIntoPhotos() async {
    final dir = _photosDir;
    if (dir == null) {
      return;
    }
    setState(() => _saving = true);
    final lines = await saveFolderIntoPhotos(_photos!, dir);
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    _say(lines.isEmpty ? 'Nothing left to save.' : lines.join('\n'));
    if (_photosDir != dir) {
      return;
    }
    // What was saved is no longer in the working folder.
    await controller.chooseDirectory(
      dir,
      remember: false,
      label: fromPhotosText(mediaIn(dir).length),
    );
  }

  Future<void> _confirmThen(
    Confirmation? question,
    Future<void> Function() action,
  ) async {
    if (question == null) {
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(question.title),
        content: Text(question.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (yes ?? false) {
      await action();
    }
  }

  Widget _signedField(TextEditingController text, String key, bool on) =>
      SizedBox(
        width: 60,
        child: TextField(
          key: ValueKey(key),
          controller: text,
          enabled: on,
          decoration: const InputDecoration(isDense: true),
          // A whole number, with its sign.
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^[+-]?\d{0,4}')),
          ],
        ),
      );

  int _whole(TextEditingController text) =>
      int.tryParse(text.text.replaceFirst('+', '')) ?? 0;

  Future<void> _shiftAll() {
    final c = controller;
    final hours = _whole(_shiftHours);
    final minutes = _whole(_shiftMinutes);
    final tz = _shiftSetsTz ? (_shiftTz ?? c.currentTz) : null;
    return _confirmThen(
      c.askShiftAll(hours, minutes, tz),
      () => c.shiftAll(hours, minutes, tz),
    );
  }

  Future<void> _viewAllMetadata() async {
    final found = await controller.allMetadata();
    if (found == null || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _MetadataViewer(title: found.title, rows: found.rows),
    );
  }

  Widget _fileList() {
    final c = controller;
    final names = c.fileNames;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          // One button, as on Color and Resize (spec §10.67(g)). A folder
          // stays a place here: the page's "all files" steps work on one.
          PlaceMenuButton(
            label: chooseMediaLabel,
            icon: Icons.photo_library_outlined,
            filled: true,
            enabled: !c.busy && !_saving,
            places: [
              (
                icon: Icons.description_outlined,
                label: filesPlaceLabel,
                onPressed: _selectFiles,
              ),
              (
                icon: Icons.folder_outlined,
                label: folderPlaceLabel,
                onPressed: _selectDirectory,
              ),
              if (_photos != null)
                (
                  icon: Icons.photo_library_outlined,
                  label: photoLibraryPlaceLabel,
                  onPressed: _fromPhotos,
                ),
            ],
          ),
          if (_photos != null) const PhotosFetching(),
          if (_photosDir != null) ...[
            FilledButton.icon(
              icon: const Icon(Icons.save_alt),
              label: const Text(intoPhotosLabel),
              onPressed: c.busy || _saving ? null : _saveIntoPhotos,
            ),
            const MutedText(
              'These are copies. Change their dates, then save them into '
              'a new album; the originals in Photos stay as they are.',
              size: 11,
            ),
          ],
          MutedText(c.dirLabel),
          Expanded(
            child: ListView.builder(
              itemCount: names.length,
              itemExtent: 30,
              itemBuilder: (context, i) => ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(names[i], style: const TextStyle(fontSize: 13)),
                selected: i == c.selectedIndex,
                selectedColor: accent,
                onTap: c.busy || _saving ? null : () => c.selectFile(i),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _details() {
    final c = controller;
    final idle = !c.busy && !_saving;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          SectionCard(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c.selectedFileName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: c.viewMetadataEnabled && !c.busy
                        ? _viewAllMetadata
                        : null,
                    child: const Text('View All Metadata'),
                  ),
                ],
              ),
              if (c.djiVisible)
                const Text(
                  djiDetectedText,
                  style: TextStyle(
                    color: Color(0xFF4CAF50),
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          SectionCard(
            title: 'Edit metadata tags',
            children: [
              for (final g in tagGuide)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 2,
                  children: [
                    Text(
                      g.tag,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextField(
                      controller: _fields[g.tag],
                      style: const TextStyle(fontSize: 15),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (text) => c.setTagValue(g.tag, text),
                    ),
                    Text(
                      TagEditorController.helpOf(g),
                      style: const TextStyle(
                        color: Color(0xFF808080),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          SectionCard(
            title: 'Batch set directory timezone',
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Timezone offset:'),
                  DropdownButton<String>(
                    value: c.currentTz,
                    items: [
                      for (final tz in c.tzOptions)
                        DropdownMenuItem(value: tz, child: Text(tz)),
                    ],
                    onChanged: idle ? (v) => c.currentTz = v! : null,
                  ),
                  const Text('Mode:'),
                  // Narrower than its longest mode on a small window: the
                  // text is cut short there instead of overflowing.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: c.currentTzMode,
                      items: [
                        for (final mode in tzModeOptions)
                          DropdownMenuItem(
                            value: mode,
                            child: Text(mode, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: idle ? (v) => c.currentTzMode = v! : null,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: idle
                        ? () => _confirmThen(
                            c.askApplyTimezone(),
                            c.applyTimezone,
                          )
                        : null,
                    child: const Text('Apply Timezone to All'),
                  ),
                ],
              ),
            ],
          ),
          SectionCard(
            title: 'Shift all files',
            children: [
              const MutedText(
                "For a camera whose clock was wrong: every file's date moves "
                'by the same hours and minutes (both may be negative).',
                size: 13,
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Hours:'),
                  _signedField(_shiftHours, 'shift-hours', idle),
                  const Text('Minutes:'),
                  _signedField(_shiftMinutes, 'shift-minutes', idle),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _shiftSetsTz,
                        onChanged: idle
                            ? (v) => setState(() => _shiftSetsTz = v ?? false)
                            : null,
                      ),
                      const Text('Also set offset:'),
                    ],
                  ),
                  DropdownButton<String>(
                    value: _shiftTz ?? c.currentTz,
                    items: [
                      for (final tz in c.tzOptions)
                        DropdownMenuItem(value: tz, child: Text(tz)),
                    ],
                    onChanged: idle && _shiftSetsTz
                        ? (v) => setState(() => _shiftTz = v)
                        : null,
                  ),
                  OutlinedButton(
                    onPressed: idle ? _shiftAll : null,
                    child: const Text('Shift All Files'),
                  ),
                ],
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: idle ? c.revert : null,
                child: const Text('Revert Changes'),
              ),
              OutlinedButton(
                onPressed: idle
                    ? () => _confirmThen(c.askUpdateAll(), c.updateAll)
                    : null,
                child: const Text('Update All (DJI)'),
              ),
              FilledButton(
                onPressed: idle ? c.writeTags : null,
                child: const Text('Write to File'),
              ),
            ],
          ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.statusText.isNotEmpty) MutedText(c.statusText, size: 14),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 20,
        children: [
          _fileList(),
          Expanded(child: _details()),
        ],
      ),
    ),
  );
}

/// Every tag of a file, with a filter on names and values.
class _MetadataViewer extends StatefulWidget {
  const _MetadataViewer({required this.title, required this.rows});

  final String title;
  final List<MetadataRow> rows;

  @override
  State<_MetadataViewer> createState() => _MetadataViewerState();
}

class _MetadataViewerState extends State<_MetadataViewer> {
  String filter = '';

  @override
  Widget build(BuildContext context) {
    final rows = filterMetadataRows(widget.rows, filter);
    return Dialog(
      child: SizedBox(
        width: 700,
        height: 600,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Filter',
                  hintText: 'Type to filter tag names or values...',
                  border: OutlineInputBorder(),
                ),
                onChanged: (text) => setState(() => filter = text),
              ),
              Expanded(
                child: ColoredBox(
                  color: const Color(0xFF141414),
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemExtent: 26,
                    itemBuilder: (context, i) => ColoredBox(
                      color: i.isEven
                          ? const Color(0xFF1A1A1A)
                          : const Color(0xFF141414),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 260,
                              child: Text(
                                rows[i].tag,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                '${rows[i].value}',
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
