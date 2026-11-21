// The types the Android picker offers (lib/engine/file_picks.dart, spec
// §10.92): the groups' MIME types, or every file when a group has none,
// as the dive logs, whose types Android does not know.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/engine/file_picks.dart';

void main() {
  test('the Android picker offers the MIME types of the groups', () {
    expect(
      pickMimeTypes(const [
        XTypeGroup(
          label: 'Photos and videos',
          mimeTypes: ['image/*', 'video/*'],
        ),
      ]),
      ['image/*', 'video/*'],
    );
    // Each type once, from every group.
    expect(
      pickMimeTypes(const [
        XTypeGroup(label: 'Pictures', mimeTypes: ['image/png', 'video/*']),
        XTypeGroup(label: 'Videos', mimeTypes: ['video/*']),
      ]),
      ['image/png', 'video/*'],
    );
  });

  test('every file when a group has no MIME types, or there is no group', () {
    expect(
      pickMimeTypes(const [
        XTypeGroup(label: 'Dive logs', extensions: ['fit', 'uddf']),
      ]),
      isEmpty,
    );
    expect(
      pickMimeTypes(const [
        XTypeGroup(label: 'Videos', mimeTypes: ['video/*']),
        XTypeGroup(label: 'Dive logs', extensions: ['fit']),
      ]),
      isEmpty,
    );
    expect(pickMimeTypes(const []), isEmpty);
  });
}
