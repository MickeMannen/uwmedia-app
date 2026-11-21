// Where a platform check report goes on disk (REPORT_FORMAT.md, "Files"):
// `<dir>/<name>.json` and its renders in `<dir>/<name>/`, the name made of
// the platform and the time the run started. Plain dart:io, for the driver
// on the host and for the test on a desktop.
import 'dart:convert';
import 'dart:io';

/// `<os>[-simulator]-<yyyymmdd>-<hhmmss>` of [report] (its platform and its
/// UTC start).
String reportName(Map<String, dynamic> report) {
  final platform = report['platform'] as Map<String, dynamic>? ?? const {};
  final os = '${platform['os'] ?? 'unknown'}';
  final started = DateTime.tryParse('${report['started']}')?.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = started == null
      ? 'unknown'
      : '${started.year}${two(started.month)}${two(started.day)}-'
            '${two(started.hour)}${two(started.minute)}${two(started.second)}';
  final kind = report['implementation'] == 'python' ? 'python-' : '';
  return '$kind$os${platform['simulator'] == true ? '-simulator' : ''}-$stamp';
}

/// Writes [report] and its [files] (PNG bytes by name) into [dir], and
/// the summary [text] as `<name>.txt` beside it; gives the report's path.
String writePlatformCheckReport(
  String dir,
  Map<String, dynamic> report,
  Map<String, List<int>> files, {
  String? text,
}) {
  final name = reportName(report);
  final folder = Directory('$dir${Platform.pathSeparator}$name')
    ..createSync(recursive: true);
  for (final e in files.entries) {
    File('${folder.path}${Platform.pathSeparator}${e.key}')
        .writeAsBytesSync(e.value);
  }
  final path = '$dir${Platform.pathSeparator}$name.json';
  if (text != null) {
    File('$dir${Platform.pathSeparator}$name.txt').writeAsStringSync(text);
  }
  File(
    path,
  ).writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(report)}\n');
  return path;
}
