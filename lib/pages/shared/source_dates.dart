/// The dates of a page's source files, read in the background so that
/// the page can say which dives they are matched to before a run (spec
/// §10.67(c)): [sourceDateReads] at a time, by the reader the run uses,
/// and a file read before is not read again.
library;

import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/engine/file_times.dart';

/// How many files' dates are read at a time.
const sourceDateReads = 4;

/// Every tag of a file; `null` when it cannot be read.
typedef TagReader = Future<MediaTags?> Function(String path);

class SourceDates {
  SourceDates({required this.reader, required this.onRead});

  /// The reader of a file's tags, asked for once for each [load]. When
  /// there is none to be had (it throws: the tools are missing), nothing
  /// is read and [dates] stays `null`.
  final Future<TagReader> Function() reader;

  /// Called when the dates of all the files asked for last are read.
  final void Function() onRead;

  // A file that was read and has no date to be had is here with `null`.
  Map<String, DateTime?> _dates = const {};
  bool _read = false;
  bool _reading = false;
  int _ticket = 0;

  /// Each file's own date in the order asked for (`null` for a file with
  /// no date to be had), once all of them are read; `null` before.
  Map<String, DateTime?>? get dates => _read ? _dates : null;

  /// Whether dates are being read just now.
  bool get reading => _reading;

  /// Reads the dates of [files] that are not read yet; those of other
  /// files are let go. A call ends the one before it.
  Future<void> load(List<String> files) async {
    final ticket = ++_ticket;
    final known = _dates;
    final missing = [
      for (final file in files)
        if (!known.containsKey(file)) file,
    ];
    // What is read already of these files; the others are let go.
    final dates = <String, DateTime?>{
      for (final file in files)
        if (known.containsKey(file)) file: known[file],
    };
    _dates = dates;
    _read = missing.isEmpty;
    _reading = missing.isNotEmpty;
    if (missing.isEmpty) {
      return;
    }
    final TagReader metadata;
    try {
      metadata = await reader();
    } on Exception {
      if (ticket == _ticket) {
        _reading = false;
      }
      return;
    }
    var next = 0;
    Future<void> worker() async {
      while (next < missing.length && ticket == _ticket) {
        final file = missing[next++];
        try {
          dates[file] = localCreationDate(
            await metadata(file),
            fileModified: fileModified(file),
          );
        } on Exception {
          dates[file] = null;
        }
      }
    }

    await Future.wait([for (var i = 0; i < sourceDateReads; i++) worker()]);
    if (ticket != _ticket) {
      return;
    }
    // In the order asked for.
    _dates = {for (final file in files) file: dates[file]};
    _read = true;
    _reading = false;
    onRead();
  }

  /// Ends a reading under way; nothing is said of it.
  void dispose() {
    _ticket++;
    _reading = false;
  }
}
