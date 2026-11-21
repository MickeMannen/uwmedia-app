// The user's Pictures and Downloads folders as the app finds them
// (lib/engine/start_folders.dart) on the computer it runs on: both found,
// and both folders that are there. Run:
//   flutter test integration_test/start_folders_test.dart -d <macos|windows|linux>
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/config/app_settings.dart';
import 'package:uwmedia_app/engine/start_folders.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Pictures and Downloads are found', (tester) async {
    final folders = await findStartFolders(
      homeFromEnvironment(Platform.environment),
    );
    debugPrint('start folders: $folders');
    for (final kind in [StartFolder.pictures, StartFolder.downloads]) {
      expect(folders[kind], isNotNull, reason: '$kind');
      expect(Directory(folders[kind]!).existsSync(), isTrue, reason: '$kind');
    }
  });
}
