// Checks a platform check report's timed runs (engine/perf/*) against the
// times recorded for the same machine, so that a release does not ship a
// slowdown unnoticed.
//
//   dart run tool/platform_check/perf_gate.dart <report.json> [--update]
//       [--baselines tool/platform_check/perf_baselines]
//
// The baseline is one file per machine, <os>-<device>.json in the
// baselines folder (the report's platform os and device), written by
// --update from a report whose checks all passed. A run is:
// - slower when it takes more than 15 % and more than 150 ms longer than
//   the baseline (the floor keeps the short PNG run's jitter out);
// - faster the other way round (the baseline can be lowered with
//   --update, so a later slowdown is measured from the better time);
// - not comparable when its encoder or the build mode differs from the
//   baseline's, or it is missing from the report.
// Exits 1 when a run is slower, missing or not comparable, or the machine
// has no baseline; 0 otherwise. --update writes the baseline instead (the
// owner's call after a slowdown that is accepted, or a speed-up).
import 'dart:convert';
import 'dart:io';

const baselineFormat = 'uwmedia-perf-baseline/1';
const defaultBaselines = 'tool/platform_check/perf_baselines';

/// A run may take this much longer than its baseline, by both measures,
/// before it counts as slower.
const slowerRatio = 1.15;
const slowerFloorMs = 150;

enum PerfStatus { same, faster, slower, missing, notComparable }

typedef PerfLine = ({
  String id,
  PerfStatus status,
  num? baselineMs,
  num? ms,
  String? note,
});

/// The file name of the machine's baseline: `<os>-<device>.json`, with
/// anything but letters, digits, dot, dash and underscore made a dash.
String baselineName(Map<String, dynamic> report) {
  final platform = report['platform'] as Map<String, dynamic>? ?? const {};
  final key =
      '${platform['os'] ?? 'unknown'}-${platform['device'] ?? 'unknown'}';
  return '${key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')}.json';
}

/// The timed runs of [report]: id to (median ms, encoder).
Map<String, (num, String?)> perfRuns(Map<String, dynamic> report) => {
  for (final c
      in (report['checks'] as List<dynamic>).cast<Map<String, dynamic>>())
    if ((c['id'] as String).startsWith('engine/perf/') &&
        c['status'] == 'pass' &&
        c['result'] is Map<String, dynamic>)
      if ((c['result'] as Map<String, dynamic>)['run_ms_median']
          case final num ms)
        c['id'] as String: (ms, (c['result'] as Map)['encoder'] as String?),
};

/// The baseline [report] would write.
Map<String, dynamic> baselineOf(Map<String, dynamic> report, {String? commit}) {
  final platform = report['platform'] as Map<String, dynamic>? ?? const {};
  final runs = perfRuns(report);
  int? repeats;
  for (final c
      in (report['checks'] as List<dynamic>).cast<Map<String, dynamic>>()) {
    if ((c['id'] as String).startsWith('engine/perf/') &&
        c['result'] is Map<String, dynamic>) {
      repeats ??= (c['result'] as Map)['repeats'] as int?;
    }
  }
  return {
    'format': baselineFormat,
    'about':
        'The platform check timed runs on this machine, the times a '
        'release is held to (tool/platform_check/perf_gate.dart). Written '
        'by --update; not edited by hand.',
    'machine': {
      'os': platform['os'],
      'os_version': platform['os_version'],
      'device': platform['device'],
      'processors': platform['processors'],
    },
    'build_mode': platform['build_mode'],
    'app': report['app'],
    'commit': ?commit,
    'recorded': report['started'],
    'repeats': repeats,
    'runs': {
      for (final MapEntry(key: id, value: (ms, encoder)) in runs.entries)
        id: {'ms': ms, 'encoder': encoder},
    },
  };
}

/// Each baseline run against [report].
List<PerfLine> gate(
  Map<String, dynamic> report,
  Map<String, dynamic> baseline,
) {
  final platform = report['platform'] as Map<String, dynamic>? ?? const {};
  final mode = platform['build_mode'];
  final modeDiffers = mode != baseline['build_mode'];
  final runs = perfRuns(report);
  final lines = <PerfLine>[];
  for (final MapEntry(key: id, value: base)
      in (baseline['runs'] as Map<String, dynamic>).entries) {
    final baseMs = (base as Map<String, dynamic>)['ms'] as num;
    final run = runs[id];
    if (run == null) {
      lines.add((
        id: id,
        status: PerfStatus.missing,
        baselineMs: baseMs,
        ms: null,
        note: 'not in the report, or it failed',
      ));
      continue;
    }
    final (ms, encoder) = run;
    String? note;
    if (modeDiffers) {
      note = 'build mode $mode, baseline ${baseline['build_mode']}';
    } else if (encoder != base['encoder']) {
      note = 'encoder $encoder, baseline ${base['encoder']}';
    }
    final PerfStatus status;
    if (note != null) {
      status = PerfStatus.notComparable;
    } else if (ms > baseMs * slowerRatio && ms - baseMs > slowerFloorMs) {
      status = PerfStatus.slower;
    } else if (baseMs > ms * slowerRatio && baseMs - ms > slowerFloorMs) {
      status = PerfStatus.faster;
    } else {
      status = PerfStatus.same;
    }
    lines.add((id: id, status: status, baselineMs: baseMs, ms: ms, note: note));
  }
  return lines;
}

/// Whether [lines] let a release through.
bool passes(List<PerfLine> lines) => lines.every(
  (l) => l.status == PerfStatus.same || l.status == PerfStatus.faster,
);

String table(List<PerfLine> lines) {
  const names = {
    PerfStatus.same: 'same',
    PerfStatus.faster: 'faster',
    PerfStatus.slower: 'SLOWER',
    PerfStatus.missing: 'MISSING',
    PerfStatus.notComparable: 'NOT COMPARABLE',
  };
  final width = lines.fold(5, (w, l) => w > l.id.length ? w : l.id.length);
  String ms(num? v) => v == null ? '-' : '${v.round()} ms';
  return [
    '${'run'.padRight(width)}  ${'baseline'.padLeft(10)}  '
        '${'now'.padLeft(10)}  ${'now / base'.padLeft(10)}  result',
    for (final l in lines)
      '${l.id.padRight(width)}  ${ms(l.baselineMs).padLeft(10)}  '
          '${ms(l.ms).padLeft(10)}  '
          '${(l.ms == null || l.baselineMs == null || l.baselineMs == 0 ? '-' : (l.ms! / l.baselineMs!).toStringAsFixed(2)).padLeft(10)}  '
          '${names[l.status]}${l.note == null ? '' : ' (${l.note})'}',
  ].join('\n');
}

String? _commit() {
  try {
    final r = Process.runSync('git', ['rev-parse', '--short', 'HEAD']);
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  } on ProcessException {
    return null;
  }
}

void main(List<String> args) {
  String? reportPath;
  var baselines = defaultBaselines;
  var update = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--update':
        update = true;
      case '--baselines' when i + 1 < args.length:
        baselines = args[++i];
      case final a when !a.startsWith('--') && reportPath == null:
        reportPath = a;
      default:
        stderr.writeln(
          'Usage: dart run tool/platform_check/perf_gate.dart <report.json> '
          '[--update] [--baselines <folder>]',
        );
        exit(2);
    }
  }
  final report =
      jsonDecode(File(reportPath!).readAsStringSync()) as Map<String, dynamic>;
  final platform = report['platform'] as Map<String, dynamic>? ?? const {};
  if (platform['simulator'] == true) {
    stderr.writeln('A simulator or emulator is not timed: use a real device.');
    exit(1);
  }
  final file = File('$baselines/${baselineName(report)}');
  if (update) {
    final failed = (report['checks'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((c) => c['status'] == 'fail')
        .map((c) => c['id'])
        .toList();
    if (failed.isNotEmpty) {
      stderr.writeln('Not recorded: checks failed in the report: $failed');
      exit(1);
    }
    final baseline = baselineOf(report, commit: _commit());
    if ((baseline['runs'] as Map).isEmpty) {
      stderr.writeln('Not recorded: the report has no timed runs.');
      exit(1);
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(baseline)}\n',
    );
    stdout.writeln('Baseline written: ${file.path}');
    return;
  }
  if (!file.existsSync()) {
    stderr.writeln(
      'No baseline for this machine (${file.path}). Record one from a '
      'passing run with --update.',
    );
    exit(1);
  }
  final baseline = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  if (baseline['format'] != baselineFormat) {
    stderr.writeln('${file.path} is not a $baselineFormat file.');
    exit(2);
  }
  final lines = gate(report, baseline);
  stdout
    ..writeln(
      'Baseline: ${file.path} (recorded ${baseline['recorded']}'
      '${baseline['commit'] == null ? '' : ', commit ${baseline['commit']}'})',
    )
    ..writeln(table(lines));
  if (passes(lines)) {
    stdout.writeln('\nNo slowdown.');
  } else {
    stdout.writeln(
      '\nSlower than the baseline: find the cause before the release, or, '
      'when the slowdown is accepted, record the new times with --update.',
    );
    exit(1);
  }
}
