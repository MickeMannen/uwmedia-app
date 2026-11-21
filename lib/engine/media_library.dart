/// The phone's photo library (owner, 2026-11-13): photos and videos picked
/// from it, and corrected copies saved into an album of their own, the
/// originals left as they are.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// The library could not hand over what was picked; [message] says why.
class LibraryException implements Exception {
  const LibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class MediaLibrary {
  /// Photos and videos picked from the library, as local files with the
  /// library's bytes; empty when the user picked none. Without [photos]
  /// or [videos] only the other kind is offered; without [multiple] one
  /// file. Throws a [LibraryException] when a picked file could not be
  /// read (one not yet downloaded from iCloud).
  Future<List<String>> pick({
    bool photos = true,
    bool videos = true,
    bool multiple = true,
  });

  /// The file at [path] saved into the library, in the album [album]
  /// (made when there is none of that name). False when it went into the
  /// library but into no album: iOS lets an app with access to chosen
  /// photos only, or to add only, have no album.
  Future<bool> saveToAlbum(String path, String album);
}

/// How many picked files the library is handing over just now (macOS:
/// its picker has closed and the files are being copied, downloaded
/// first when they are in iCloud); 0 when none.
final photosFetching = ValueNotifier<int>(0);

/// The files being handed over ([photosFetching]) are no longer wanted:
/// the pick gives nothing.
Future<void> cancelPhotosFetch() async {
  try {
    await PlatformMediaLibrary._channel.invokeMethod<void>('cancelPick');
  } on MissingPluginException {
    // No fetch to cancel on this system.
  }
}

/// The library through the app's own channel (`MediaStore` on Android,
/// `PHPhotoLibrary` and `PHPicker` on iOS) and `image_picker`.
class PlatformMediaLibrary implements MediaLibrary {
  const PlatformMediaLibrary();

  static const _channel = MethodChannel('uwmedia/media_library');

  @override
  Future<List<String>> pick({
    bool photos = true,
    bool videos = true,
    bool multiple = true,
  }) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fetching') {
        photosFetching.value = call.arguments as int? ?? 0;
      }
    });
    try {
      // The runner's own picker where it has one (iOS): the files as the
      // library has them, under their names. `image_picker` encodes a
      // photo again there (an HEIC becomes a JPEG) and renames it.
      final picked = await _channel.invokeListMethod<String>('pick', {
        'photos': photos,
        'videos': videos,
        'multiple': multiple,
      });
      return picked ?? const [];
    } on MissingPluginException {
      // Android: its picker hands over the original files.
    } on PlatformException catch (e) {
      throw LibraryException(e.message ?? 'The library gave no file');
    } finally {
      photosFetching.value = 0;
    }
    final picker = ImagePicker();
    if (!multiple) {
      final file = photos && videos
          ? await picker.pickMedia(requestFullMetadata: true)
          : photos
          ? await picker.pickImage(
              source: ImageSource.gallery,
              requestFullMetadata: true,
            )
          : await picker.pickVideo(source: ImageSource.gallery);
      return [?file?.path];
    }
    final files = photos && videos
        ? await picker.pickMultipleMedia(requestFullMetadata: true)
        : photos
        ? await picker.pickMultiImage(requestFullMetadata: true)
        : await picker.pickMultiVideo();
    return [for (final file in files) file.path];
  }

  @override
  Future<bool> saveToAlbum(String path, String album) async =>
      await _channel.invokeMethod<bool>('saveToAlbum', {
        'path': path,
        'album': album,
      }) ??
      true;
}
