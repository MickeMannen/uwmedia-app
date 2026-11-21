/// The dive logs a page reads are the ones kept in the app (the Dive Logs
/// page), on the desktop as on the phones (owner, 2026-11-16; spec
/// §10.65). The desktop's one dive-logs folder of before (spec §10.44,
/// optional since §10.57) is no longer read: what is left of it here is
/// the folder a user had set, which the Dive Logs page offers to import
/// once, and the way from a page to that page.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/engine/log_files.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// How many logs the app keeps in [dir] (the log store's folder); 0
/// without one.
int keptLogsIn(String? dir) {
  if (dir == null || !FileSystemEntity.isDirectorySync(dir)) {
    return 0;
  }
  try {
    return logFilesIn(dir).length;
  } on FileSystemException {
    return 0;
  }
}

/// What a page says when no log is kept yet.
const noLogsHint =
    'No dive logs kept yet: add them on the Dive Logs page to match '
    'dives and draw overlays.';

const diveLogsButtonLabel = 'Dive Logs…';

/// The settings field of the folder of before (Python's Color page's
/// `logs_input`; the Python app still reads it, so it is left as it is).
const diveLogsFolderField = 'logs_input';

/// The field the Overlay Generator kept a folder of its own in (Python's
/// still does): read when the shared one is empty.
const legacyGeneratorLogsField = 'hudpage_logs_input';

/// The folder the import was offered for and answered (imported, or
/// not wanted): not offered again.
const logsFolderAnsweredField = 'logs_folder_import_answered';

/// The dive-logs folder set before the logs were kept in the app, empty
/// when none is set.
String diveLogsFolder(ConfigStore config) {
  final fields = config.fields();
  for (final key in [diveLogsFolderField, legacyGeneratorLogsField]) {
    final value = fields[key];
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
  }
  return '';
}

/// The folder of before whose logs the Dive Logs page offers to import:
/// one that is set and there, and not answered for yet; else `null`.
String? logsFolderToOffer(ConfigStore config) {
  final folder = diveLogsFolder(config).trim();
  if (folder.isEmpty ||
      config.fields()[logsFolderAnsweredField] == folder ||
      !FileSystemEntity.isDirectorySync(folder)) {
    return null;
  }
  return folder;
}

/// The offer for [folder] was answered.
void answerLogsFolderOffer(ConfigStore config, String folder) {
  try {
    config.setField(logsFolderAnsweredField, folder);
  } on FileSystemException {
    // Only offered again at the next start.
  }
}

/// The way from a page that reads dive logs to the Dive Logs page while
/// no log is kept yet ([kept] is 0): the hint and the button. With logs
/// kept there is nothing here; a file that matches no dive is said by
/// the page's `DiveMatchButton`, whose list leads to the Dive Logs page
/// (owner, 2026-11-17).
class DiveLogsLink extends StatelessWidget {
  const DiveLogsLink({
    super.key,
    required this.services,
    required this.kept,
    this.enabled = true,
  });

  final AppServices services;
  final int kept;

  /// Off during a run.
  final bool enabled;

  @override
  Widget build(BuildContext context) => kept > 0
      ? const SizedBox.shrink()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            const MutedText(noLogsHint),
            OutlinedButton.icon(
              icon: const Icon(Icons.scuba_diving_outlined),
              label: const Text(diveLogsButtonLabel),
              onPressed: enabled
                  ? () => services.openPage(diveLogsTitle)
                  : null,
            ),
          ],
        );
}
