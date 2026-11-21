/// Whether a page's photos and videos have their dive logs, at a glance
/// and file by file (owner, 2026-11-17; spec §10.68): a button that is
/// green when every file is matched to a dive, orange when some are not
/// and red when none is, and that opens the list of the files with the
/// dive each was matched to.
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/pages/dive_matches.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const matchedColor = Color(0xFF4CAF50);
const partlyMatchedColor = Color(0xFFFF9800);
const unmatchedColor = Color(0xFFE53935);

const matchingText = 'Matching the dive logs…';
const noDateText = 'no date in the file';
const noDiveText = 'No dive log';

/// The button's colour and icon for [matches].
(Color, IconData) diveMatchLook(DiveMatches matches) => matches.unmatched == 0
    ? (matchedColor, Icons.check_circle)
    : matches.unmatched == matches.files
    ? (unmatchedColor, Icons.error)
    : (partlyMatchedColor, Icons.warning_amber_rounded);

class DiveMatchButton extends StatelessWidget {
  const DiveMatchButton({
    super.key,
    required this.matches,
    this.pending = false,
    this.onDiveLogs,
  });

  /// `null` while there is nothing to say (no file, no log, or the
  /// files' dates still being read: [pending]).
  final DiveMatches? matches;
  final bool pending;

  /// The way to the Dive Logs page from the list, when a file has no
  /// dive; without it the list has none.
  final VoidCallback? onDiveLogs;

  @override
  Widget build(BuildContext context) {
    final found = matches;
    if (found == null || found.files == 0) {
      return pending ? const MutedText(matchingText) : const SizedBox.shrink();
    }
    final (color, icon) = diveMatchLook(found);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: OutlinedButton.icon(
        icon: Icon(icon, color: color),
        label: Text(diveMatchLabel(found)),
        style: OutlinedButton.styleFrom(side: BorderSide(color: color)),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) =>
              DiveMatchDialog(matches: found, onDiveLogs: onDiveLogs),
        ),
      ),
    );
  }
}

/// The files with the dive each was matched to.
class DiveMatchDialog extends StatelessWidget {
  const DiveMatchDialog({super.key, required this.matches, this.onDiveLogs});

  final DiveMatches matches;
  final VoidCallback? onDiveLogs;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = diveMatchLook(matches);
    return AlertDialog(
      title: Row(
        spacing: 8,
        children: [
          Icon(icon, color: color),
          Flexible(child: Text(diveMatchLabel(matches))),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 640,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: matches.rows.length,
          separatorBuilder: (context, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _row(matches.rows[i]),
        ),
      ),
      actions: [
        if (onDiveLogs != null && matches.unmatched > 0)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onDiveLogs!();
            },
            child: const Text('Dive Logs…'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  // The file with the time it was looked up at, and its dive.
  Widget _row(FileMatch row) {
    final dive = row.dive;
    final time = row.time == null
        ? noDateText
        : pyStrftime(row.time!, '%Y-%m-%d %H:%M:%S');
    return ListTile(
      dense: true,
      leading: Icon(
        dive == null ? Icons.cancel : Icons.check_circle,
        color: dive == null ? unmatchedColor : matchedColor,
      ),
      title: Text(p.basename(row.file)),
      subtitle: Text(
        dive == null ? '$noDiveText · $time' : '${diveLabel(dive)} · $time',
      ),
    );
  }
}
