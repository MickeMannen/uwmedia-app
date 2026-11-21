/// The progress of a run (Python `FfmpegClass.run_command`'s reading of
/// ffmpeg's `-progress` lines and `utils/progress_lines.py`).
library;

import 'dart:convert';

import 'package:uwmedia_app/core/util/py_round.dart';

/// The arguments that make ffmpeg report its progress on its error
/// stream, a line at a time, and nothing else.
const progressArgs = ['-progress', 'pipe:2', '-nostats', '-loglevel', 'error'];

/// Turns ffmpeg's progress lines into the percentage of a file's whole
/// run. [duration] is the clip's length in seconds; [rangeStart] and
/// [rangeEnd] the share of the file's run the encode is (the colour runs
/// analyse the clip first), so that the percentage keeps climbing across
/// the phases. Updates are held back to one a percent of the encode.
class EncodeProgress {
  EncodeProgress({
    required this.duration,
    this.rangeStart = 0.0,
    this.rangeEnd = 100.0,
  });

  final double? duration;
  final double rangeStart;
  final double rangeEnd;
  double _lastEmitted = 0.0;

  bool get _measured => duration != null && duration! != 0;

  /// The percentage to report for a line of ffmpeg's progress output, or
  /// `null` when the line is no step worth one.
  double? onLine(String line) {
    if (!_measured || !line.contains('out_time_us=')) {
      return null;
    }
    final micros = int.tryParse(line.split('=')[1].trim());
    if (micros == null) {
      return null;
    }
    final seconds = micros / 1000000.0;
    final raw = seconds / duration! * 100;
    final pct = raw > 100.0 ? 100.0 : raw;
    if (pct - _lastEmitted >= 1.0 || pct >= 100.0) {
      _lastEmitted = pct;
      return rangeStart + pct * (rangeEnd - rangeStart) / 100.0;
    }
    return null;
  }

  /// The percentage to report once ffmpeg has ended well, or `null` when
  /// the end was reported already: ffmpeg's last time falls a frame short
  /// of the duration.
  double? onDone() => _measured && _lastEmitted < 100.0 ? rangeEnd : null;
}

/// A progress line as the Python command line prints it, for one file
/// ([label]) or without a name.
String progressLine(double percent, [String? label]) =>
    'UWMEDIA_FFMPEG_PROGRESS ${pyFormatFixed(percent, 1)}'
    '${(label ?? '').isEmpty ? '' : ' $label'}';

/// Progress of the phases before the encode, for one file, held back to
/// one update a percent.
class FileProgress {
  FileProgress(this.label);

  final String? label;
  double _last = -1.0;

  /// The percentage to report, or `null`.
  double? report(double percent) {
    if ((label ?? '').isNotEmpty && percent - _last >= 1.0) {
      _last = percent;
      return percent;
    }
    return null;
  }

  /// The work started again from the beginning (a phone's export the
  /// system interrupted): the next, lower percentages are reported.
  void restart() => _last = -1.0;
}

/// Complete lines out of a process's output as it arrives: a read can end
/// in the middle of a line, or of a UTF-8 character, and the rest is kept
/// until the next one.
class LineBuffer {
  final _decoded = StringBuffer();
  late final ByteConversionSink _sink = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(StringConversionSink.fromStringSink(_decoded));
  String _pending = '';
  bool _closed = false;

  String _take() {
    final text = _decoded.toString();
    _decoded.clear();
    return text;
  }

  static String _line(String line) =>
      line.endsWith('\r') ? line.replaceFirst(RegExp(r'\r+$'), '') : line;

  /// The complete lines in [data] and what was left from earlier reads.
  List<String> feed(List<int> data) {
    _sink.add(data);
    final lines = (_pending + _take()).split('\n');
    _pending = lines.removeLast();
    return [for (final line in lines) _line(line)];
  }

  /// What is left once the process has ended: a last line without a line
  /// break.
  List<String> flush() {
    if (!_closed) {
      _closed = true;
      _sink.close();
    }
    final text = _pending + _take();
    _pending = '';
    return text.isEmpty ? [] : [_line(text)];
  }
}

/// A page's status once a run has ended. When the process was killed by a
/// signal ([crashed]) the code is the signal's number, and saying "exit
/// code 13" would be wrong.
String finishedText(int exitCode, {required bool crashed}) => crashed
    ? 'Failed - processing stopped (signal $exitCode)'
    : exitCode == 0
    ? 'Finished (exit code 0)'
    : 'Failed (exit code $exitCode)';
