/// The time a Color run has left (spec §10.97), from what the run itself
/// shows as it goes, in place of "elapsed over the share of files done":
///
/// - a file counts by its work ([RunFile.weight], its size), not as one
///   file among equals;
/// - the pace is that of the files that ended last ([recentFiles] of a
///   kind), not the run's from its start;
/// - a video in work is measured where it is: its encoding's own pace
///   from the moment it began, and how long the looking and drawing
///   before it took, not a fixed share of a file.
///
/// Several files are worked on at once; how many is what the run has
/// been seen to do. Nothing is said until a pace is known.
library;

import 'dart:math' as math;

/// A file of a run: its work against the others' (bytes) and whether it
/// is a video.
typedef RunFile = ({double weight, bool video});

/// The percent a video's encoding begins at, at the latest (the colour
/// analysis and the overlays come before; `hudProgressEnd`).
const encodeFrom = 14.0;

/// How many of the last ended files of a kind give the pace.
const recentFiles = 8;

/// The percent points of encoding seen before its pace is believed.
const minEncodeSpan = 3.0;

/// The share of a video's time before its encoding, until one is seen.
const defaultPrepShare = 0.14;

class _InWork {
  _InWork(this.file, this.start);

  final RunFile file;
  final double start;
  double percent = 0;

  // The first report from the encoding, and the last one.
  double? anchorTime;
  double anchorPercent = 0;
  double lastTime = 0;

  /// The seconds the encoding takes from its first report to its end,
  /// by its pace so far; `null` before enough of it is seen.
  double? get encodeSeconds {
    final from = anchorTime;
    final span = percent - anchorPercent;
    if (from == null || span < minEncodeSpan || lastTime <= from) {
      return null;
    }
    return (lastTime - from) * (100 - anchorPercent) / span;
  }

  /// The file's whole time by that pace.
  double? get projected => switch (encodeSeconds) {
    null => null,
    final encode => anchorTime! - start + encode,
  };
}

typedef _Ended = ({double weight, double seconds, double? prep});

class RunEstimate {
  /// [clock] gives seconds that only go forward. [files] are the run's
  /// files by the name the run calls them; [total] is their number when
  /// the run knows of more than [files] holds.
  RunEstimate(this.clock, Map<String, RunFile> files, {int? total})
    : _waiting = {
        for (final MapEntry(:key, :value) in files.entries)
          key: (weight: math.max(value.weight, 1), video: value.video),
      } {
    _unknown = math.max(0, (total ?? files.length) - files.length);
    final weights = _waiting.values.map((file) => file.weight);
    _meanWeight = weights.isEmpty
        ? 1
        : weights.reduce((a, b) => a + b) / weights.length;
    _mostlyVideo =
        _waiting.values.where((file) => file.video).length * 2 >=
        _waiting.length;
  }

  final double Function() clock;
  final Map<String, RunFile> _waiting;
  final Map<String, _InWork> _inWork = {};
  final Map<bool, List<_Ended>> _ended = {true: [], false: []};
  late int _unknown;
  late final double _meanWeight;
  late final bool _mostlyVideo;
  int _lanes = 1;

  RunFile get _stranger => (weight: _meanWeight, video: _mostlyVideo);

  /// [name] is being worked on now.
  void begun(String name) {
    if (_inWork.containsKey(name)) {
      return;
    }
    var file = _waiting.remove(name);
    if (file == null) {
      file = _stranger;
      _unknown = math.max(0, _unknown - 1);
    }
    _inWork[name] = _InWork(file, clock());
    _lanes = math.max(_lanes, _inWork.length);
  }

  /// [name] says how far it is, 0 to 100.
  void progress(String name, double percent) {
    final work = _inWork[name];
    if (work == null) {
      return;
    }
    final now = clock();
    work.percent = percent.clamp(0, 100).toDouble();
    if (work.percent >= encodeFrom && work.percent < 100) {
      if (work.anchorTime == null) {
        work.anchorTime = now;
        work.anchorPercent = work.percent;
      }
      work.lastTime = now;
    }
  }

  /// [name] ended. [counted]: it was worked through (not skipped, not
  /// failed), so its time says something about the others.
  void ended(String name, {required bool counted}) {
    final work = _inWork.remove(name);
    if (work == null) {
      // Never begun: skipped before any work.
      if (_waiting.remove(name) == null) {
        _unknown = math.max(0, _unknown - 1);
      }
      return;
    }
    if (!counted) {
      return;
    }
    final seconds = clock() - work.start;
    final list = _ended[work.file.video]!
      ..add((
        weight: work.file.weight,
        seconds: seconds,
        prep: work.anchorTime == null ? null : work.anchorTime! - work.start,
      ));
    if (list.length > recentFiles) {
      list.removeAt(0);
    }
  }

  // Seconds for a unit of weight, of videos or of photos.
  double? _pace(bool video) {
    final ended = _ended[video]!;
    if (ended.isNotEmpty) {
      return ended.fold<double>(0, (sum, file) => sum + file.seconds) /
          ended.fold<double>(0, (sum, file) => sum + file.weight);
    }
    // No such file ended yet: those in work whose end can be seen.
    var seconds = 0.0;
    var weight = 0.0;
    for (final work in _inWork.values) {
      final whole = work.projected;
      if (work.file.video == video && whole != null) {
        seconds += whole;
        weight += work.file.weight;
      }
    }
    return weight > 0 ? seconds / weight : null;
  }

  // The share of a video's time before its encoding, as seen.
  double get _prepShare {
    var prep = 0.0;
    var whole = 0.0;
    for (final file in _ended[true]!) {
      if (file.prep != null) {
        prep += file.prep!;
        whole += file.seconds;
      }
    }
    if (whole == 0) {
      for (final work in _inWork.values) {
        final projected = work.projected;
        if (projected != null) {
          prep += work.anchorTime! - work.start;
          whole += projected;
        }
      }
    }
    return whole > 0 ? (prep / whole).clamp(0.0, 1.0) : defaultPrepShare;
  }

  double? _leftOf(_InWork work, double now, double? pace, double prepShare) {
    final encode = work.encodeSeconds;
    if (encode != null) {
      final left = encode * (100 - work.percent) / (100 - work.anchorPercent);
      return math.max(0, left - (now - work.lastTime));
    }
    if (pace == null) {
      return null;
    }
    final whole = work.file.weight * pace;
    if (!work.file.video) {
      return math.max(0, whole - (now - work.start));
    }
    if (work.anchorTime != null) {
      return whole * (1 - prepShare);
    }
    final prepDone = (work.percent / encodeFrom).clamp(0.0, 1.0);
    return whole * prepShare * (1 - prepDone) + whole * (1 - prepShare);
  }

  /// The seconds the run has left; `null` while no pace is known.
  double? remaining() {
    final now = clock();
    final paces = {true: _pace(true), false: _pace(false)};
    // A kind none of which has ended goes by the other's pace.
    double? paceOf(bool video) => paces[video] ?? paces[!video];
    final prepShare = _prepShare;
    var sum = 0.0;
    var longest = 0.0;
    for (final work in _inWork.values) {
      final left = _leftOf(work, now, paceOf(work.file.video), prepShare);
      if (left == null) {
        return null;
      }
      sum += left;
      longest = math.max(longest, left);
    }
    final waiting = [
      ..._waiting.values,
      for (var i = 0; i < _unknown; i++) _stranger,
    ];
    for (final file in waiting) {
      final pace = paceOf(file.video);
      if (pace == null) {
        return null;
      }
      sum += file.weight * pace;
    }
    final files = _inWork.length + waiting.length;
    if (files == 0) {
      return 0;
    }
    // The files' times were taken with [_lanes] of them in work at once.
    return math.max(longest, sum / math.min(_lanes, files));
  }
}
