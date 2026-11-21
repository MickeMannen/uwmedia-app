// The platform check's summary as plain text: what the results screen
// shows, the console gets and `<report>.txt` holds, for pasting. The layout
// is fixed by REPORT_FORMAT.md ("Summary text"); the Python app prints the
// same lines.

/// The summary of [report] (the report JSON as written); [clipSeconds] is
/// the perf clip's length, for the "x realtime" column.
String summaryText(Map<String, dynamic> report, {required double clipSeconds}) {
  final app = report['app'] as Map<String, dynamic>? ?? const {};
  final platform = report['platform'] as Map<String, dynamic>? ?? const {};
  final engine = report['engine'] as Map<String, dynamic>? ?? const {};
  final checks = [
    for (final c in report['checks'] as List<dynamic>? ?? const [])
      c as Map<String, dynamic>,
  ];
  final implementation = report['implementation'] == 'python'
      ? 'python'
      : 'flutter';
  final build = app['build'];
  final version =
      '${app['version'] ?? '?'}'
      '${build == null || '$build'.isEmpty ? '' : '+$build'}';

  final String engineLine;
  if (engine['engine'] == 'ffmpeg') {
    final words = '${engine['ffmpeg_version'] ?? ''}'.split(' ');
    final ffmpeg = words.length > 2 && words[1] == 'version' ? words[2] : '?';
    engineLine = 'ffmpeg $ffmpeg, ${engine['encoder'] ?? '?'}, hw accel on';
  } else if (engine['engine'] != null) {
    engineLine = '${engine['engine']}';
  } else {
    engineLine = 'none';
  }

  final byId = {for (final c in checks) c['id'] as String: c};
  final clipCheck = byId['engine/perf/clip'];
  final String clipLine;
  final clip = clipCheck?['result'];
  if (clipCheck?['status'] == 'pass' && clip is Map<String, dynamic>) {
    final sha = '${clip['sha256'] ?? ''}';
    final fps = clip['fps'];
    clipLine =
        'perf_clip.mp4 ${sha.length >= 12 ? sha.substring(0, 12) : sha}, '
        '${_fixed(clip['duration_s'], 1)} s '
        '${clip['width']}x${clip['height']} '
        '${fps is num ? fps.round() : '?'} fps';
  } else {
    clipLine = 'none (${clipCheck?['reason'] ?? 'not run'})';
  }

  final correctness = checks.where(
    (c) => !(c['id'] as String).startsWith('engine/perf/'),
  );
  int count(String status) =>
      correctness.where((c) => c['status'] == status).length;

  final perf = checks
      .where(
        (c) =>
            (c['id'] as String).startsWith('engine/perf/') &&
            c['id'] != 'engine/perf/clip',
      )
      .toList();
  final repeats = perf
      .map((c) => (c['result'] as Map<String, dynamic>?)?['repeats'])
      .whereType<int>()
      .firstOrNull;
  final lines = [
    'UWMedia platform check',
    'implementation: $implementation $version',
    'os: ${platform['os'] ?? '?'} ${platform['os_version'] ?? ''}'.trimRight(),
    'device: ${platform['device'] ?? 'unknown'}, '
        '${platform['processors'] ?? '?'} CPUs',
    'engine: $engineLine',
    'clip: $clipLine',
    'checks: ${count('pass')} pass, ${count('fail')} fail, '
        '${count('skip')} skip',
    'perf: median of ${repeats ?? 0}, seconds of the run itself, '
        'x realtime',
  ];
  for (final c in perf) {
    final name = (c['id'] as String).substring('engine/perf/'.length);
    final head = '  ${name.padRight(16)}';
    final result = c['result'];
    if (c['status'] == 'pass' && result is Map<String, dynamic>) {
      final ms = result['run_ms_median'] as num? ?? 0;
      final seconds = ms / 1000;
      final speed = seconds > 0 ? clipSeconds / seconds : 0.0;
      final out = result['output'] as Map<String, dynamic>? ?? const {};
      final mb = (out['bytes'] as num? ?? 0) / 1e6;
      lines.add(
        '$head${seconds.toStringAsFixed(2).padLeft(8)} s'
        '${speed.toStringAsFixed(2).padLeft(8)}x  '
        '${out['width']}x${out['height']} ${out['codec']} '
        '${mb.toStringAsFixed(1)} MB',
      );
    } else {
      final word = c['status'] == 'skip' ? 'skipped' : 'failed';
      lines.add('$head$word: ${c['reason'] ?? ''}');
    }
  }
  lines.add('started: ${report['started']}');
  return '${lines.join('\n')}\n';
}

String _fixed(Object? value, int digits) =>
    value is num ? value.toStringAsFixed(digits) : '?';
