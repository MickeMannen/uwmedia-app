// Waiting in a widget test for work that takes real time (an isolate
// reading a dive log, a tool): a fixed pause is too short on a slow
// machine (the Windows runner, 2026-11-26) and too long everywhere else.
import 'package:flutter_test/flutter_test.dart';

/// Lets real time pass, a little at a time, until [found] finds
/// something or [timeout] is over; the caller's `expect` then says what
/// is missing.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder found, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clock = Stopwatch()..start();
  while (true) {
    await tester.pumpAndSettle();
    if (found.evaluate().isNotEmpty || clock.elapsed >= timeout) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
}
