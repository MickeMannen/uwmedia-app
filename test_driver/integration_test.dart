// The host side of `flutter drive` for the integration tests: waits for the
// test on the device and passes on its result, as the stock
// integrationDriver does, and saves a platform check report
// (integration_test/platform_check_test.dart) into build/platform_check/
// whether the test passed or not, so that a failing check can be looked at.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';

import '../integration_test/platform_check/report_files.dart';

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  final json = await driver.requestData(
    null,
    timeout: const Duration(minutes: 150),
  );
  final response = Response.fromJson(json);
  await driver.close();

  final data = response.data;
  final report = data?['platform_check'];
  if (report is Map<String, dynamic>) {
    final files = <String, List<int>>{
      for (final e
          in (data?['files'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: base64Decode(e.value as String),
    };
    final path = writePlatformCheckReport(
      'build${Platform.pathSeparator}platform_check',
      report,
      files,
      text: data?['summary_text'] as String?,
    );
    final summary = report['summary'];
    stdout.writeln('Platform check report: $path ($summary)');
  }
  if (response.allTestsPassed) {
    stdout.writeln('All tests passed.');
    exit(0);
  }
  stdout.writeln('Failure Details:\n${response.formattedFailureDetails}');
  exit(1);
}
