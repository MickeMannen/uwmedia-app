// The parts of the platform check that are plain Dart (no Flutter, no
// files): the parsed logs, the rules engine and the colour engine on the
// cases of cases.json, each recorded as a check of the report described in
// REPORT_FORMAT.md. The test on a device runs them, and so does
// test/tool/platform_check_test.dart on the host.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

/// The report format's name and version; a reader refuses another.
const reportFormat = 'uwmedia-platform-check-report/1';

/// A check that ran but found something wrong: [reason] says what, and
/// [result] keeps what was measured up to there.
class CheckFailure implements Exception {
  CheckFailure(this.reason, [this.result]);

  final String reason;
  final Map<String, Object?>? result;

  @override
  String toString() => reason;
}

/// The checks of one run, in the order they ran. A check that throws is
/// recorded as failed and the next one runs.
class CheckRecorder {
  final List<Map<String, Object?>> checks = [];

  /// Runs [body] as the check [id] of [area] and records its result.
  Future<void> run(
    String area,
    String id,
    Future<Map<String, Object?>> Function() body,
  ) async {
    final watch = Stopwatch()..start();
    String status;
    String? reason;
    Map<String, Object?>? result;
    try {
      result = await body();
      status = 'pass';
    } on CheckFailure catch (e) {
      status = 'fail';
      reason = e.reason;
      result = e.result;
    } on Object catch (e, stack) {
      status = 'fail';
      final where = stack.toString().split('\n').take(4).join(' | ');
      reason = '$e ($where)';
    }
    checks.add({
      'area': area,
      'id': id,
      'status': status,
      'reason': reason,
      'time_ms': watch.elapsedMilliseconds,
      'result': jsonSafe(result),
    });
  }

  /// Records [id] of [area] as not run, for [reason].
  void skip(String area, String id, String reason) => checks.add({
    'area': area,
    'id': id,
    'status': 'skip',
    'reason': reason,
    'time_ms': 0,
    'result': null,
  });

  int count(String status) => checks.where((c) => c['status'] == status).length;
}

/// [value] with every number JSON cannot hold (NaN, infinities) as the
/// strings "nan", "inf" and "-inf".
Object? jsonSafe(Object? value) => switch (value) {
  final double d when d.isNaN => 'nan',
  final double d when d.isInfinite => d > 0 ? 'inf' : '-inf',
  final Map<String, Object?> m => {
    for (final e in m.entries) e.key: jsonSafe(e.value),
  },
  final List<Object?> l => [for (final v in l) jsonSafe(v)],
  _ => value,
};

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

// --- dives ------------------------------------------------------------------

/// What the report keeps of one dive: its summary and the [fields] of the
/// waypoint at each of [sampleSeconds] after its start.
Map<String, Object?> diveSummary(
  Dive dive,
  List<int> sampleSeconds,
  List<String> fields,
) => {
  'start_time': formatNaive(dive.startTime),
  'end_time': formatNaive(dive.endTime),
  'duration_s': dive.duration,
  'max_depth': dive.maxDepth,
  'waypoints': dive.waypoints.length,
  'device': dive.device,
  'manufactor': dive.manufactor,
  'timezone': dive.timezone,
  'is_ccr': dive.isCcr,
  'gf_low': dive.gfLow,
  'gf_high': dive.gfHigh,
  'log_format': dive.logFormat,
  'samples': [
    for (final s in sampleSeconds)
      () {
        final wp = dive.getWaypointAt(dive.startTime.add(Duration(seconds: s)));
        if (wp == null) {
          return <String, Object?>{'at_s': s, 'timestamp': null};
        }
        final json = wp.toJson();
        return <String, Object?>{
          'at_s': s,
          'timestamp': json['timestamp'],
          for (final f in fields)
            f: f == 'tanks'
                ? {
                    for (final key
                        in (json['tanks'] as Map<String, dynamic>).keys.toList()
                          ..sort())
                      key:
                          ((json['tanks'] as Map<String, dynamic>)[key]
                              as Map<String, dynamic>)['pressure_bar'],
                  }
                : json[f],
        };
      }(),
  ],
};

/// One check per log of the pack's `dives` section.
Future<void> runDiveChecks(
  CheckRecorder recorder,
  Map<String, dynamic> pack,
) async {
  final section = pack['dives'] as Map<String, dynamic>;
  final fields = [for (final f in section['fields'] as List<dynamic>) '$f'];
  for (final log in section['logs'] as List<dynamic>) {
    final entry = log as Map<String, dynamic>;
    await recorder.run('dives', 'dives/${entry['id']}', () async {
      final bytes = base64Decode(entry['bytes_base64'] as String);
      final name = entry['file_name'] as String;
      final format = detectLogFormat(name, bytes);
      final dives = parseLogFile(name, bytes) ?? const <Dive>[];
      final seconds = [
        for (final s in entry['sample_seconds'] as List<dynamic>) s as int,
      ];
      final result = <String, Object?>{
        'bytes_sha256': sha256Hex(bytes),
        'format': format,
        'dive_count': dives.length,
        'dives': [for (final d in dives) diveSummary(d, seconds, fields)],
      };
      if (format != entry['expect_format']) {
        throw CheckFailure(
          'format $format, expected ${entry['expect_format']}',
          result,
        );
      }
      if (dives.isEmpty) {
        throw CheckFailure('no dive parsed', result);
      }
      return result;
    });
  }
}

// --- rules ------------------------------------------------------------------

List<Object?>? _record(Object? value) => switch (value) {
  null => null,
  (final Object? a, final Object? b) => [a, b],
  (final Object? a, final Object? b, final Object? c, final Object? d) => [
    a,
    b,
    c,
    d,
  ],
  _ => throw ArgumentError('not a record: $value'),
};

/// One check per computer of the pack's `rules` section, on the dummy
/// dive. [rules] is hud_rules.json decoded.
Future<void> runRuleChecks(
  CheckRecorder recorder,
  Map<String, dynamic> pack,
  Map<String, dynamic> rules,
) async {
  final section = pack['rules'] as Map<String, dynamic>;
  final engine = HudRules(rules);
  final diveSpec = section['dive'] as Map<String, dynamic>;
  for (final c in section['computers'] as List<dynamic>) {
    final computer = c as Map<String, dynamic>;
    await recorder.run('rules', 'rules/${computer['id']}', () async {
      final m = computer['manufacturer'] as String?;
      final mo = computer['model'] as String?;
      final dive = buildDummyDive(
        variant: diveSpec['variant'] as String?,
        ccr: diveSpec['ccr'] == true,
        // Python's sample dive, without the port's SAC (spec §10.54).
        sac: false,
      );
      final wps = dive.waypoints;
      final timeline = <Map<String, Object?>>[];
      for (final t in section['times_s'] as List<dynamic>) {
        final w = waypointAt(dive, t as num)!;
        timeline.add({
          't': t,
          'time_since_start': w.timeSinceStart,
          'state': engine.resolveState(m, mo, w, wps),
          'stop_phase': _record(engine.stopPhase(m, mo, w, wps)),
          'safety_stop_status': _record(engine.safetyStopStatus(m, mo, w, wps)),
          'deco_clear_seconds': engine.decoClearSeconds(m, mo, w, wps),
          'ndl_before_clear': engine.getNdlBeforeClear(m, mo, w, wps),
          'safety_text': engine.getSafetyStopText(m, mo, w),
        });
      }
      final base = waypointAt(dive, section['forced_from_s'] as num);
      final forced = <String, Object?>{};
      for (final s in section['forced_states'] as List<dynamic>) {
        final (wp, history) = forcedDive(base, s as String);
        forced[s] = engine.resolveState(m, mo, wp, history);
      }
      return {'timeline': timeline, 'forced': forced};
    });
  }
}

// --- colour -----------------------------------------------------------------

/// `picture()` of tool/python_reference/color_fixture.py (the formula is in
/// cases.json): a gradient per channel, noise from a hash of the position,
/// and a bright disc.
RgbImage packPicture(List<dynamic> spec) {
  final [width as int, height as int, seed as int, base, gain, torch] = spec;
  final rgb = Uint8List(width * height * 3);
  final radius = (width < height ? width : height) ~/ 6;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - width ~/ 3;
      final dy = y - height ~/ 2;
      final disc = dx * dx + dy * dy < radius * radius;
      for (var c = 0; c < 3; c++) {
        final noise =
            ((x * 73856093) ^
                    (y * 19349663) ^
                    ((c + 1) * 83492791) ^
                    (seed * 2654435761)) %
                41 -
            20;
        final g = (gain as List<dynamic>)[c] as List<dynamic>;
        var value =
            ((base as List<dynamic>)[c] as int) +
            (x * (g[0] as int)) ~/ width +
            (y * (g[1] as int)) ~/ height +
            noise;
        if (torch == 1 && disc) {
          value += 70 - 10 * c;
        }
        rgb[(y * width + x) * 3 + c] = value.clamp(0, 255);
      }
    }
  }
  return RgbImage(width, height, rgb);
}

/// The mean of each channel of three-byte pixels.
List<double> channelMeans(Uint8List rgb) {
  final sums = [0, 0, 0];
  for (var i = 0; i + 2 < rgb.length; i += 3) {
    sums[0] += rgb[i];
    sums[1] += rgb[i + 1];
    sums[2] += rgb[i + 2];
  }
  final n = rgb.length ~/ 3;
  return [for (final s in sums) n == 0 ? 0.0 : s / n];
}

/// One check per frame and profile of the pack's `color` section.
/// [colorYaml] is the text of the bundled color.yaml.
Future<void> runColorChecks(
  CheckRecorder recorder,
  Map<String, dynamic> pack,
  String colorYaml,
) async {
  final section = pack['color'] as Map<String, dynamic>;
  final profiles = mergedColorProfiles(colorYaml, null);
  for (final f in section['frames'] as List<dynamic>) {
    final frameSpec = f as Map<String, dynamic>;
    final frame = packPicture(frameSpec['picture'] as List<dynamic>);
    final frameHash = sha256Hex(frame.rgb);
    for (final p in section['profiles'] as List<dynamic>) {
      final name = p as String;
      await recorder.run('color', 'color/${frameSpec['id']}/$name', () async {
        final values = profiles[name];
        if (values == null) {
          throw CheckFailure('no profile "$name" in color.yaml');
        }
        final engine = ColorEngine(ColorProfile.fromMap(values));
        final filter = engine.analyze(frame).filter;
        final corrected = engine.applyFilter(frame, filter);
        final result = <String, Object?>{
          'frame_size': [frame.width, frame.height],
          'frame_sha256': frameHash,
          'filter': [for (final v in filter) v],
          'corrected_mean': channelMeans(corrected.rgb),
          'corrected_sha256': sha256Hex(corrected.rgb),
        };
        if (filter.any((v) => !v.isFinite)) {
          throw CheckFailure('the filter is not finite', result);
        }
        return result;
      });
    }
  }
}
