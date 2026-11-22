// Output file names and the camera clock offset against the Python app: the
// cases of its tests/test_clock_offset.py, tests/test_output_naming.py,
// tests/test_filename_formats.py (the pattern checks) and
// tests/test_filename_presets.py, then the sweeps of the parity fixture
// made by tool/python_reference/naming_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/naming/clock_offset.dart';
import 'package:uwmedia_app/core/naming/filename_formats.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

import '../../helpers/python_reference.dart';

/// A folder's files as the fixture's file system saw them.
class FakeFiles {
  FakeFiles(Iterable<String> names, {required this.ignoreCase})
    : _names = {for (final name in names) _key(name, ignoreCase)};

  final bool ignoreCase;
  final Set<String> _names;

  static String _key(String name, bool ignoreCase) =>
      ignoreCase ? name.toLowerCase() : name;

  bool exists(String path) => _names.contains(_key(path, ignoreCase));

  bool sameFile(String a, String b) =>
      _key(a, ignoreCase) == _key(b, ignoreCase);
}

NamingArgs argsOf(Map<String, dynamic> json) => NamingArgs(
  renderVideoLog: json['render_video_log'] as bool? ?? false,
  originalLayoutStem: json['original_layout_stem'] as String?,
  renderLogFilenameFormat:
      json['render_log_filename_format'] as String? ??
      defaultRenderLogFilenameFormat,
  filenameFormat: json['filename_format'] as String?,
  keepFilename: json['keep_filename'] as bool? ?? false,
  overlayLayoutPaths: [
    for (final o in jsonObjects(json['overlay_instances'] ?? const <dynamic>[]))
      o['layout_path'] as String,
  ],
  overlayFormat: json['overlay_format'] as String? ?? overlayFormatHevc,
  color: json.containsKey('color') ? json['color'] as String? : 'default',
  layout: json['layout'] as String?,
  noOverwrite: json['no_overwrite'] as bool? ?? false,
  overwrite: json['overwrite'] as bool? ?? false,
);

void main() {
  final reference = pythonReference('naming/naming_cases.json');
  final ignoreCase = reference['case_insensitive_files'] as bool;

  group('tests/test_clock_offset.py', () {
    test('test_offset_text_reads_like_a_person_would_say_it', () {
      expect(formatOffset(0), '0 s');
      expect(formatOffset(7214), '+2 h 14 s');
      expect(formatOffset(-37), '-37 s');
      expect(formatOffset(3600), '+1 h');
      expect(formatOffset(-125), '-2 min 5 s');
    });

    test('test_dive_time_parsing_accepts_what_a_computer_shows', () {
      expect(parseDiveTime('12:34'), 754);
      expect(parseDiveTime('1:02:03'), 3723);
      expect(parseDiveTime('12.34'), 754);
      expect(parseDiveTime('754'), 754);
      expect(parseDiveTime('12m34s'), 754);
      expect(parseDiveTime(' 0:05 '), 5);
      expect(parseDiveTime('12:70'), isNull);
      expect(parseDiveTime('abc'), isNull);
      expect(parseDiveTime(''), isNull);
      expect(parseDiveTime(null), isNull);
    });

    test('a very long number is read, not thrown on', () {
      expect(parseDiveTime('${'9' * 30}:00'), greaterThan(1e30));
      expect(parseDiveTime('${'9' * 30}s'), greaterThan(1e29));
    });
  });

  group('tests/test_output_naming.py', () {
    final taken = naive(2026, 9, 5, 14, 30, 0, 123, 456);
    const photo = '/tmp/raw/DSC06641.JPG';
    String name(NamingArgs args, {String outputDir = '/tmp/out'}) =>
        outputFilename(
          source: photo,
          outputDir: outputDir,
          sourceIsFolder: true,
          args: args,
          creationDate: taken,
        );

    test('test_keep_filename_keeps_name_in_batch_to_other_folder', () {
      expect(name(const NamingArgs(keepFilename: true)), 'DSC06641.jpg');
    });

    test('test_default_batch_naming_is_still_date_taken', () {
      expect(name(const NamingArgs()), '20260905_143000_12.jpg');
    });

    test('test_filename_format_pattern', () {
      expect(
        name(const NamingArgs(filenameFormat: '%Y%m%d_Bali')),
        '20260905_Bali_12.jpg',
      );
    });

    test('test_filename_token_keeps_source_name_without_milliseconds', () {
      expect(
        name(const NamingArgs(filenameFormat: '{filename}_color')),
        'DSC06641_color.jpg',
      );
      expect(
        name(const NamingArgs(filenameFormat: '%Y%m%d_{filename}')),
        '20260905_DSC06641.jpg',
      );
    });

    test('test_keep_filename_into_source_folder_never_overwrites_source', () {
      for (final ignoreCase in [true, false]) {
        for (final overwrite in [false, true]) {
          final files = FakeFiles([photo], ignoreCase: ignoreCase);
          final args = NamingArgs(
            keepFilename: true,
            color: 'default',
            overwrite: overwrite,
          );
          final target = resolveTargetPath(
            target: '/tmp/raw/${name(args, outputDir: '/tmp/raw')}',
            source: photo,
            args: args,
            unique: UniquePaths(files.exists),
            sameFile: files.sameFile,
          );
          expect(target.skipped, isFalse);
          expect(
            target.path,
            ignoreCase ? '/tmp/raw/DSC06641_1.jpg' : '/tmp/raw/DSC06641.jpg',
          );
          expect(target.overwrites, isFalse);
        }
      }
    });

    test('test_no_overwrite_does_not_skip_because_of_the_source', () {
      final files = FakeFiles([photo], ignoreCase: true);
      final target = resolveTargetPath(
        target: '/tmp/raw/DSC06641.jpg',
        source: photo,
        args: const NamingArgs(
          keepFilename: true,
          color: 'default',
          noOverwrite: true,
        ),
        unique: UniquePaths(files.exists),
        sameFile: files.sameFile,
      );
      expect(target.skipped, isFalse);
      expect(target.path, '/tmp/raw/DSC06641_1.jpg');
    });

    test('test_no_overwrite_still_skips_earlier_output', () {
      final files = FakeFiles([
        photo,
        '/tmp/out/DSC06641.jpg',
      ], ignoreCase: true);
      final target = resolveTargetPath(
        target: '/tmp/out/DSC06641.jpg',
        source: photo,
        args: const NamingArgs(
          keepFilename: true,
          color: 'default',
          noOverwrite: true,
        ),
        unique: UniquePaths(files.exists),
        sameFile: files.sameFile,
      );
      expect(target.skipped, isTrue);
    });

    test('test_no_overwrite_skips_for_an_overlays_only_run', () {
      final files = FakeFiles([
        photo,
        '/tmp/out/DSC06641.jpg',
      ], ignoreCase: true);
      final target = resolveTargetPath(
        target: '/tmp/out/DSC06641.jpg',
        source: photo,
        args: const NamingArgs(
          keepFilename: true,
          noOverwrite: true,
          overlayLayoutPaths: ['x.json'],
        ),
        unique: UniquePaths(files.exists),
        sameFile: files.sameFile,
      );
      expect(target.skipped, isTrue);
    });

    test('overwrite says when it replaces a file', () {
      final files = FakeFiles([photo, '/tmp/out/a.jpg'], ignoreCase: false);
      TargetPath resolve(String target) => resolveTargetPath(
        target: target,
        source: photo,
        args: const NamingArgs(color: 'default', overwrite: true),
        unique: UniquePaths(files.exists),
        sameFile: files.sameFile,
      );
      expect(resolve('/tmp/out/a.jpg'), (
        path: '/tmp/out/a.jpg',
        skipped: false,
        overwrites: true,
      ));
      expect(resolve('/tmp/out/b.jpg').overwrites, isFalse);
    });

    test('test_hud_token_is_the_first_overlay_name', () {
      expect(
        name(
          const NamingArgs(
            filenameFormat: '%Y%m%d_%H%M%S_{hud}',
            overlayLayoutPaths: [
              '/tmp/x/garmin_mk3i_main.json',
              '/tmp/x/shearwater_perdix.json',
            ],
          ),
        ),
        '20260905_143000_garmin_mk3i_main_12.jpg',
      );
      expect(
        name(
          const NamingArgs(
            filenameFormat: '%Y%m%d_%H%M%S_{hud}',
            originalLayoutStem: 'my_hud',
          ),
        ),
        '20260905_143000_my_hud_12.jpg',
      );
    });

    test('test_hud_token_without_an_overlay_is_left_out', () {
      expect(
        name(const NamingArgs(filenameFormat: '%Y%m%d_%H%M%S_{hud}')),
        '20260905_143000_12.jpg',
      );
    });

    test('a pattern with an unknown date code gives the source name', () {
      expect(
        name(const NamingArgs(filenameFormat: '%Y_%Q')),
        'DSC06641_12.jpg',
      );
    });
  });

  group('tests/test_filename_formats.py and test_filename_presets.py', () {
    test('test_pattern_validation', () {
      const cases = {
        '%Y%m%d_%H%M%S_Bali': true,
        '%Y-%m-%d': true,
        '': false,
        '   ': false,
        'dive/%Y': false,
        r'dive\%Y': false,
        'no_codes_here': false,
      };
      cases.forEach((pattern, ok) {
        expect(patternError(pattern) == null, ok, reason: pattern);
      });
    });

    test('test_example_uses_preset_sample_date', () {
      expect(exampleFilename('%Y%m%d_%H%M%S_Bali'), '20260905_143000_Bali');
    });

    test('an unknown date code is an error on every platform', () {
      expect(patternError('%Y_%Q'), 'Invalid pattern: Unknown date code %Q');
      expect(patternError('%Y%'), startsWith('Invalid pattern: '));
      expect(exampleFilename('%Y_%Q'), '%Y_%Q');
      expect(() => pyStrftime(naive(2026), '%E'), throwsFormatException);
    });

    test('test_filename_format_presets_are_pairwise_distinct', () {
      final patterns = [for (final (_, p) in filenameFormatPresets) p];
      expect(patterns.toSet().length, patterns.length);
    });

    test('test_preset_lineup', () {
      expect(
        [for (final (label, _) in filenameFormatPresets) label.split(' (')[0]],
        [
          'Original',
          'Original + color',
          'Date + time',
          'Date + time + color',
          'Date + time + overlay',
        ],
      );
      final fixed = naive(2026, 9, 5, 14, 30);
      expect(filenameFormatPresets[0].$2, '');
      expect(filenameFormatPresets[1].$2, '{filename}_color');
      expect(pyStrftime(fixed, filenameFormatPresets[2].$2), '20260905_143000');
      expect(
        pyStrftime(fixed, filenameFormatPresets[3].$2),
        '20260905_143000_color',
      );
      expect(
        pyStrftime(fixed, filenameFormatPresets[4].$2),
        '20260905_143000_{hud}',
      );
    });

    test('test_legacy_labels_map_to_current_presets', () {
      final labels = {for (final (label, _) in filenameFormatPresets) label};
      legacyPresetLabels.forEach((old, current) {
        expect(labels, isNot(contains(old)));
        expect(labels, contains(current));
      });
    });
  });

  group('parity with Python', () {
    test('formatOffset', () {
      final clock = reference['clock'] as Map<String, dynamic>;
      for (final [value, want]
          in (clock['format_offset'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(formatOffset((value as num).toDouble()), want, reason: '$value');
      }
    });

    test('parseDiveTime', () {
      final clock = reference['clock'] as Map<String, dynamic>;
      for (final [text, want]
          in (clock['parse_dive_time'] as List<dynamic>)
              .cast<List<dynamic>>()) {
        final got = parseDiveTime(text as String);
        if (text == '١٢:٣٤') {
          // Python reads the digits of any script; the port only 0-9.
          expect(want, 754);
          expect(got, isNull);
        } else if (want == 'nan') {
          expect(got, isNaN, reason: text);
        } else if (want == 'inf') {
          expect(got, double.infinity, reason: text);
        } else {
          expect(got, want, reason: '"$text"');
        }
      }
    });

    test('pyStrftime', () {
      final strftime = reference['strftime'] as Map<String, dynamic>;
      final dates = [
        for (final text in strftime['dates'] as List<dynamic>)
          parseNaive(text as String),
      ];
      for (final [pattern, want]
          in (strftime['patterns'] as List<dynamic>).cast<List<dynamic>>()) {
        for (final (i, date) in dates.indexed) {
          expect(
            pyStrftime(date, pattern as String),
            (want as List<dynamic>)[i],
            reason: '$pattern on ${formatNaive(date)}',
          );
        }
      }
    });

    test('patternError, exampleFilename and the presets', () {
      final patterns = reference['patterns'] as Map<String, dynamic>;
      expect(formatNaive(exampleDateTime), patterns['example_datetime']);
      expect([
        for (final (label, pattern) in filenameFormatPresets) [label, pattern],
      ], patterns['presets']);
      expect(legacyPresetLabels, patterns['legacy_labels']);
      for (final [pattern, error, example]
          in (patterns['patterns'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(patternError(pattern as String), error, reason: pattern);
        expect(exampleFilename(pattern), example, reason: pattern);
      }
    });

    test('outputFilename', () {
      final cases = jsonObjects(reference['output_filename']);
      expect(cases.length, greaterThan(2000));
      // Python appended a photo's milliseconds ("_123"); the app
      // appends the hundredths ("_12", spec §10.95), so those names are
      // Python's without their last digit.
      var withMilliseconds = 0;
      for (final c in cases) {
        final taken = parseNaive(c['taken'] as String);
        final got = outputFilename(
          source: '/work/${c['source']}',
          outputDir: '/work/${c['output_dir']}',
          sourceIsFolder: c['source_is_dir'] as bool,
          args: argsOf(c['args'] as Map<String, dynamic>),
          creationDate: taken,
          forcedFilename: c['forced'] as String?,
        );
        final python = c['want'] as String;
        if (got == python) {
          continue;
        }
        withMilliseconds++;
        expect(
          '${pyStem(got)}${taken.millisecond % 10}${pySuffix(got)}',
          python,
          reason: '$c',
        );
      }
      expect(withMilliseconds, 255);
    });

    test('outputPathFor and the conversion names', () {
      final paths = reference['paths'] as Map<String, dynamic>;
      for (final [format, path, isVideo, want]
          in (paths['output_path_for'] as List<dynamic>)
              .cast<List<dynamic>>()) {
        expect(
          outputPathFor(
            format as String,
            path as String,
            isVideo: isVideo as bool,
          ),
          want,
          reason: '$format $path $isVideo',
        );
      }
      expect([
        for (final (name, w, h, rate) in convertResolutions) [name, w, h, rate],
      ], paths['convert_resolutions']);
      for (final [source, resolution, want]
          in (paths['convert_output_filename'] as List<dynamic>)
              .cast<List<dynamic>>()) {
        expect(
          convertOutputFilename('/media/$source', resolution as String),
          want,
          reason: '$source $resolution',
        );
      }
    });

    test('two files of a run with one name: the later one numbered', () {
      const args = NamingArgs(color: 'default');
      TargetPath Function(String) run(
        NamingArgs args,
        FakeFiles files,
        UniquePaths unique,
      ) =>
          (source) => resolveTargetPath(
            target: '/out/20260905_143000.jpg',
            source: source,
            args: args,
            unique: unique,
            sameFile: files.sameFile,
          );

      // Neither skip nor overwrite.
      var files = FakeFiles(const [], ignoreCase: ignoreCase);
      var next = run(args, files, UniquePaths(files.exists));
      expect(next('/raw/a.jpg').path, '/out/20260905_143000.jpg');
      expect(next('/raw/b.jpg').path, '/out/20260905_143000_1.jpg');
      expect(next('/raw/c.jpg').path, '/out/20260905_143000_2.jpg');

      // Overwrite: an earlier run's files are written over, each by its
      // own photo, and the first photo's is not written over by the
      // second.
      files = FakeFiles(const [
        '/out/20260905_143000.jpg',
      ], ignoreCase: ignoreCase);
      next = run(
        const NamingArgs(color: 'default', overwrite: true),
        files,
        UniquePaths(files.exists),
      );
      expect(next('/raw/a.jpg'), (
        path: '/out/20260905_143000.jpg',
        skipped: false,
        overwrites: true,
      ));
      expect(next('/raw/b.jpg'), (
        path: '/out/20260905_143000_1.jpg',
        skipped: false,
        overwrites: false,
      ));

      // Skip: the first is there and is skipped, the second is not there
      // and is written; with both there both are skipped.
      next = run(
        const NamingArgs(color: 'default', noOverwrite: true),
        files,
        UniquePaths(files.exists),
      );
      expect(next('/raw/a.jpg').skipped, isTrue);
      expect(next('/raw/b.jpg'), (
        path: '/out/20260905_143000_1.jpg',
        skipped: false,
        overwrites: false,
      ));
      files = FakeFiles(const [
        '/out/20260905_143000.jpg',
        '/out/20260905_143000_1.jpg',
      ], ignoreCase: ignoreCase);
      next = run(
        const NamingArgs(color: 'default', noOverwrite: true),
        files,
        UniquePaths(files.exists),
      );
      expect(next('/raw/a.jpg').skipped, isTrue);
      expect(next('/raw/b.jpg').skipped, isTrue);
    });

    test('UniquePaths', () {
      for (final run in jsonObjects(reference['unique'])) {
        final files = FakeFiles([
          for (final name in run['existing'] as List<dynamic>) '/d/$name',
        ], ignoreCase: ignoreCase);
        final unique = UniquePaths(files.exists);
        for (final [name, lower, want]
            in (run['calls'] as List<dynamic>).cast<List<dynamic>>()) {
          expect(
            unique.unique('/d/$name', lowerSuffix: lower as bool),
            '/d/$want',
            reason: '$run',
          );
        }
      }
    });

    test('resolveTargetPath', () {
      final cases = jsonObjects(reference['resolve']);
      expect(cases.length, 120);
      for (final c in cases) {
        final files = FakeFiles([
          for (final name in c['existing'] as List<dynamic>) '/d/$name',
        ], ignoreCase: ignoreCase);
        final got = resolveTargetPath(
          target: '/d/${c['target']}',
          source: '/d/${c['source']}',
          args: argsOf(c['args'] as Map<String, dynamic>),
          unique: UniquePaths(files.exists),
          sameFile: files.sameFile,
        );
        expect(
          [got.path, got.skipped],
          [
            '/d/${(c['want'] as List<dynamic>)[0]}',
            (c['want'] as List<dynamic>)[1],
          ],
          reason: '$c',
        );
      }
    });
  });
}
