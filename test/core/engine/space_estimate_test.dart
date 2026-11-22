// The room a Color run's results take, about (spec §10.96).
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/engine/space_estimate.dart';

void main() {
  const photo = (bytes: 20000000, video: false);
  const video = (bytes: 4000000000, video: true);

  test('rewritten files come out a little larger than their sources', () {
    expect(estimatedOutputBytes([photo], rewritten: true), 24000000);
    expect(estimatedOutputBytes([video], rewritten: true), 4200000000);
    expect(
      estimatedOutputBytes([photo, video, photo], rewritten: true),
      24000000 * 2 + 4200000000,
    );
    expect(estimatedOutputBytes(const [], rewritten: true), 0);
  });

  test('copied files take their own size', () {
    expect(estimatedOutputBytes([photo, video], rewritten: false), 4020000000);
  });

  test('a part of a video takes its share, written anew', () {
    expect(
      estimatedOutputBytes([video], rewritten: false, partFraction: 0.25),
      1050000000,
    );
    expect(
      estimatedOutputBytes([video], rewritten: true, partFraction: 3),
      4200000000,
    );
  });

  test('a comparison: a short clip of a video, a photo as it is or a wipe', () {
    expect(
      estimatedOutputBytes([video], rewritten: true, compare: true),
      compareClipBytes,
    );
    // A video shorter than the clip's most.
    expect(
      estimatedOutputBytes(
        [(bytes: 10000000, video: true)],
        rewritten: true,
        compare: true,
      ),
      10500000,
    );
    expect(
      estimatedOutputBytes([photo], rewritten: true, compare: true),
      24000000,
    );
    expect(
      estimatedOutputBytes([photo], rewritten: true, compare: true, wipe: true),
      wipeVideoBytes,
    );
  });

  test('the line and whether the room is short', () {
    expect(spaceSizeText(14200000000), '14.2 GB');
    expect(spaceSizeText(350400000), '350 MB');
    expect(spaceSizeText(1), '1 MB');
    expect(spaceIsShort(10, null), isFalse);
    expect(spaceIsShort(10, 10), isFalse);
    expect(spaceIsShort(11, 10), isTrue);
    expect(spaceLine(14200000000, null), 'About 14.2 GB needed');
    expect(
      spaceLine(14200000000, 114000000000),
      'About 14.2 GB needed, 114.0 GB free',
    );
    expect(
      spaceLine(14200000000, 9000000000),
      'About 14.2 GB needed, only 9.0 GB free on this disk',
    );
  });

  test('an error that says the disk is full', () {
    expect(
      saysDiskFull(
        "FileSystemException: writeFrom failed, path = '/out/a.jpg' "
        '(OS Error: No space left on device, errno = 28)',
      ),
      isTrue,
    );
    expect(
      saysDiskFull('av_interleaved_write_frame(): No space left on device'),
      isTrue,
    );
    expect(
      saysDiskFull(
        'OS Error: There is not enough space on the disk.\r\n, errno = 112',
      ),
      isTrue,
    );
    expect(saysDiskFull('OS Error: Permission denied, errno = 13'), isFalse);
    expect(saysDiskFull('errno = 280'), isFalse);
  });
}
