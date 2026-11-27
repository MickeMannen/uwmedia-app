/// Running the bundled tools (ffmpeg, ffprobe, exiftool) as processes on
/// the desktop: one-shot runs that give their output, and long runs whose
/// lines are read as they come and that Stop ends with everything they
/// started (spec §10.2).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/engine/app_log.dart';

/// What the log calls a run of [executable]: the tool's name and the
/// start of its arguments.
String runName(String executable, List<String> args) {
  final text = [p.basenameWithoutExtension(executable), ...args].join(' ');
  return text.length <= 100 ? text : '${text.substring(0, 100)}…';
}

/// What a finished run left.
typedef RunResult = ({int exitCode, String stdout, String stderr});

/// Runs [executable] to its end. `null` when it could not be started or
/// took longer than [timeout], in which case it is stopped.
Future<RunResult?> runCapture(
  String executable,
  List<String> args, {
  Duration? timeout,
}) => AppLog.timed(
  'Tools',
  runName(executable, args),
  () => _runCapture(executable, args, timeout: timeout),
  slowMs: 2000,
);

Future<RunResult?> _runCapture(
  String executable,
  List<String> args, {
  Duration? timeout,
}) async {
  final Process process;
  try {
    process = await Process.start(executable, args);
  } on ProcessException {
    return null;
  }
  // Nothing is typed into a tool; one that waits for input gets its end.
  unawaited(process.stdin.close().catchError((Object _) {}));
  final out = process.stdout.transform(systemEncoding.decoder).join();
  final err = process.stderr.transform(systemEncoding.decoder).join();
  try {
    final exit = timeout == null
        ? await process.exitCode
        : await process.exitCode.timeout(timeout);
    return (exitCode: exit, stdout: await out, stderr: await err);
  } on TimeoutException {
    await killTree(process);
    return null;
  }
}

/// Runs [executable] to its end and gives what it wrote on standard
/// output as bytes (a picture, say); `null` when it could not be started
/// or ended with an error.
Future<Uint8List?> runForBytes(String executable, List<String> args) =>
    AppLog.timed(
      'Tools',
      runName(executable, args),
      () => _runForBytes(executable, args),
      slowMs: 2000,
    );

Future<Uint8List?> _runForBytes(String executable, List<String> args) async {
  final Process process;
  try {
    process = await Process.start(executable, args);
  } on ProcessException {
    return null;
  }
  unawaited(process.stdin.close().catchError((Object _) {}));
  unawaited(process.stderr.drain<void>().catchError((Object _) {}));
  final out = BytesBuilder(copy: false);
  await process.stdout.forEach(out.add);
  return await process.exitCode == 0 ? out.takeBytes() : null;
}

/// The Stop of a piece of work made of several runs: stops the run that
/// is going and tells the work not to start another.
class RunControl {
  bool _stopped = false;
  Future<void> Function()? _stopCurrent;

  bool get stopped => _stopped;

  /// The run that is going now, for [stop] to end.
  void running(ToolRun run) => _stopCurrent = run.stop;

  /// A process of the caller's own that is going now, and how to end it.
  // ignore: use_setters_to_change_properties, a hand-over, not a property
  void runningWith(Future<void> Function() stop) => _stopCurrent = stop;

  Future<void> stop() async {
    _stopped = true;
    await _stopCurrent?.call();
  }
}

/// The command that ends the process [pid] and every process it started
/// on Windows, where killing a process leaves its children running.
List<String> windowsTreeKill(int pid) => [
  'taskkill',
  '/T',
  '/F',
  '/PID',
  '$pid',
];

/// Ends [process] with everything it started. The tools are started
/// directly, never through a shell, so elsewhere than on Windows the
/// process itself is all there is.
Future<void> killTree(Process process) async {
  if (Platform.isWindows) {
    final command = windowsTreeKill(process.pid);
    try {
      await Process.run(command.first, command.sublist(1));
    } on ProcessException {
      process.kill();
    }
  } else {
    process.kill(ProcessSignal.sigkill);
  }
}

/// A tool that is running: its error stream a line at a time (ffmpeg
/// reports its progress there), and a way to stop it.
class ToolRun {
  ToolRun._(this._process, this.lines);

  /// Starts [executable]. Throws a [ProcessException] when it cannot be
  /// started.
  static Future<ToolRun> start(String executable, List<String> args) async {
    final process = await Process.start(executable, args);
    // Under way until it ends; the pages write what a long run did.
    unawaited(
      AppLog.timed(
        'Tools',
        runName(executable, args),
        () => process.exitCode,
        slowMs: null,
      ),
    );
    unawaited(process.stdin.close().catchError((Object _) {}));
    // Standard output is not read: what the tools write there in a long
    // run is nothing the app shows, and an unread pipe would stall them.
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));
    final buffer = LineBuffer();
    final lines = StreamController<String>();
    process.stderr.listen(
      (data) => buffer.feed(data).forEach(lines.add),
      onDone: () {
        buffer.flush().forEach(lines.add);
        lines.close();
      },
      onError: (Object _) {},
    );
    return ToolRun._(process, lines.stream);
  }

  final Process _process;

  /// The lines of the error stream; ends when the process has.
  final Stream<String> lines;
  bool _stopped = false;

  /// Whether [stop] ended the run.
  bool get stopped => _stopped;

  Future<int> get exitCode => _process.exitCode;

  /// Ends the run and everything it started.
  Future<void> stop() async {
    _stopped = true;
    await killTree(_process);
  }
}
