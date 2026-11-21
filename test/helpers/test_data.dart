import 'dart:io';

/// The folder of the owner's private media and dive logs: `test_data/` in
/// the repo, or where `UWMEDIA_TEST_DATA` points. It is not in git, so on a
/// fresh clone it is missing and the tests that need it skip themselves.
Directory testDataDir() =>
    Directory(Platform.environment['UWMEDIA_TEST_DATA'] ?? 'test_data');

/// Why a test that needs [relativePath] under the test data cannot run, or
/// `null` when it is there. Use as the `skip:` of a `requires_media` test.
String? skipIfNoTestData([String relativePath = '']) {
  final path = '${testDataDir().path}/$relativePath';
  final there =
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  return there ? null : 'needs $path (the local test data)';
}
