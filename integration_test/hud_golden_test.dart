// The overlay golden test (test/hud/hud_golden_test.dart) on the real
// engine: the desktop app's own renderer (Impeller) instead of the test
// engine's, which may draw text differently. Run on a desktop, from the
// repo:
//   flutter test integration_test/hud_golden_test.dart -d macos \
//     --dart-define=REPO=$PWD
// (the test reads the fonts, templates and golden images of the repo).
import 'dart:io';

import 'package:integration_test/integration_test.dart';

import '../test/hud/hud_golden_test.dart' as golden;

const _repo = String.fromEnvironment('REPO');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (_repo.isNotEmpty) {
    Directory.current = _repo;
  }
  golden.main();
}
