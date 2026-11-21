/// The Tag Editor on a phone (spec §9.1): pick photos and videos, see and
/// set their dates and offsets, shift them all, and save corrected copies
/// into a new album.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/pages/tag_editor_lite/tag_editor_lite_controller.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

class TagEditorLitePage extends StatefulWidget {
  const TagEditorLitePage({
    super.key,
    required this.services,
    this.library = const PlatformMediaLibrary(),
  });

  final AppServices services;
  final MediaLibrary library;

  @override
  State<TagEditorLitePage> createState() => _TagEditorLitePageState();
}

class _TagEditorLitePageState extends State<TagEditorLitePage> {
  late final controller = TagEditorLiteController(
    library: widget.library,
    tempDir: widget.services.tempDir,
  );
  final _date = TextEditingController();
  // `null`: the file's own offset kept (or none when it has none).
  String? _offset;
  final _hours = TextEditingController(text: '0');
  final _minutes = TextEditingController(text: '0');
  bool _shiftSetsTz = false;
  String _shiftTz = '+00:00';
  int _shown = -1;
  int _shownPick = -1;

  @override
  void dispose() {
    controller.dispose();
    for (final text in [_date, _hours, _minutes]) {
      text.dispose();
    }
    super.dispose();
  }

  // The edit fields follow the file picked.
  void _follow() {
    final c = controller;
    if ((c.selected == _shown && c.picks == _shownPick) || c.selected < 0) {
      return;
    }
    _shown = c.selected;
    _shownPick = c.picks;
    final (moment, zone) = c.items[c.selected].after;
    _date.text = liteDateText(moment);
    final text = zone == null ? null : tzIso(zone);
    // An offset the list does not have, or none, is kept as it is.
    _offset = text != null && tzOffsets.contains(text) ? text : null;
  }

  void _tell(String? error) {
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  int _whole(TextEditingController text) =>
      int.tryParse(text.text.replaceFirst('+', '')) ?? 0;

  Future<void> _save() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _AlbumDialog(suggestion: controller.albumSuggestion),
    );
    if (name != null && name.trim().isNotEmpty) {
      await controller.saveCopies(name);
    }
  }

  Widget _signed(TextEditingController text, String key) => SizedBox(
    width: 64,
    child: TextField(
      key: ValueKey(key),
      controller: text,
      keyboardType: const TextInputType.numberWithOptions(signed: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^[+-]?\d{0,4}')),
      ],
      decoration: const InputDecoration(isDense: true),
    ),
  );

  Widget _offsets(String value, ValueChanged<String>? onChanged) =>
      DropdownButton<String>(
        value: value,
        items: [
          for (final tz in tzOffsets)
            DropdownMenuItem(value: tz, child: Text(tz)),
        ],
        onChanged: onChanged == null ? null : (v) => onChanged(v!),
      );

  Widget _list() {
    final c = controller;
    return Column(
      children: [
        for (final (i, item) in c.items.indexed)
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: ValueKey('lite-$i'),
              dense: true,
              selected: i == c.selected,
              title: Text(item.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                item.error ??
                    (() {
                      final now =
                          '${liteDateText(item.local)} '
                          '${item.offset == null ? '' : tzIso(item.offset!)}';
                      if (item.pending == null) {
                        return now;
                      }
                      final (moment, zone) = item.after;
                      return '$now  →  ${liteDateText(moment)} '
                          '${zone == null ? '' : tzIso(zone)}';
                    })(),
              ),
              trailing: item.pending == null
                  ? null
                  : const Icon(Icons.edit_calendar_outlined, size: 18),
              onTap: () => c.select(i),
            ),
          ),
      ],
    );
  }

  Widget _detail() {
    final c = controller;
    final item = c.items[c.selected];
    return SectionCard(
      title: item.name,
      children: [
        for (final tag in liteRawTags)
          if (item.tags[tag] != null)
            Text(
              '$tag: ${item.tags[tag]}',
              style: const TextStyle(fontSize: 12),
            ),
        if (item.error == null) ...[
          TextField(
            key: const ValueKey('lite-date'),
            controller: _date,
            decoration: const InputDecoration(
              labelText: 'Local date and time',
              hintText: '2026:05:21 06:58:22',
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Offset'),
              DropdownButton<String?>(
                value: _offset,
                items: [
                  const DropdownMenuItem(child: Text('As it is')),
                  for (final tz in tzOffsets)
                    DropdownMenuItem(value: tz, child: Text(tz)),
                ],
                onChanged: (v) => setState(() => _offset = v),
              ),
              FilledButton.tonal(
                onPressed: c.busy
                    ? null
                    : () => _tell(c.setDate(c.selected, _date.text, _offset)),
                child: const Text('Set'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      _follow();
      return PageFrame(
        title: 'Tag Editor',
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: c.busy ? null : c.pick,
                child: const Text('Pick photos and videos'),
              ),
              OutlinedButton(
                onPressed: !c.busy && c.hasChanges ? c.discard : null,
                child: const Text('Discard changes'),
              ),
              FilledButton(
                onPressed: !c.busy && c.hasChanges ? _save : null,
                child: const Text('Save copies to new album…'),
              ),
            ],
          ),
          if (c.items.isEmpty)
            const MutedText(
              'Pick photos and videos from the library to see their dates. '
              'Changes are saved as corrected copies in a new album.',
            )
          else ...[
            _list(),
            if (c.selected >= 0) _detail(),
            SectionCard(
              title: 'Shift all files',
              children: [
                const MutedText(
                  "For a camera whose clock was wrong: every file's date "
                  'moves by the same hours and minutes.',
                  size: 13,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Hours'),
                    _signed(_hours, 'lite-hours'),
                    const Text('Minutes'),
                    _signed(_minutes, 'lite-minutes'),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _shiftSetsTz,
                          onChanged: (v) =>
                              setState(() => _shiftSetsTz = v ?? false),
                        ),
                        const Text('New offset'),
                      ],
                    ),
                    _offsets(
                      _shiftTz,
                      _shiftSetsTz ? (v) => setState(() => _shiftTz = v) : null,
                    ),
                    OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : () => _tell(
                              c.shiftAll(
                                _whole(_hours),
                                _whole(_minutes),
                                _shiftSetsTz ? _shiftTz : null,
                              ),
                            ),
                      child: const Text('Shift all'),
                    ),
                  ],
                ),
              ],
            ),
          ],
          if (c.busy) const LinearProgressIndicator(),
          if (c.status.isNotEmpty) MutedText(c.status, size: 13),
        ],
      );
    },
  );
}

/// The album the copies go into; the field owned here, so that it lives
/// as long as the dialog does (its closing animation included).
class _AlbumDialog extends StatefulWidget {
  const _AlbumDialog({required this.suggestion});

  final String suggestion;

  @override
  State<_AlbumDialog> createState() => _AlbumDialogState();
}

class _AlbumDialogState extends State<_AlbumDialog> {
  late final _album = TextEditingController(text: widget.suggestion);

  @override
  void dispose() {
    _album.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save to a new album'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          const Text(
            'The changed files are saved as corrected copies into this '
            'album; the originals stay as they are.',
          ),
          TextField(
            controller: _album,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Album'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _album.text),
        child: const Text('Save'),
      ),
    ],
  );
}
