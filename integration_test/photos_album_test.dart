// Apple Photos on the Mac (macos/Runner/MainFlutterWindow.swift, spec
// §10.50): a picture made here saved into an album of the real library.
// It writes to the Photos library of whoever runs it, so it runs only
// when asked for by name, with the album to use:
//   flutter test integration_test/photos_album_test.dart -d macos \
//     --dart-define=ALBUM=uwmedia_test
// The first run shows the system's question about Photos; answer it.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/engine/media_library.dart';

const _album = String.fromEnvironment('ALBUM');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a picture into the album',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('uwmedia_photos_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      // A blue-green picture, 320 by 240.
      const w = 320;
      const h = 240;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 10;
        rgba[i + 1] = 120 + (i ~/ 4 % w) * 100 ~/ w;
        rgba[i + 2] = 180;
        rgba[i + 3] = 255;
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
      final codec = await ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      ).instantiateCodec();
      final image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(p.join(dir.path, 'uwmedia_photos_test.png'))
        ..writeAsBytesSync(png!.buffer.asUint8List());

      await const PlatformMediaLibrary()
          .saveToAlbum(file.path, _album)
          .timeout(const Duration(minutes: 2));
    },
    skip: _album.isEmpty || !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
