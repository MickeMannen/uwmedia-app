// The preview's shaders against the colour engine on a device, with its
// graphics card (test/color/color_shader_test.dart is the same in the
// test runner's software renderer):
//
//   flutter test integration_test/color_shader_test.dart -d <device>
import 'package:integration_test/integration_test.dart';

import '../test/color/color_shader_test.dart' as shaders;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  shaders.main();
}
