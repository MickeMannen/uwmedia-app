// Compares two platform check reports (integration_test/platform_check/
// REPORT_FORMAT.md): two platforms of the Flutter app, or the Flutter app
// and the Python app on the same desktop.
//
//   dart run tool/platform_check/compare.dart <report A> <report B>
//       [--pack integration_test/platform_check/cases.json] [--all]
//
// Prints one line per check: identical, within tolerance, known deviation
// (a difference the spec lists, cases.json "known_differences"; only
// against the Python app), different, failed, skipped or missing; with the
// largest differences under each line that is not identical (--all lists
// every one). Exits 1 when a check is different, failed or missing.
//
// The tolerances (also in REPORT_FORMAT.md, "Comparing"):
// - Text, booleans, whole numbers, sizes, codecs, frame counts: exact.
// - Parsed dives and rules: 1e-6 on decimals (the same text parsed and the
//   same sums; only the last bits of a computed value may differ).
// - Colour filter: 1e-6 (float32 values; the parity test finds Python's
//   exactly). Corrected frame: 0.05 on each channel's mean. Its SHA-256 is
//   compared between two Dart reports (the same code; a difference means
//   the platform's maths differ) and only shown against Python (the parity
//   test allows 1 level on 0.1 % of the bytes, 3 after sharpening).
// - Renders: the PNGs themselves, over the area both have: the mean
//   absolute difference and the share of pixels off by more than 40 in a
//   channel. Against Python: 5.0 and 4 % (the port's golden test limits,
//   Flutter's rasteriser against Pillow's). Dart against Dart: 5.0 and 6 %:
//   the platforms' text rasterising differs (the first macOS / iOS
//   simulator run, 2026-11-15: glyph edges only, worst 3.3 and 4.3 %; the
//   macOS desktop draws text heavier than the iOS simulator and than
//   Pillow, so the two Dart platforms lie on either side of Python). An
//   element that moves, changes colour or goes missing is far above
//   either. Size within 1 px, the crop box within 2 px (an edge pixel more
//   or less); mean and hash only shown.
// - Engine: codec, size and frame count exact, duration within 0.05 s.
//   `engine/source_clip` is the clip itself read by the platform: its
//   frames' channel means within 4.0 over the frame and 12.0 per grid cell
//   (the YUV to RGB conversion of the platform's frame grab; a larger
//   difference means the platforms read the same video in other colours,
//   and the phone's colour analysis sees what its frame grab gives). The
//   runs are compared as the change from that clip, each platform against
//   its own reading of it (`mean_change` within 3.0, `grid_change` within
//   8.0: the encoders differ, VideoToolbox, NVENC, x265, MediaCodec,
//   AVFoundation), so that the measuring does not hide or fake a
//   difference in the run; their absolute means are only shown. Bytes,
//   hashes of re-made clips and messages are only shown.
// - Overlay-only runs (`engine/overlay/<format>`) and the perf runs are
//   compared as they are (absolute frame means within 4.0 / 12.0).
// - Performance: every engine check with a time of the run itself
//   (`run_ms`, or `run_ms_median` of a perf run's repeats) goes into a
//   table after the checks: A, B and B / A. Times never fail a comparison.
// - Times (time_ms, duration_ms, run_ms) and the platform facts are never
//   compared,
//   nor the `setup/` checks (an implementation's own preparation), which are
//   listed only when they failed.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const reportFormat = 'uwmedia-platform-check-report/1';

/// How one leaf of two results compares.
enum Outcome { identical, tolerated, known, info, different }

/// What a check comes to, in the order of severity.
enum CheckStatus {
  identical('identical'),
  tolerated('within tolerance'),
  known('known deviation'),
  skipped('skipped'),
  different('different'),
  failed('failed'),
  missing('missing');

  const CheckStatus(this.label);
  final String label;

  bool get bad => this == different || this == failed || this == missing;
}

/// A leaf that is not identical: where, the two values and why it counts
/// as it does.
class LeafNote {
  LeafNote(this.path, this.a, this.b, this.outcome, this.note, [this.size]);

  final String path;
  final Object? a;
  final Object? b;
  final Outcome outcome;
  final String note;

  /// How far apart, for ordering (0 for text).
  final double? size;

  @override
  String toString() =>
      '$path: ${_short(a)} | ${_short(b)} (${outcome.name}: $note)';
}

String _short(Object? v) {
  final text = v is String ? v : jsonEncode(v);
  return text.length > 60 ? '${text.substring(0, 57)}...' : text;
}

const sourceClipId = 'engine/source_clip';

/// The engine values an implementation may leave out (`null` on one side
/// is only shown); any other missing value is a difference.
const optionalEngineKeys = {
  'frames',
  'source_frames',
  'samples',
  'layers',
  'messages',
  'bytes',
  'luts',
  'pictures',
};

/// The runs whose frames are the clip's own, changed: compared as the
/// change from `engine/source_clip` ([withChanges]).
const relativeRuns = {'engine/color', 'engine/color_overlay'};

/// An engine run's [result] with each frame's `mean` and `grid` also as
/// the change from the same frame of the clip ([source], the platform's
/// own reading of it): `mean_change`, `grid_change`. Each platform reads
/// frames with its own YUV to RGB conversion; the change the run made is
/// what is compared, the absolute values only shown.
Map<String, dynamic> withChanges(
  Map<String, dynamic> result,
  Map<String, dynamic> source,
) {
  final frames = result['frames_at'];
  final base = source['frames_at'];
  if (frames is! List || base is! List) {
    return result;
  }
  List<Object?> minus(Object? a, Object? b) => a is List && b is List
      ? [
          for (var i = 0; i < a.length && i < b.length; i++)
            a[i] is num && b[i] is num
                ? (a[i] as num) - (b[i] as num)
                : minus(a[i], b[i]),
        ]
      : const [];
  return {
    ...result,
    'frames_at': [
      for (final f in frames)
        () {
          final frame = f as Map<String, dynamic>;
          final from = base.cast<Map<String, dynamic>?>().firstWhere(
            (b) => b?['t'] == frame['t'],
            orElse: () => null,
          );
          if (from == null ||
              frame['grid'] is! List ||
              from['grid'] is! List ||
              (frame['grid'] as List).length != (from['grid'] as List).length) {
            return frame;
          }
          return {
            ...frame,
            'mean_change': minus(frame['mean'], from['mean']),
            'grid_change': minus(frame['grid'], from['grid']),
          };
        }(),
    ],
  };
}

/// The comparison of one check.
class CheckComparison {
  CheckComparison(this.id, this.status, this.notes, [this.detail = '']);

  final String id;
  final CheckStatus status;
  final List<LeafNote> notes;
  final String detail;
}

/// A rule of how a leaf compares.
sealed class Rule {
  const Rule();
}

class Exact extends Rule {
  const Exact();
}

class Within extends Rule {
  const Within(this.limit, this.why);
  final double limit;
  final String why;
}

class Shown extends Rule {
  const Shown(this.why);
  final String why;
}

const _exact = Exact();

/// The rule for the leaf at [path] (keys and list indices) of a check of
/// [area]; [python] when one of the reports is the Python app's.
/// [relative]: an engine run whose frames are compared as the change from
/// the clip ([withChanges]); their absolute values are then only shown.
Rule ruleFor(
  String area,
  List<Object> path, {
  required bool python,
  bool relative = false,
}) {
  final keys = path.whereType<String>().toList();
  final key = keys.isEmpty ? '' : keys.last;
  if (key == 'time_ms' ||
      key == 'duration_ms' ||
      key == 'run_ms' ||
      key == 'run_ms_median' ||
      key == 'repeats' ||
      keys.contains('run_ms')) {
    return const Shown('a time: see the performance table');
  }
  switch (area) {
    case 'dives':
    case 'rules':
      return const Within(1e-6, 'the last bits of a computed value');
    case 'color':
      if (keys.contains('filter')) {
        return const Within(1e-6, 'float32 values');
      }
      if (key == 'corrected_mean') {
        return const Within(0.05, 'a level on a few bytes');
      }
      if (key == 'corrected_sha256' && python) {
        return const Shown('NumPy and Dart round a few bytes differently');
      }
      return _exact;
    case 'renders':
      if (key == 'size') {
        return const Within(1, 'an edge pixel more or less');
      }
      if (key == 'box') {
        return const Within(2, 'an edge pixel more or less');
      }
      if (key == 'mean' || key == 'rgb_sha256' || key == 'png') {
        return const Shown('the PNGs are compared instead');
      }
      return _exact;
    case 'engine':
      if (key == 'duration_s') {
        return const Within(0.05, 'the container\'s rounding');
      }
      if (keys.contains('grid_change')) {
        return const Within(8.0, 'the encoders differ');
      }
      if (keys.contains('mean_change')) {
        return const Within(3.0, 'the encoders differ');
      }
      if (keys.contains('grid')) {
        return relative
            ? const Shown('the change from the clip is compared')
            : const Within(12.0, 'YUV to RGB conversions');
      }
      if (key == 'mean' && keys.contains('frames_at')) {
        return relative
            ? const Shown('the change from the clip is compared')
            : const Within(4.0, 'YUV to RGB conversions');
      }
      if (const {
        'bytes',
        'encoder',
        'sha256',
        'same_as_pack_clip',
        'messages',
      }.contains(key)) {
        return const Shown('depends on the encoder or the ffmpeg build');
      }
      return _exact;
  }
  return _exact;
}

/// A difference cases.json lists as intended (spec §10), for leaves of a
/// dives check when one report is the Python app's.
class KnownDifference {
  KnownDifference(Map<String, dynamic> json)
    : area = json['area'] as String,
      keys = (json['keys'] as List<dynamic>?)?.cast<String>(),
      formats = (json['formats'] as List<dynamic>?)?.cast<String>(),
      when = json['when'] as String,
      spec = json['spec'] as String? ?? '';

  final String area;
  final List<String>? keys;
  final List<String>? formats;
  final String when;
  final String spec;

  /// Whether the leaf whose path has the keys [pathKeys] (the leaf's own
  /// last; a listed key matches the leaf or any key above it) differs as
  /// this entry says.
  bool matches(
    String checkArea,
    List<String> pathKeys,
    String? format,
    Object? python,
    Object? dart,
  ) {
    if (checkArea != area ||
        (keys != null && !pathKeys.any(keys!.contains)) ||
        (formats != null && !formats!.contains(format))) {
      return false;
    }
    return switch (when) {
      'python_zero_dart_null' => python is num && python == 0 && dart == null,
      'python_null_dart_value' => python == null && dart != null,
      _ => false,
    };
  }
}

/// Compares two values of a check of [area], leaf by leaf, into [notes].
/// [pythonIsA] / [pythonIsB] say which side is Python's.
void compareValues(
  String area,
  Object? a,
  Object? b,
  List<LeafNote> notes, {
  List<Object> path = const [],
  bool pythonIsA = false,
  bool pythonIsB = false,
  List<KnownDifference> known = const [],
  String? format,
  bool relative = false,
}) {
  final python = pythonIsA || pythonIsB;
  String where() => path.map((e) => e is int ? '[$e]' : '/$e').join();
  if (a is Map && b is Map) {
    final keys = {...a.keys, ...b.keys}.cast<String>().toList()..sort();
    for (final k in keys) {
      compareValues(
        area,
        a[k],
        b[k],
        notes,
        path: [...path, k],
        pythonIsA: pythonIsA,
        pythonIsB: pythonIsB,
        known: known,
        format: format,
        relative: relative,
      );
    }
    return;
  }
  if (a is List && b is List) {
    final listRule = ruleFor(area, path, python: python, relative: relative);
    if (a.length != b.length && listRule is Shown) {
      notes.add(LeafNote(where(), a, b, Outcome.info, listRule.why));
      return;
    }
    if (a.length != b.length) {
      notes.add(
        LeafNote(
          where(),
          'length ${a.length}',
          'length ${b.length}',
          Outcome.different,
          'not as many entries',
        ),
      );
      return;
    }
    for (var i = 0; i < a.length; i++) {
      compareValues(
        area,
        a[i],
        b[i],
        notes,
        path: [...path, i],
        pythonIsA: pythonIsA,
        pythonIsB: pythonIsB,
        known: known,
        format: format,
        relative: relative,
      );
    }
    return;
  }
  if (a == b || (a is num && b is num && a.toDouble() == b.toDouble())) {
    return;
  }
  final rule = ruleFor(area, path, python: python, relative: relative);
  final leafKey = path.whereType<String>().lastOrNull ?? '';
  if (area == 'engine' &&
      (a == null || b == null) &&
      optionalEngineKeys.contains(leafKey)) {
    // A phone's engine may not give a value ffprobe gives (a frame count),
    // nor the Python app every count of a run.
    notes.add(LeafNote(where(), a, b, Outcome.info, 'not reported by one'));
    return;
  }
  if (rule is Shown) {
    notes.add(LeafNote(where(), a, b, Outcome.info, rule.why));
    return;
  }
  if (rule is Within && a is num && b is num) {
    final gap = (a - b).abs().toDouble();
    notes.add(
      LeafNote(
        where(),
        a,
        b,
        gap <= rule.limit ? Outcome.tolerated : Outcome.different,
        'off by ${_number(gap)}, limit ${_number(rule.limit)} (${rule.why})',
        gap,
      ),
    );
    return;
  }
  if (python) {
    final pathKeys = path.whereType<String>().toList();
    final pythonValue = pythonIsA ? a : b;
    final dartValue = pythonIsA ? b : a;
    for (final k in known) {
      if (k.matches(area, pathKeys, format, pythonValue, dartValue)) {
        notes.add(LeafNote(where(), a, b, Outcome.known, k.spec));
        return;
      }
    }
  }
  final aIsNumber = a is num;
  notes.add(
    LeafNote(
      where(),
      a,
      b,
      Outcome.different,
      aIsNumber && b is num ? 'not equal' : 'not the same value',
      aIsNumber && b is num ? (a - b).abs().toDouble() : null,
    ),
  );
}

String _number(double v) => v == 0
    ? '0'
    : (v.abs() >= 0.01 ? v.toStringAsFixed(3) : v.toStringAsExponential(1));

// --- PNG ----------------------------------------------------------------------

/// A decoded picture: three bytes a pixel.
class RgbPicture {
  RgbPicture(this.width, this.height, this.rgb);

  final int width;
  final int height;
  final Uint8List rgb;
}

/// An 8-bit, non-interlaced PNG (grey, grey and alpha, RGB or RGBA) as RGB,
/// the alpha dropped. Throws a [FormatException] for anything else.
RgbPicture decodePng(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  for (var i = 0; i < 8; i++) {
    if (bytes.length < 8 || bytes[i] != signature[i]) {
      throw const FormatException('not a PNG');
    }
  }
  final data = ByteData.sublistView(bytes);
  var offset = 8;
  int? width;
  int? height;
  int? colourType;
  final idat = BytesBuilder(copy: false);
  while (offset + 8 <= bytes.length) {
    final length = data.getUint32(offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    final body = Uint8List.sublistView(bytes, offset + 8, offset + 8 + length);
    if (type == 'IHDR') {
      width = data.getUint32(offset + 8);
      height = data.getUint32(offset + 12);
      final depth = body[8];
      colourType = body[9];
      if (depth != 8 || body[12] != 0) {
        throw FormatException('PNG depth $depth, interlace ${body[12]}');
      }
    } else if (type == 'IDAT') {
      idat.add(body);
    } else if (type == 'IEND') {
      break;
    }
    offset += 12 + length;
  }
  if (width == null || height == null) {
    throw const FormatException('PNG without a header');
  }
  final channels = switch (colourType) {
    0 => 1,
    2 => 3,
    4 => 2,
    6 => 4,
    _ => throw FormatException('PNG colour type $colourType'),
  };
  final raw = zlib.decode(idat.takeBytes());
  final stride = width * channels;
  final pixels = Uint8List(stride * height);
  var prior = Uint8List(stride);
  var at = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[at++];
    final line = Uint8List(stride);
    for (var x = 0; x < stride; x++) {
      final value = raw[at++];
      final left = x >= channels ? line[x - channels] : 0;
      final up = prior[x];
      final upLeft = x >= channels ? prior[x - channels] : 0;
      line[x] = switch (filter) {
        0 => value,
        1 => value + left,
        2 => value + up,
        3 => value + ((left + up) >> 1),
        4 => value + _paeth(left, up, upLeft),
        _ => throw FormatException('PNG filter $filter'),
      };
    }
    pixels.setRange(y * stride, (y + 1) * stride, line);
    prior = line;
  }
  final rgb = Uint8List(width * height * 3);
  for (var i = 0, o = 0; i < pixels.length; i += channels) {
    if (channels < 3) {
      rgb[o++] = pixels[i];
      rgb[o++] = pixels[i];
      rgb[o++] = pixels[i];
    } else {
      rgb[o++] = pixels[i];
      rgb[o++] = pixels[i + 1];
      rgb[o++] = pixels[i + 2];
    }
  }
  return RgbPicture(width, height, rgb);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

/// (mean absolute difference, share of pixels off by more than 40 in a
/// channel) over the area both pictures have, as the golden tests measure.
(double, double) pictureDifference(RgbPicture a, RgbPicture b) {
  final w = math.min(a.width, b.width);
  final h = math.min(a.height, b.height);
  if (w == 0 || h == 0) {
    return (double.infinity, 1);
  }
  var sum = 0;
  var changed = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = 3 * (y * a.width + x);
      final j = 3 * (y * b.width + x);
      var worst = 0;
      for (var c = 0; c < 3; c++) {
        final d = (a.rgb[i + c] - b.rgb[j + c]).abs();
        sum += d;
        if (d > worst) worst = d;
      }
      if (worst > 40) changed++;
    }
  }
  return (sum / (w * h * 3), changed / (w * h));
}

/// The render limits (mean, share) for a pair of reports.
(double, double) renderLimits({required bool python}) =>
    python ? (5.0, 0.04) : (5.0, 0.06);

// --- reports ------------------------------------------------------------------

/// The folder a report's PNGs lie in: its path without `.json`.
String filesDirOf(String reportPath) => reportPath.endsWith('.json')
    ? reportPath.substring(0, reportPath.length - 5)
    : '${reportPath}_files';

/// Compares two reports. [filesA] / [filesB] give a render's PNG bytes by
/// its name (`null` when it is not there).
List<CheckComparison> compareReports(
  Map<String, dynamic> a,
  Map<String, dynamic> b, {
  Uint8List? Function(String name)? filesA,
  Uint8List? Function(String name)? filesB,
  List<KnownDifference> known = const [],
}) {
  final pythonIsA = a['implementation'] == 'python';
  final pythonIsB = b['implementation'] == 'python';
  final python = pythonIsA || pythonIsB;
  Map<String, Map<String, dynamic>> byId(Map<String, dynamic> r) => {
    for (final c in r['checks'] as List<dynamic>)
      (c as Map<String, dynamic>)['id'] as String: c,
  };
  final checksA = byId(a);
  final checksB = byId(b);
  final ids = [
    ...checksA.keys,
    for (final id in checksB.keys)
      if (!checksA.containsKey(id)) id,
  ];
  final out = <CheckComparison>[];
  for (final id in ids) {
    final ca = checksA[id];
    final cb = checksB[id];
    if (id.startsWith('setup/')) {
      // An implementation's own preparation: shown only when it failed.
      final failed = [ca, cb].where((c) => c?['status'] == 'fail');
      if (failed.isNotEmpty) {
        out.add(
          CheckComparison(
            id,
            CheckStatus.failed,
            const [],
            failed.map((c) => '${c!['reason']}').join('; '),
          ),
        );
      }
      continue;
    }
    if (ca == null || cb == null) {
      out.add(
        CheckComparison(
          id,
          CheckStatus.missing,
          const [],
          'only in ${ca == null ? 'B' : 'A'}',
        ),
      );
      continue;
    }
    final sa = ca['status'];
    final sb = cb['status'];
    if (sa == 'fail' || sb == 'fail') {
      out.add(
        CheckComparison(
          id,
          CheckStatus.failed,
          const [],
          [
            if (sa == 'fail') 'A: ${ca['reason']}',
            if (sb == 'fail') 'B: ${cb['reason']}',
          ].join('; '),
        ),
      );
      continue;
    }
    if (sa == 'skip' || sb == 'skip') {
      out.add(
        CheckComparison(
          id,
          CheckStatus.skipped,
          const [],
          [
            if (sa == 'skip') 'A: ${ca['reason']}',
            if (sb == 'skip') 'B: ${cb['reason']}',
          ].join('; '),
        ),
      );
      continue;
    }
    final area = ca['area'] as String;
    final notes = <LeafNote>[];
    var ra = ca['result'];
    var rb = cb['result'];
    var relative = false;
    final sourceA = checksA[sourceClipId]?['result'];
    final sourceB = checksB[sourceClipId]?['result'];
    if (area == 'engine' &&
        relativeRuns.contains(id) &&
        sourceA is Map<String, dynamic> &&
        sourceB is Map<String, dynamic> &&
        ra is Map<String, dynamic> &&
        rb is Map<String, dynamic>) {
      ra = withChanges(ra, sourceA);
      rb = withChanges(rb, sourceB);
      relative = true;
    }
    compareValues(
      area,
      ra,
      rb,
      notes,
      pythonIsA: pythonIsA,
      pythonIsB: pythonIsB,
      known: known,
      format: ra is Map ? ra['format'] as String? : null,
      relative: relative,
    );
    var detail = '';
    if (area == 'renders' && ra is Map && rb is Map) {
      final name = ra['png'] as String? ?? '$id.png';
      final pa = filesA?.call(name);
      final pb = filesB?.call(rb['png'] as String? ?? name);
      if (pa == null || pb == null) {
        notes.add(
          LeafNote(
            '/png',
            pa == null ? 'no file' : 'file',
            pb == null ? 'no file' : 'file',
            Outcome.different,
            'the PNG is missing',
          ),
        );
      } else {
        final RgbPicture ia;
        final RgbPicture ib;
        try {
          ia = decodePng(pa);
          ib = decodePng(pb);
        } on Object catch (e) {
          notes.add(
            LeafNote('/png', name, name, Outcome.different, 'unreadable: $e'),
          );
          out.add(CheckComparison(id, CheckStatus.different, notes));
          continue;
        }
        final (mean, changed) = pictureDifference(ia, ib);
        final (meanLimit, changedLimit) = renderLimits(python: python);
        detail =
            'mean ${mean.toStringAsFixed(2)} (limit $meanLimit), '
            '${(100 * changed).toStringAsFixed(2)} % of pixels > 40 '
            '(limit ${100 * changedLimit} %)';
        if (mean > 0 || changed > 0) {
          notes.add(
            LeafNote(
              '/png',
              '${ia.width}x${ia.height}',
              '${ib.width}x${ib.height}',
              mean <= meanLimit && changed <= changedLimit
                  ? Outcome.tolerated
                  : Outcome.different,
              detail,
              mean,
            ),
          );
        }
      }
    }
    final outcomes = notes.map((n) => n.outcome).toSet();
    final status = outcomes.contains(Outcome.different)
        ? CheckStatus.different
        : outcomes.contains(Outcome.known)
        ? CheckStatus.known
        : outcomes.contains(Outcome.tolerated)
        ? CheckStatus.tolerated
        : CheckStatus.identical;
    out.add(CheckComparison(id, status, notes, detail));
  }
  return out;
}

/// The timed runs of two reports side by side: per `engine/` check with a
/// time of the run itself, A's and B's milliseconds (the median of the
/// repeats for a perf run) and B / A. Empty when neither has any.
String performanceTable(Map<String, dynamic> a, Map<String, dynamic> b) {
  Map<String, (num, String)> times(Map<String, dynamic> r) => {
    for (final c in (r['checks'] as List<dynamic>).cast<Map<String, dynamic>>())
      if (c['area'] == 'engine' &&
          c['status'] == 'pass' &&
          c['result'] is Map<String, dynamic>)
        if (((c['result'] as Map<String, dynamic>)['run_ms_median'] ??
                (c['result'] as Map<String, dynamic>)['run_ms'])
            case final num ms)
          c['id'] as String: (ms, '${(c['result'] as Map)['encoder'] ?? ''}'),
  };
  final ta = times(a);
  final tb = times(b);
  final ids = [
    ...ta.keys,
    for (final id in tb.keys)
      if (!ta.containsKey(id)) id,
  ];
  if (ids.isEmpty) {
    return '';
  }
  final width = ids.fold(5, (w, id) => math.max(w, id.length));
  String ms(num? v) => v == null ? '-' : '${v.round()} ms';
  final lines = [
    '${'check'.padRight(width)}  ${'A'.padLeft(10)}  ${'B'.padLeft(10)}'
        '  ${'B / A'.padLeft(6)}  encoders',
  ];
  for (final id in ids) {
    final x = ta[id];
    final y = tb[id];
    final ratio = x == null || y == null || x.$1 == 0
        ? '-'
        : (y.$1 / x.$1).toStringAsFixed(2);
    lines.add(
      '${id.padRight(width)}  ${ms(x?.$1).padLeft(10)}  '
      '${ms(y?.$1).padLeft(10)}  ${ratio.padLeft(6)}  '
      '${x?.$2 ?? '-'} | ${y?.$2 ?? '-'}',
    );
  }
  return lines.join('\n');
}

String _describe(Map<String, dynamic> r) {
  final platform = r['platform'] as Map<String, dynamic>? ?? const {};
  final engine = r['engine'] as Map<String, dynamic>? ?? const {};
  final app = r['app'] as Map<String, dynamic>? ?? const {};
  return [
    '${r['implementation']} ${app['version'] ?? ''}'.trim(),
    '${platform['os']} ${platform['os_version'] ?? ''}'.trim(),
    if (platform['device'] != null) '${platform['device']}',
    if (platform['simulator'] == true) 'simulator',
    'engine: ${engine['engine'] ?? engine['kind'] ?? 'none'}'
        '${engine['encoder'] == null ? '' : ' (${engine['encoder']})'}',
    'started ${r['started']}',
  ].join(', ');
}

Map<String, dynamic> _read(String path) {
  final json = jsonDecode(File(path).readAsStringSync());
  if (json is! Map<String, dynamic> || json['format'] != reportFormat) {
    throw FormatException('$path is not a $reportFormat report');
  }
  return json;
}

Uint8List? Function(String) _filesOf(String reportPath) => (name) {
  final file = File('${filesDirOf(reportPath)}${Platform.pathSeparator}$name');
  return file.existsSync() ? file.readAsBytesSync() : null;
};

void main(List<String> args) {
  final paths = <String>[];
  var packPath = 'integration_test/platform_check/cases.json';
  var all = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--pack' && i + 1 < args.length) {
      packPath = args[++i];
    } else if (args[i] == '--all') {
      all = true;
    } else {
      paths.add(args[i]);
    }
  }
  if (paths.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/platform_check/compare.dart <report A> '
      '<report B> [--pack cases.json] [--all]',
    );
    exit(2);
  }
  final a = _read(paths[0]);
  final b = _read(paths[1]);
  final known = <KnownDifference>[];
  final pack = File(packPath);
  if (pack.existsSync()) {
    final json = jsonDecode(pack.readAsStringSync()) as Map<String, dynamic>;
    for (final k in json['known_differences'] as List<dynamic>? ?? const []) {
      known.add(KnownDifference(k as Map<String, dynamic>));
    }
  } else {
    stdout.writeln('(no $packPath: known deviations are not recognised)');
  }
  final python =
      a['implementation'] == 'python' || b['implementation'] == 'python';
  stdout
    ..writeln('A: ${_describe(a)}')
    ..writeln('B: ${_describe(b)}')
    ..writeln(
      python
          ? 'Against the Python app: render limits 5.0 / 4 %.'
          : 'Dart against Dart: render limits 5.0 / 6 %.',
    );
  if (a['pack_sha256'] != b['pack_sha256']) {
    stdout.writeln('WARNING: the reports ran different case packs.');
  }
  final ia = a['inputs'] as Map<String, dynamic>? ?? const {};
  final ib = b['inputs'] as Map<String, dynamic>? ?? const {};
  for (final key in {...ia.keys, ...ib.keys}) {
    if (ia[key] != ib[key]) {
      stdout.writeln('WARNING: $key differs: the inputs are not the same.');
    }
  }
  stdout.writeln();

  final results = compareReports(
    a,
    b,
    filesA: _filesOf(paths[0]),
    filesB: _filesOf(paths[1]),
    known: known,
  );
  final width = results.fold(0, (w, r) => math.max(w, r.id.length));
  for (final r in results) {
    stdout.writeln(
      '${r.status.label.padRight(17)} ${r.id.padRight(width)}'
      '${r.detail.isEmpty ? '' : '  ${r.detail}'}',
    );
    if (r.status == CheckStatus.identical && !all) {
      continue;
    }
    final shown =
        r.notes.where((n) => n.outcome != Outcome.info || all).toList()
          ..sort((x, y) {
            final rank = y.outcome.index.compareTo(x.outcome.index);
            return rank != 0 ? rank : (y.size ?? 0).compareTo(x.size ?? 0);
          });
    for (final n in all ? shown : shown.take(3)) {
      stdout.writeln('    $n');
    }
    if (!all && shown.length > 3) {
      stdout.writeln('    ... ${shown.length - 3} more (--all)');
    }
  }
  final table = performanceTable(a, b);
  if (table.isNotEmpty) {
    stdout
      ..writeln()
      ..writeln('Performance (median of the timed runs; never a failure):')
      ..writeln(table);
  }
  final counts = <CheckStatus, int>{};
  for (final r in results) {
    counts[r.status] = (counts[r.status] ?? 0) + 1;
  }
  stdout
    ..writeln()
    ..writeln(
      [
        for (final s in CheckStatus.values)
          if (counts[s] != null) '${counts[s]} ${s.label}',
      ].join(', '),
    );
  exit(results.any((r) => r.status.bad) ? 1 : 0);
}
