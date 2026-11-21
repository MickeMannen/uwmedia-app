// The platform check: the same cases (integration_test/platform_check/
// cases.json) on every platform the app runs on, written to one report per
// run that tool/platform_check/compare.dart compares with another platform's
// report or with the Python app's (REPORT_FORMAT.md). Parsed logs, the
// rules engine, the colour engine, overlay renders, and the platform's own
// media engine on a short invented clip. A check that fails is recorded
// and the others still run; the test fails at the end when any did.
//
// Run from the repo (CONTRIBUTING.md, "Platform check"):
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/platform_check_test.dart -d <device>
// The driver saves build/platform_check/<platform>-<time>.json with the
// renders in the folder of the same name. On a desktop,
// `flutter test integration_test/platform_check_test.dart -d macos
// --dart-define=OUT=$PWD/build/platform_check` writes the same files
// without the driver.
//
// The timed runs use perf_clip.mp4 (beside cases.json, committed): a
// desktop build finds it in the repo it was built in, a phone asks for it
// with the system file picker (or `--dart-define=PERF_CLIP=<path>`, which a
// simulator can use for a path on the Mac). `--dart-define=PERF=0` leaves
// the timed runs out, `--dart-define=PERF_REPEATS=<n>` repeats each n
// times (default 1). At the end a screen shows the summary (also printed
// and saved as <report>.txt) with a Copy button and waits for Done, up to
// 30 minutes; `--dart-define=WAIT=0` does not wait (unattended runs).
//
// cases.json and the clip are built into the test (pack.g.dart, made by
// tool/platform_check/embed_pack.dart), so a phone needs nothing else.
// Everything is written into a temporary folder, the app's folders pointed
// there too, and removed at the end.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/app_paths.dart';

import 'platform_check/checks.dart';
import 'platform_check/engine_check.dart';
import 'platform_check/pack.g.dart';
import 'platform_check/renders.dart';
import 'platform_check/report_files.dart';
import 'platform_check/screens.dart';
import 'platform_check/summary.dart';

const _out = String.fromEnvironment('OUT');

/// How many times each perf run is done (`--dart-define=PERF_REPEATS=3`);
/// 0 takes the pack's `engine.perf.repeats`.
const _perfRepeats = int.fromEnvironment('PERF_REPEATS');

/// `PERF=0` leaves the timed runs out; `WAIT=0` neither asks for the perf
/// clip nor waits on the summary.
const _perfSwitch = String.fromEnvironment('PERF', defaultValue: '1');
const _waitSwitch = String.fromEnvironment('WAIT', defaultValue: '1');
const _perfClipDefine = String.fromEnvironment('PERF_CLIP');

bool _off(String value) =>
    const {'0', 'false', 'no', 'off'}.contains(value.toLowerCase());

/// How long the summary screen waits for Done, and the pick screen for a
/// file.
const _summaryWait = Duration(minutes: 30);
const _pickWait = Duration(minutes: 10);

/// The perf clip on this machine: [_perfClipDefine], else (a desktop build)
/// the file in the repo the app was built in, found from the executable
/// upwards, else the one the person picks. `(null, reason)` without one.
Future<(String?, String)> _findPerfClip(
  WidgetTester tester,
  String fileName,
) async {
  if (_off(_perfSwitch)) {
    return (null, 'the timed runs were switched off (PERF=0)');
  }
  if (_perfClipDefine.isNotEmpty) {
    return File(_perfClipDefine).existsSync()
        ? (_perfClipDefine, '')
        : (null, 'PERF_CLIP names no file: $_perfClipDefine');
  }
  final relative = p.join('integration_test', 'platform_check', fileName);
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 12; i++) {
    final candidate = p.join(dir.path, relative);
    if (File(candidate).existsSync()) {
      return (candidate, '');
    }
    if (dir.parent.path == dir.path) {
      break;
    }
    dir = dir.parent;
  }
  if (_off(_waitSwitch)) {
    return (null, 'no $fileName here, and WAIT=0 asks for none');
  }
  final done = Completer<String?>();
  final picked = await waitOnScreen<String?>(
    tester,
    PickClipScreen(done, fileName: fileName),
    done,
    timeout: _pickWait,
    onTimeout: () => null,
  );
  return picked == null ? (null, 'no $fileName was picked') : (picked, '');
}

/// The first line [executable] prints, or `null`.
Future<String?> _firstLine(String executable, List<String> args) async {
  try {
    final result = await Process.run(executable, args);
    final line = '${result.stdout}'.trim().split('\n').first.trim();
    return result.exitCode == 0 && line.isNotEmpty ? line : null;
  } on Object {
    return null;
  }
}

typedef _SysctlC = Int32 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<IntPtr>,
  Pointer<Void>,
  IntPtr,
);
typedef _SysctlDart = int Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<IntPtr>,
  Pointer<Void>,
  int,
);

/// The text value of the `sysctl` [name] on an Apple system, or `null`.
/// Plain `dart:ffi`, with libc's malloc and free (no ffi package).
String? _sysctlText(String name) {
  try {
    final libc = DynamicLibrary.process();
    final sysctl = libc.lookupFunction<_SysctlC, _SysctlDart>('sysctlbyname');
    final malloc = libc
        .lookupFunction<
          Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)
        >('malloc');
    final free = libc
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('free');
    const room = 256;
    final key = utf8.encode(name);
    final keyPtr = malloc(key.length + 1).cast<Uint8>();
    final size = malloc(sizeOf<IntPtr>()).cast<IntPtr>();
    final value = malloc(room).cast<Uint8>();
    try {
      keyPtr.asTypedList(key.length + 1)
        ..setAll(0, key)
        ..[key.length] = 0;
      size.value = room;
      if (sysctl(keyPtr, value, size, nullptr, 0) != 0) {
        return null;
      }
      final bytes = value.asTypedList(size.value.clamp(0, room));
      final end = bytes.indexOf(0);
      return utf8.decode(end < 0 ? bytes : bytes.sublist(0, end));
    } finally {
      free(keyPtr.cast());
      free(size.cast());
      free(value.cast());
    }
  } on Object {
    return null;
  }
}

/// What the report says of the machine: no names, no serials.
Future<Map<String, Object?>> _platform() async {
  final env = Platform.environment;
  String? model;
  var simulator = false;
  if (Platform.isMacOS) {
    model = await _firstLine('/usr/sbin/sysctl', ['-n', 'hw.model']);
  } else if (Platform.isLinux) {
    try {
      model = File('/sys/devices/virtual/dmi/id/product_name')
          .readAsStringSync()
          .trim();
    } on FileSystemException {
      model = null;
    }
  } else if (Platform.isAndroid) {
    final maker = await _firstLine('getprop', ['ro.product.manufacturer']);
    final name = await _firstLine('getprop', ['ro.product.model']);
    model = [?maker, ?name].join(' ');
    simulator =
        await _firstLine('getprop', ['ro.kernel.qemu']) == '1' ||
        await _firstLine('getprop', ['ro.boot.qemu']) == '1';
  } else if (Platform.isIOS) {
    // A phone's model (iPhone19,7); a simulator gives the Mac's processor
    // (arm64). The SIMULATOR_* variables do not reach an app that flutter
    // drive starts.
    final machine = _sysctlText('hw.machine');
    simulator =
        env.containsKey('SIMULATOR_DEVICE_NAME') ||
        (machine != null && !RegExp('^(iPhone|iPad|iPod)').hasMatch(machine));
    model = simulator
        ? env['SIMULATOR_MODEL_IDENTIFIER'] ?? env['SIMULATOR_DEVICE_NAME']
        : machine;
  }
  return {
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'device': model == null || model.isEmpty ? null : model,
    'simulator': simulator,
    'processors': Platform.numberOfProcessors,
    'dart': Platform.version,
    'build_mode': kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the platform check', (tester) async {
    final started = DateTime.now().toUtc();
    final watch = Stopwatch()..start();
    final packBytes = base64Decode(packJsonBase64);
    final pack = jsonDecode(utf8.decode(packBytes)) as Map<String, dynamic>;
    final clip = base64Decode(clipBase64);
    final perfSpec =
        ((pack['engine'] as Map<String, dynamic>)['perf']
                as Map<String, dynamic>)['clip']
            as Map<String, dynamic>;
    final perfFile = perfSpec['file'] as String;

    // A folder of its own, and the app's folders in it.
    final mobile = Platform.isAndroid || Platform.isIOS;
    final base = mobile ? await getTemporaryDirectory() : Directory.systemTemp;
    final work = base.createTempSync('uwmedia_platform_check_');
    await initAppPaths(
      paths: AppPaths((
        config: p.join(work.path, 'config'),
        data: p.join(work.path, 'data'),
        cache: p.join(work.path, 'cache'),
        legacyBase: null,
      )),
    );

    final recorder = CheckRecorder();
    final files = <String, Uint8List>{};
    final engine = <String, Object?>{};
    final inputs = <String, Object?>{};
    try {
      final (rulesText, colorYaml) = await bundledRulesAndProfiles();
      final rules = jsonDecode(rulesText) as Map<String, dynamic>;
      inputs['hud_rules_sha256'] = sha256Hex(utf8.encode(rulesText));
      inputs['color_yaml_sha256'] = sha256Hex(utf8.encode(colorYaml));
      await runDiveChecks(recorder, pack);
      await runRuleChecks(recorder, pack, rules);
      await runColorChecks(recorder, pack, colorYaml);

      HudKit? kit;
      Map<String, String>? texts;
      await recorder.run('setup', 'setup/overlay_kit', () async {
        kit = await HudKit.load();
        texts = await templateTexts();
        return {'template_files': texts!.length};
      });
      if (kit == null || texts == null) {
        const reason = 'the overlay fonts, rules or templates did not load';
        for (final c in (pack['renders'] as Map)['cases'] as List<dynamic>) {
          recorder.skip('renders', 'renders/${(c as Map)['id']}', reason);
        }
        recorder
          ..skip('engine', 'engine/ffmpeg_generate', reason)
          ..skip('engine', 'engine/source_clip', reason);
        final engineSection = pack['engine'] as Map<String, dynamic>;
        for (final r in engineSection['runs'] as List<dynamic>) {
          recorder.skip('engine', 'engine/${(r as Map)['id']}', reason);
        }
        recorder.skip('engine', 'engine/perf/clip', reason);
        final perf = engineSection['perf'] as Map<String, dynamic>;
        for (final id in perf['runs'] as List<dynamic>) {
          recorder.skip('engine', 'engine/perf/$id', reason);
        }
      } else {
        await runRenderChecks(recorder, pack, kit!, texts!, files);
        final (perfClip, perfSkip) = await _findPerfClip(tester, perfFile);
        await runEngineChecks(
          recorder,
          pack,
          kit!,
          clip,
          work,
          engine,
          texts: texts!,
          colorYaml: colorYaml,
          perfRepeats: _perfRepeats,
          perfClipPath: perfClip,
          perfSkipReason: perfSkip,
        );
      }
    } finally {
      try {
        work.deleteSync(recursive: true);
      } on FileSystemException {
        // The system's temp folder sweep takes it.
      }
    }

    final info = await PackageInfo.fromPlatform();
    final report = <String, Object?>{
      'format': reportFormat,
      'implementation': 'dart',
      'pack_format': pack['format'],
      'pack_sha256': sha256Hex(packBytes),
      'started': started.toIso8601String(),
      'duration_ms': watch.elapsedMilliseconds,
      'app': {
        'name': info.appName,
        'version': info.version,
        'build': info.buildNumber,
      },
      'platform': await _platform(),
      'engine': engine,
      'inputs': inputs,
      'summary': {
        'pass': recorder.count('pass'),
        'fail': recorder.count('fail'),
        'skip': recorder.count('skip'),
      },
      'checks': recorder.checks,
    };
    final text = summaryText(
      jsonDecode(jsonEncode(report)) as Map<String, dynamic>,
      clipSeconds: (perfSpec['duration_s'] as num).toDouble(),
    );
    binding.reportData = {
      'platform_check': report,
      'summary_text': text,
      'files': {for (final e in files.entries) e.key: base64Encode(e.value)},
    };
    // ignore: avoid_print
    print(text.trimRight());
    if (_out.isNotEmpty && !mobile) {
      final path = writePlatformCheckReport(_out, report, files, text: text);
      // ignore: avoid_print
      print('Platform check report: $path');
    }
    if (!_off(_waitSwitch)) {
      final done = Completer<void>();
      await waitOnScreen<void>(
        tester,
        SummaryScreen(text, done),
        done,
        timeout: _summaryWait,
        onTimeout: () {},
      );
    }
    final failed = [
      for (final c in recorder.checks)
        if (c['status'] == 'fail') '${c['id']}: ${c['reason']}',
    ];
    expect(failed, isEmpty, reason: 'checks that failed');
  }, timeout: const Timeout(Duration(minutes: 120)));
}
