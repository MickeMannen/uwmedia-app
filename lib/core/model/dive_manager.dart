/// The dives loaded for a run, ported from `models/manager.py` of the
/// Python app (spec §4).
library;

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

/// The same dive exported in several formats is kept once, from the format
/// carrying the most: higher wins, then more samples. A dive with no
/// format, or an unknown one, ranks 0.
const Map<String, int> logFormatRank = {
  'fit': 5,
  'uddf': 5,
  'shearwater_xml': 5,
  'shearwater_csv': 4,
  'subsurface_xml': 3,
  'subsurface_csv': 1,
};

/// How far apart two logs of the same dive may start.
const Duration sameDiveStartTolerance = Duration(seconds: 60);

/// How long before a dive's start a timestamp still belongs to it.
const Duration _beforeDiveWindow = Duration(minutes: 30);

/// Why [DiveManager.addDives] did not keep a dive.
enum DroppedDiveReason {
  /// The same dive from another log file, which carries more.
  poorerCopy,

  /// Another dive with exactly the same start and end took its place.
  sameStartAndEnd,
}

/// A dive [DiveManager.addDives] dropped, and the one held instead.
class DroppedDive {
  const DroppedDive({
    required this.dropped,
    required this.kept,
    required this.reason,
  });

  final Dive dropped;
  final Dive kept;
  final DroppedDiveReason reason;
}

/// What tells whether two logs hold the same dive, and which of them
/// carries more: enough for the Dive Logs page to say of its list what
/// [DiveManager.addDives] does with the dives themselves.
typedef DiveCopy = ({
  DateTime start,
  String? logFormat,
  String? logPath,
  String? manufactor,
  int samples,
});

/// Whether [dive] is [held] in another format: both read from log files,
/// different files, starts within [sameDiveStartTolerance] and not from
/// different makers' computers (two computers worn on one dive stay two
/// dives).
bool isSameDive(DiveCopy dive, DiveCopy held) {
  if (_isEmpty(dive.logFormat) ||
      _isEmpty(held.logFormat) ||
      held.logPath == dive.logPath) {
    return false;
  }
  if (held.start.difference(dive.start).abs() > sameDiveStartTolerance) {
    return false;
  }
  final maker = _maker(dive.manufactor);
  final heldMaker = _maker(held.manufactor);
  return maker.isEmpty || heldMaker.isEmpty || maker == heldMaker;
}

/// Whether [dive] carries less than [held]: a lower format rank, or the
/// same rank and fewer samples.
bool isPoorerCopy(DiveCopy dive, DiveCopy held) {
  final rank = logFormatRank[dive.logFormat ?? ''] ?? 0;
  final heldRank = logFormatRank[held.logFormat ?? ''] ?? 0;
  if (rank != heldRank) {
    return rank < heldRank;
  }
  return dive.samples < held.samples;
}

DiveCopy _copy(Dive dive) => (
  start: dive.startTime,
  logFormat: dive.logFormat,
  logPath: dive.logPath,
  manufactor: dive.manufactor,
  samples: dive.waypoints.length,
);

class DiveManager {
  /// The dives held, keyed by (start, end), in the order they were added.
  final Map<(DateTime, DateTime), Dive> dives = {};

  /// Adds [newDives], keeping one copy of a dive loaded in several formats.
  ///
  /// Returns what was dropped on the way. Python drops silently; reporting
  /// it is the port's fix for spec §10.14. Which dives are kept, and in
  /// which order, is the same as in Python.
  List<DroppedDive> addDives(List<Dive> newDives) {
    final dropped = <DroppedDive>[];
    for (final dive in newDives) {
      final sameDive = _sameDiveKey(dive);
      if (sameDive != null) {
        final held = dives[sameDive]!;
        if (isPoorerCopy(_copy(dive), _copy(held))) {
          dropped.add(
            DroppedDive(
              dropped: dive,
              kept: held,
              reason: DroppedDiveReason.poorerCopy,
            ),
          );
          continue;
        }
        dives.remove(sameDive);
        dropped.add(
          DroppedDive(
            dropped: held,
            kept: dive,
            reason: DroppedDiveReason.poorerCopy,
          ),
        );
      }
      final key = (dive.startTime, dive.endTime);
      final replaced = dives[key];
      if (replaced != null && !identical(replaced, dive)) {
        dropped.add(
          DroppedDive(
            dropped: replaced,
            kept: dive,
            reason: DroppedDiveReason.sameStartAndEnd,
          ),
        );
      }
      dives[key] = dive;
    }
    return dropped;
  }

  /// The first dive, in the order added, with
  /// `start − 30 min ≤ timestamp ≤ end`.
  ///
  /// The 30 minutes before the dive are as in Python (spec §10.10, not
  /// decided yet).
  Dive? findDiveForTimestamp(DateTime timestamp) {
    assert(timestamp.isUtc, naiveTimeMessage);
    for (final dive in dives.values) {
      final earliest = dive.startTime.subtract(_beforeDiveWindow);
      if (!timestamp.isBefore(earliest) && !timestamp.isAfter(dive.endTime)) {
        return dive;
      }
    }
    return null;
  }

  /// The key of a dive already held that is [dive] in another format
  /// ([isSameDive]).
  (DateTime, DateTime)? _sameDiveKey(Dive dive) {
    final copy = _copy(dive);
    for (final entry in dives.entries) {
      if (isSameDive(copy, _copy(entry.value))) {
        return entry.key;
      }
    }
    return null;
  }
}

bool _isEmpty(String? text) => text == null || text.isEmpty;

final _whitespace = RegExp(r'\s+');
final _edgeCommas = RegExp(r'^,+|,+$');

/// The first word of the maker's name, without commas at its ends, in
/// lower case ("Shearwater Research, Inc" and "Shearwater" are one maker).
String _maker(String? manufactor) {
  final words = (manufactor ?? '')
      .split(_whitespace)
      .where((word) => word.isNotEmpty);
  final first = words.isEmpty ? '' : words.first;
  return first.replaceAll(_edgeCommas, '').toLowerCase();
}
