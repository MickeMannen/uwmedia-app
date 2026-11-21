/// The text of a problem report (spec §10.76): what the app and the
/// machine are, and the last lines of the app's log, for a user to read
/// and send. Nothing is sent by the app itself.
library;

/// How many of the log's last lines a report carries.
const reportLogLines = 400;

/// One line of the log: when, where in the app, what.
String logLine(DateTime at, String source, String text) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  // One line each, whatever a tool printed.
  final flat = text.trimRight().replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' | ');
  return '$stamp [$source] $flat';
}

/// The report: the [facts] (name and value, in order), then the [log]'s
/// last [reportLogLines] lines.
String reportText(Map<String, String> facts, List<String> log) {
  final lines = log.length > reportLogLines
      ? log.sublist(log.length - reportLogLines)
      : log;
  return [
    'UWMedia problem report',
    for (final MapEntry(:key, :value) in facts.entries) '$key: $value',
    '',
    lines.isEmpty ? 'The log is empty.' : 'Log (last ${lines.length} lines):',
    ...lines,
    '',
  ].join('\n');
}
