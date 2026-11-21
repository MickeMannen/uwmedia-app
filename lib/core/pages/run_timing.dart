/// Elapsed and estimated remaining time of a long batch (Python
/// `utils/run_timing.py`), for the progress cards of Color, Overlay
/// Generator and Convertion.
///
/// The estimate is elapsed over the fraction done, and honest about its
/// limits: it is hidden until [minFraction] of the work and [minElapsed]
/// seconds are done (a first file much shorter or longer than the rest
/// gives nonsense before that), it is said with "about", and above a
/// minute it is rounded up to ten seconds so that it does not flicker.
/// The fraction is the whole batch's, not the file's in flight.
library;

import 'package:uwmedia_app/core/util/py_round.dart';

const minFraction = 0.03;
const minElapsed = 5.0;

/// 0:07, 4:12, 1:03:45: the shape of the pages' time labels.
String formatDuration(num seconds) {
  final rounded = pyRound(seconds.toDouble());
  final total = rounded < 0 ? 0 : rounded;
  final hours = total ~/ 3600;
  final minutes = total % 3600 ~/ 60;
  final secs = (total % 60).toString().padLeft(2, '0');
  return hours != 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$secs'
      : '$minutes:$secs';
}

/// A stopwatch with a remaining-time estimate. [clock] gives seconds that
/// only go forward.
class RunTimer {
  RunTimer(this.clock);

  final double Function() clock;
  double? _start;
  double? _end;
  bool _stoppedOk = true;

  void start() {
    _start = clock();
    _end = null;
    _stoppedOk = true;
  }

  /// Freezes the elapsed time; [ok] false marks an abort or a failure.
  void stop({bool ok = true}) {
    if (_start != null && _end == null) {
      _end = clock();
    }
    _stoppedOk = ok;
  }

  void reset() => _start = _end = null;

  bool get running => _start != null && _end == null;

  bool get started => _start != null;

  double get elapsed => _start == null ? 0.0 : (_end ?? clock()) - _start!;

  /// The seconds left, or `null` while too little is done to say.
  double? remaining(double? fraction) {
    if (!running || fraction == null) {
      return null;
    }
    final done = fraction > 1.0 ? 1.0 : fraction;
    final soFar = elapsed;
    if (done < minFraction || soFar < minElapsed) {
      return null;
    }
    final left = soFar * (1.0 - done) / done;
    return left > 60 ? (left / 10.0).ceilToDouble() * 10 : left;
  }

  /// The progress card's line: empty before the first run, "Elapsed
  /// 0:04", "Elapsed 4:12 · about 9:30 left", then "Finished in 13:41" or
  /// "Stopped after 2:10".
  String text(double? fraction) {
    if (_start == null) {
      return '';
    }
    if (!running) {
      return '${_stoppedOk ? 'Finished in' : 'Stopped after'} '
          '${formatDuration(elapsed)}';
    }
    final left = remaining(fraction);
    return 'Elapsed ${formatDuration(elapsed)}'
        '${left == null ? '' : ' · about ${formatDuration(left)} left'}';
  }
}
