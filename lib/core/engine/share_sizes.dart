/// Copies of a video named by where they are going (user stories U5.6 and
/// U5.7, spec §10.49): H.264 with AAC sound so that they play wherever
/// they are sent, as the video was shot or in portrait, a landscape video
/// then either cropped to a window the diver places or shown whole
/// between bars. Not in the Python app.
library;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/naming/output_naming.dart';

/// Where a copy goes: [name] on the page, [tag] in the file's name, the
/// frame it fits in ([long] by [short], either way up) and its bit rate
/// when the frame is filled.
class ShareSize {
  const ShareSize(this.name, this.tag, this.long, this.short, this.bitrate);

  final String name;
  final String tag;
  final int long;
  final int short;

  /// Bits a second at [long] by [short].
  final int bitrate;
}

const shareWhatsApp = ShareSize('WhatsApp', 'WhatsApp', 1280, 720, 3000000);

/// WeChat takes a video of up to 25 MB in a chat (owner, 2026-11-17):
/// at this rate about a minute and a half.
const shareWeChat = ShareSize('WeChat', 'WeChat', 1280, 720, 2000000);
const shareInstagram = ShareSize(
  'Instagram / Facebook',
  'Instagram',
  1920,
  1080,
  8000000,
);

/// The shape of a copy.
enum ShareShape {
  /// As the video was shot, landscape or portrait.
  asShot,

  /// 9:16, the part of the picture inside the diver's window.
  portraitCropped,

  /// 9:16, the whole picture with bars above and below.
  portraitBars,

  /// 16:9 cut out of the picture: a landscape video out of an upright
  /// one (owner, 2026-11-19).
  landscapeCropped,

  /// 1:1 cut out of the picture.
  squareCropped;

  /// The shape of the window cut out, width over height; `null` when
  /// none of another shape than the picture's is.
  double? get aspect => switch (this) {
    asShot || portraitBars => null,
    portraitCropped => portraitAspect,
    landscapeCropped => landscapeAspect,
    squareCropped => 1,
  };

  /// What a copy's name says of it; `null` as shot.
  String? get word => switch (this) {
    asShot => null,
    portraitCropped || portraitBars => 'portrait',
    landscapeCropped => 'landscape',
    squareCropped => 'square',
  };
}

/// One copy of a run: for [size], in [shape], the crop window [cropAt]
/// along its way (0 the left or top end, 1 the right or bottom one).
class ShareCopy {
  const ShareCopy(
    this.size,
    this.shape, {
    this.cropAt = 0.5,
    this.cropAtY,
    this.cropSize = 1,
  });

  final ShareSize size;
  final ShareShape shape;

  /// The crop window's place and size, as [portraitCrop] takes them.
  final double cropAt;
  final double? cropAtY;
  final double cropSize;

  /// What the page and the status call it.
  String get label =>
      shape.word == null ? size.name : '${size.name}, ${shape.word}';

  /// The copy's file name: 'Dive 4K.MP4' gives 'Dive WhatsApp.mp4',
  /// 'Dive Instagram portrait.mp4' and 'Dive Instagram square.mp4'.
  /// Always an MP4, whatever the source is.
  String filename(String source) => p.setExtension(
    convertOutputFilename(
      source,
      shape.word == null ? size.tag : '${size.tag} ${shape.word}',
    ),
    '.mp4',
  );
}

/// The picture of a copy: the part of the source kept ([crop], in the
/// source's pixels; `null` for all of it), the size it is scaled to fit
/// in ([width] by [height], padded with black when the shapes differ) and
/// the bit rate.
typedef ShareFrame = ({
  ({int x, int y, int width, int height})? crop,
  int width,
  int height,
  int bitrate,
});

/// The aspect of a portrait copy.
const portraitAspect = 9 / 16;

/// The aspect of a landscape window cut out of a picture.
const landscapeAspect = 16 / 9;

int _even(double value) {
  final n = value.round();
  return n.isOdd ? n - 1 : n;
}

/// The smallest part a portrait copy keeps: its window's share of the
/// largest 9:16 window the picture holds.
const minCropSize = 0.3;

/// The window kept of a [sourceW] by [sourceH] picture: [size] of the
/// largest window of [aspect] (width over height; the picture's own when
/// `null`) the picture holds (1 is that window, the least
/// [minCropSize]), [at] of the way from left to right and [atY] of the way
/// from top to bottom. `null` when the whole picture is kept.
({int x, int y, int width, int height})? cropWindow(
  int sourceW,
  int sourceH, {
  double? aspect,
  double at = 0.5,
  double atY = 0.5,
  double size = 1,
}) {
  final own = sourceW / sourceH;
  final shape = aspect ?? own;
  final share = size.isNaN ? 1.0 : size.clamp(minCropSize, 1.0);
  if ((own - shape).abs() < 0.005 && share >= 1) {
    return null;
  }
  // The largest window: the full height of a wider picture, the full
  // width of a narrower one.
  final (maxW, maxH) = aspect == null
      ? (sourceW, sourceH)
      : own > shape
      ? (_even(sourceH * shape), sourceH)
      : (sourceW, _even(sourceW / shape));
  var w = maxW;
  var h = maxH;
  if (share < 1) {
    w = _atLeast2(_even(maxW * share));
    h = _atLeast2(_even(w / shape));
    if (h > maxH) {
      h = maxH;
    }
  }
  return (
    x: ((sourceW - w) * at.clamp(0.0, 1.0)).round(),
    y: ((sourceH - h) * atY.clamp(0.0, 1.0)).round(),
    width: w,
    height: h,
  );
}

/// The crop window of a portrait copy on a [sourceW] by [sourceH]
/// picture: [cropWindow] for 9:16. Without [atY] the window has one way,
/// as before it could be made smaller: [at] is sideways on a picture
/// wider than 9:16 and up and down on a narrower one, the other way
/// centred. `null` when the whole picture is kept (it is 9:16 already and
/// [size] is 1).
({int x, int y, int width, int height})? portraitCrop(
  int sourceW,
  int sourceH, {
  double at = 0.5,
  double? atY,
  double size = 1,
}) {
  final wide = sourceW / sourceH > portraitAspect;
  return cropWindow(
    sourceW,
    sourceH,
    aspect: portraitAspect,
    at: atY != null || wide ? at : 0.5,
    atY: atY ?? (wide ? 0.5 : at),
    size: size,
  );
}

/// The window [shape] keeps of a [sourceW] by [sourceH] picture, placed
/// and sized as [cropWindow] takes it: the picture's own shape made
/// smaller (zoomed in), or 9:16, 16:9 or 1:1. `null` when all of it is
/// kept (the bars keep all of it always).
({int x, int y, int width, int height})? shapeCrop(
  ShareShape shape,
  int sourceW,
  int sourceH, {
  double at = 0.5,
  double atY = 0.5,
  double size = 1,
}) => switch (shape) {
  ShareShape.asShot => cropWindow(
    sourceW,
    sourceH,
    at: at,
    atY: atY,
    size: size,
  ),
  ShareShape.portraitCropped => portraitCrop(
    sourceW,
    sourceH,
    at: at,
    atY: atY,
    size: size,
  ),
  ShareShape.portraitBars => null,
  ShareShape.landscapeCropped || ShareShape.squareCropped => cropWindow(
    sourceW,
    sourceH,
    aspect: shape.aspect,
    at: at,
    atY: atY,
    size: size,
  ),
};

/// The picture [copy] makes of a [sourceW] by [sourceH] video. Nothing is
/// made larger than the source has it; a smaller frame gets its share of
/// the bit rate (at least a quarter).
ShareFrame shareFrame(ShareCopy copy, int sourceW, int sourceH) {
  final size = copy.size;
  int rate(int width, int height) {
    final share = (width * height) / (size.long * size.short);
    return (size.bitrate * share.clamp(0.25, 1.0) / 100000).round() * 100000;
  }

  switch (copy.shape) {
    case ShareShape.asShot:
      // Zoomed in (spec §10.75): the window, of the picture's own shape.
      final crop = cropWindow(
        sourceW,
        sourceH,
        at: copy.cropAt,
        atY: copy.cropAtY ?? 0.5,
        size: copy.cropSize,
      );
      final cw = crop?.width ?? sourceW;
      final ch = crop?.height ?? sourceH;
      final (boxW, boxH) = sourceW >= sourceH
          ? (size.long, size.short)
          : (size.short, size.long);
      final scale = [1.0, boxW / cw, boxH / ch].reduce(_min);
      final w = _atLeast2(_even(cw * scale));
      final h = _atLeast2(_even(ch * scale));
      return (crop: crop, width: w, height: h, bitrate: rate(w, h));
    case ShareShape.portraitCropped:
    case ShareShape.landscapeCropped:
    case ShareShape.squareCropped:
      final crop = copy.shape == ShareShape.portraitCropped
          ? portraitCrop(
              sourceW,
              sourceH,
              at: copy.cropAt,
              atY: copy.cropAtY,
              size: copy.cropSize,
            )
          : cropWindow(
              sourceW,
              sourceH,
              aspect: copy.shape.aspect,
              at: copy.cropAt,
              atY: copy.cropAtY ?? 0.5,
              size: copy.cropSize,
            );
      final cw = crop?.width ?? sourceW;
      final ch = crop?.height ?? sourceH;
      // The size's frame in the window's shape; a smaller window is
      // written as it is.
      final (boxW, boxH) = _shapedFrame(copy.shape, size.long, size.short);
      final scale = [1.0, boxW / cw, boxH / ch].reduce(_min);
      final w = scale < 1 ? boxW : _atLeast2(_even(cw.toDouble()));
      final h = scale < 1 ? boxH : _atLeast2(_even(ch.toDouble()));
      return (crop: crop, width: w, height: h, bitrate: rate(w, h));
    case ShareShape.portraitBars:
      // The frame the picture fills sideways or upright without growing.
      final fit = [size.short / sourceW, size.long / sourceH].reduce(_min);
      final shrink = fit > 1 ? fit : 1.0;
      final w = _atLeast2(_even(size.short / shrink));
      final h = _atLeast2(_even(w / portraitAspect));
      return (crop: null, width: w, height: h, bitrate: rate(w, h));
  }
}

/// The part of the picture a run keeps whatever size it writes (spec
/// §10.75): its [shape], and the window's place and size as
/// [cropWindow] takes them.
class PictureCut {
  const PictureCut({
    this.shape = ShareShape.asShot,
    this.at = 0.5,
    this.atY = 0.5,
    this.size = 1,
  });

  final ShareShape shape;
  final double at;
  final double atY;
  final double size;

  /// Whether the picture is left as it is.
  bool get whole => shape == ShareShape.asShot && size >= 1;

  /// Whether a window may be cut out of the picture (the bars cut
  /// nothing).
  bool get cuts => shape != ShareShape.portraitBars && !whole;

  ({int x, int y, int width, int height})? cropOf(int sourceW, int sourceH) =>
      shapeCrop(shape, sourceW, sourceH, at: at, atY: atY, size: size);
}

/// The bits a second a picture of [width] by [height] is given when no
/// size names a rate: the 1080p preset's, by the number of pixels.
int areaBitrate(int width, int height) {
  final (_, w, h, rate) = convertResolutions.first;
  final share = (width * height) / (w * h);
  return (presetBitrate(rate) * share / 100000).round().clamp(5, 1000) * 100000;
}

/// The size a run writes its videos in when it is not the source's own
/// (the Color page's "Output size", user story U5.4): one of the Resize
/// page's resolutions ([resolution], HEVC as there), a copy for sharing
/// ([share], H.264), or the videos' own size with a part of the picture
/// cut out ([OutputSize.original]). A resolution and the videos' own
/// size take the part kept as [cut]; a copy for sharing has it in itself.
class OutputSize {
  const OutputSize.resolution(
    String this.resolution, {
    this.always = false,
    this.cut = const PictureCut(),
  }) : share = null;
  const OutputSize.share(ShareCopy this.share)
    : resolution = null,
      always = true,
      cut = const PictureCut();

  /// The videos' own size, [cut] kept of the picture.
  const OutputSize.original(this.cut)
    : resolution = null,
      share = null,
      always = false;

  /// Whether a video that does not reach [resolution] is written in it
  /// all the same (the Resize page, where the size was asked for by
  /// name), not left at its own size.
  final bool always;

  /// A name of [convertResolutions].
  final String? resolution;
  final ShareCopy? share;
  final PictureCut cut;

  /// H.264 with AAC sound in an MP4, not HEVC with the sound as it is.
  bool get h264 => share != null;

  /// The part of the picture kept, whichever way the size carries it
  /// (a photo keeps its size and takes only this).
  PictureCut get pictureCut {
    final copy = share;
    return copy == null
        ? cut
        : PictureCut(
            shape: copy.shape,
            at: copy.cropAt,
            atY: copy.cropAtY ?? 0.5,
            size: copy.cropSize,
          );
  }

  /// Whether a window may be cut out of the picture (the frame the
  /// overlays lie on is then the window, not the source).
  bool get cropped => share != null
      ? share!.shape.aspect != null ||
            (share!.shape == ShareShape.asShot && share!.cropSize < 1)
      : cut.shape.aspect != null ||
            (cut.shape == ShareShape.asShot && cut.size < 1);

  String get label => share?.label ?? resolution ?? 'As the original';

  /// The picture of a [sourceW] by [sourceH] video; `null` when the
  /// video is left as it is (a resolution it does not reach, nothing cut
  /// out). [sourceBitrate] is the video's own, for a part of the picture
  /// at the videos' own size.
  ShareFrame? frameFor(int sourceW, int sourceH, {int? sourceBitrate}) {
    final copy = share;
    if (copy != null) {
      return shareFrame(copy, sourceW, sourceH);
    }
    (int, int, int)? box;
    for (final (name, w, h, bitrate) in convertResolutions) {
      if (name == resolution) {
        box = (w, h, presetBitrate(bitrate));
      }
    }
    if (resolution != null && box == null) {
      return null;
    }
    if (cut.whole) {
      // As the Resize page writes it: the resolution's own frame.
      return box == null || (!always && sourceH <= box.$2 && sourceW <= box.$1)
          ? null
          : (crop: null, width: box.$1, height: box.$2, bitrate: box.$3);
    }
    final crop = cut.cropOf(sourceW, sourceH);
    final bars = cut.shape == ShareShape.portraitBars;
    if (crop == null && !bars && box == null) {
      return null;
    }
    // The shape written: the window's, or 9:16 around the whole picture.
    final cw = crop?.width ?? sourceW;
    final ch = crop?.height ?? sourceH;
    final (shapeW, shapeH) = bars && portraitDiffers(sourceW, sourceH)
        ? cw / ch > portraitAspect
              ? (cw, _even(cw / portraitAspect))
              : (_even(ch * portraitAspect), ch)
        : (cw, ch);
    // The resolution's frame (for the bars at the videos' own size, the
    // video's) turned the way the shape is; nothing is made larger.
    var scale = 1.0;
    final (int, int)? frame = box != null
        ? (box.$1, box.$2)
        : bars
        ? (
            sourceW > sourceH ? sourceW : sourceH,
            sourceW > sourceH ? sourceH : sourceW,
          )
        : null;
    if (frame != null) {
      final (long, short) = frame;
      final (boxW, boxH) = shapeW >= shapeH ? (long, short) : (short, long);
      scale = [1.0, boxW / shapeW, boxH / shapeH].reduce(_min);
    }
    var w = _atLeast2(_even(shapeW * scale));
    var h = _atLeast2(_even(shapeH * scale));
    if (frame != null && scale < 1 && cut.shape != ShareShape.asShot) {
      // 9:16 (16:9, 1:1) made smaller is the frame itself, not a pixel
      // off it.
      (w, h) = _shapedFrame(cut.shape, frame.$1, frame.$2);
    }
    final int rate;
    if (box != null) {
      final share = (w * h) / (box.$1 * box.$2);
      rate = (box.$3 * share.clamp(0.25, 1.0) / 100000).round() * 100000;
    } else if (sourceBitrate != null) {
      final share = (w * h) / (sourceW * sourceH);
      rate = (sourceBitrate * share.clamp(0.25, 1.0)).round();
    } else {
      rate = areaBitrate(w, h);
    }
    return (crop: crop, width: w, height: h, bitrate: rate);
  }
}

double _min(double a, double b) => a < b ? a : b;

// A [long] by [short] frame in [shape]: upright, lying, or square on its
// short side.
(int, int) _shapedFrame(ShareShape shape, int long, int short) =>
    switch (shape) {
      ShareShape.landscapeCropped => (long, short),
      ShareShape.squareCropped => (short, short),
      _ => (short, long),
    };

int _atLeast2(int value) => value < 2 ? 2 : value;

/// Whether a portrait copy of a [sourceW] by [sourceH] video differs from
/// the video as shot (one that is 9:16 already needs none).
bool portraitDiffers(int sourceW, int sourceH) =>
    (sourceW / sourceH - portraitAspect).abs() >= 0.005;
