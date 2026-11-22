/// How much room a Color run's results take, about, worked out before
/// the run from the sizes of its source files (spec §10.96), so that the
/// page can say when the disk has not room for them.
///
/// A video is written at its source's bit rate and a photo as a JPEG
/// with its source's tables, so each comes out near its source's size;
/// a part of a video takes its share, and a comparison is a short clip.
/// The numbers lean to the high side: a warning too many is better than
/// a disk that fills.
library;

import 'dart:math' as math;

/// A source file's size and whether it is a video.
typedef SourceSize = ({int bytes, bool video});

/// A rewritten photo against its source: the corrected picture has more
/// colour in it than the blue-green original.
const photoGrowth = 1.2;

/// A rewritten video against its source (the container, the rate
/// control's overshoot).
const videoGrowth = 1.05;

/// The most a video's before-and-after clip takes (ten seconds, spec
/// §10.94), whatever the source's length.
const compareClipBytes = 150000000;

/// The most a photo's four-second wipe video takes.
const wipeVideoBytes = 60000000;

/// The bytes the results of [files] take, about.
///
/// [rewritten]: the pictures are made anew (a colour correction, an
/// overlay, a watermark); otherwise the files are copied. [compare]: a
/// before-and-after picture, with [wipe] a photo's wipe video.
/// [partFraction]: the share of a video that is written, 0 to 1 (the
/// one video of a run with a part set).
int estimatedOutputBytes(
  List<SourceSize> files, {
  required bool rewritten,
  bool compare = false,
  bool wipe = false,
  double? partFraction,
}) {
  var total = 0.0;
  for (final file in files) {
    if (file.video) {
      if (compare) {
        total += math.min(file.bytes * videoGrowth, compareClipBytes);
      } else {
        final share = (partFraction ?? 1.0).clamp(0.0, 1.0);
        final anew = rewritten || partFraction != null;
        total += file.bytes * share * (anew ? videoGrowth : 1.0);
      }
    } else if (compare && wipe) {
      total += wipeVideoBytes;
    } else {
      total += file.bytes * (rewritten ? photoGrowth : 1.0);
    }
  }
  return total.ceil();
}

/// Whether [needed] bytes do not fit into [free]; an unknown [free] is
/// taken as room enough.
bool spaceIsShort(int needed, int? free) => free != null && needed > free;

/// [bytes] for a person: "14.2 GB" from a gigabyte on, "350 MB" below
/// (never "0 MB" for something).
String spaceSizeText(int bytes) => bytes >= 1000000000
    ? '${(bytes / 1000000000).toStringAsFixed(1)} GB'
    : '${math.max(1, (bytes / 1000000).round())} MB';

/// The page's line: "About 14.2 GB needed, 114.0 GB free", or with too
/// little room "About 14.2 GB needed, only 9.0 GB free on this disk";
/// with the free space unknown only what is needed.
String spaceLine(int needed, int? free) {
  final about = 'About ${spaceSizeText(needed)} needed';
  if (free == null) {
    return about;
  }
  return spaceIsShort(needed, free)
      ? '$about, only ${spaceSizeText(free)} free on this disk'
      : '$about, ${spaceSizeText(free)} free';
}

/// Whether [error] (an exception's text, ffmpeg's last lines) says that
/// the disk is full: POSIX's ENOSPC (28) or Windows' ERROR_DISK_FULL
/// (112), by number or in the system's words.
bool saysDiskFull(String error) {
  final text = error.toLowerCase();
  return text.contains('no space left on device') ||
      text.contains('not enough space on the disk') ||
      text.contains('enospc') ||
      RegExp(r'errno = (28|112)\b').hasMatch(text);
}
