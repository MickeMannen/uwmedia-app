// The copies for sharing (lib/core/engine/share_sizes.dart, spec §10.49):
// the picture each makes of a source, where the crop window lies, the
// bit rate, the file names, and the ffmpeg command built from them.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

void main() {
  const whatsApp = ShareCopy(shareWhatsApp, ShareShape.asShot);

  test('as shot: inside 1280 by 720 either way up, never larger', () {
    expect(shareFrame(whatsApp, 3840, 2160), (
      crop: null,
      width: 1280,
      height: 720,
      bitrate: 3000000,
    ));
    // A portrait phone video stays portrait.
    final upright = shareFrame(whatsApp, 1080, 1920);
    expect((upright.width, upright.height), (720, 1280));
    // A small source is not blown up, and gets less of the bit rate.
    final small = shareFrame(whatsApp, 640, 360);
    expect((small.width, small.height), (640, 360));
    expect(small.bitrate, 800000);
    // A 4:3 source: 960 by 720.
    final photoShape = shareFrame(whatsApp, 2704, 2028);
    expect((photoShape.width, photoShape.height), (960, 720));
  });

  test('portrait, cropped: a 9:16 window of the full height', () {
    const middle = ShareCopy(shareInstagram, ShareShape.portraitCropped);
    final frame = shareFrame(middle, 3840, 2160);
    // 2160 * 9 / 16 = 1215, even: 1214; centred in 3840.
    expect(frame.crop, (x: 1313, y: 0, width: 1214, height: 2160));
    expect((frame.width, frame.height), (1080, 1920));
    expect(frame.bitrate, 8000000);

    const left = ShareCopy(
      shareInstagram,
      ShareShape.portraitCropped,
      cropAt: 0,
    );
    expect(shareFrame(left, 3840, 2160).crop!.x, 0);
    const right = ShareCopy(
      shareInstagram,
      ShareShape.portraitCropped,
      cropAt: 1,
    );
    expect(shareFrame(right, 3840, 2160).crop!.x, 3840 - 1214);

    // A 1080p source has only 608 by 1080 to give: not made larger.
    final hd = shareFrame(middle, 1920, 1080);
    expect(hd.crop, (x: 656, y: 0, width: 608, height: 1080));
    expect((hd.width, hd.height), (608, 1080));
    expect(hd.bitrate, 2500000);
  });

  test('portrait of a source that is portrait already', () {
    const cropped = ShareCopy(shareInstagram, ShareShape.portraitCropped);
    expect(portraitDiffers(1080, 1920), isFalse);
    expect(portraitCrop(1080, 1920), isNull);
    final frame = shareFrame(cropped, 2160, 3840);
    expect(frame.crop, isNull);
    expect((frame.width, frame.height), (1080, 1920));
    // Taller than 9:16: the window moves up and down.
    expect(portraitCrop(1000, 2000, at: 1), (
      x: 0,
      y: 2000 - 1778,
      width: 1000,
      height: 1778,
    ));
  });

  test('a smaller window, placed both ways', () {
    // Half the largest window of a 4K frame (1214 x 2160), at the middle.
    expect(portraitCrop(3840, 2160, atY: 0.5, size: 0.5), (
      x: (3840 - 606) ~/ 2,
      y: (2160 - 1076) ~/ 2,
      width: 606,
      height: 1076,
    ));
    // In the bottom right corner; at the top left.
    final corner = portraitCrop(3840, 2160, at: 1, atY: 1, size: 0.5)!;
    expect((corner.x + corner.width, corner.y + corner.height), (3840, 2160));
    final first = portraitCrop(3840, 2160, at: 0, atY: 0, size: 0.5)!;
    expect((first.x, first.y), (0, 0));
    // Never smaller than the least, never larger than the largest.
    expect(portraitCrop(3840, 2160, size: 0.01)!.height, 646);
    expect(portraitCrop(3840, 2160, size: 5)!.height, 2160);
    // A 9:16 picture is cropped too once the window is smaller.
    expect(portraitCrop(1080, 1920, atY: 0, size: 0.5), (
      x: 270,
      y: 0,
      width: 540,
      height: 960,
    ));
    // The copy of the smaller part: its pixels, not made larger.
    const copy = ShareCopy(
      shareInstagram,
      ShareShape.portraitCropped,
      cropAtY: 0.5,
      cropSize: 0.5,
    );
    final frame = shareFrame(copy, 3840, 2160);
    expect(frame.crop!.width, 606);
    expect((frame.width, frame.height), (606, 1076));
  });

  test('portrait with bars: the whole picture in a 9:16 frame', () {
    const bars = ShareCopy(shareInstagram, ShareShape.portraitBars);
    final frame = shareFrame(bars, 3840, 2160);
    expect(frame.crop, isNull);
    expect((frame.width, frame.height), (1080, 1920));
    // A source narrower than the frame is not made larger: the frame is
    // as wide as it is.
    final small = shareFrame(bars, 854, 480);
    expect((small.width, small.height), (854, 1518));
    expect(
      shareFilter(frame, 3840, 2160),
      'scale=1080:1920:force_original_aspect_ratio=decrease,'
      'pad=1080:1920:(ow-iw)/2:(oh-ih)/2,setsar=1',
    );
  });

  test('the names: the place, portrait said, always an MP4', () {
    expect(whatsApp.filename('/in/Dive 4K.MOV'), 'Dive WhatsApp.mp4');
    expect(whatsApp.label, 'WhatsApp');
    const story = ShareCopy(shareInstagram, ShareShape.portraitBars);
    expect(story.filename('GX010042.MP4'), 'GX010042 Instagram portrait.mp4');
    expect(story.label, 'Instagram / Facebook, portrait');
  });

  test('the command: crop, scale, H.264, AAC, the date', () {
    const copy = ShareCopy(
      shareInstagram,
      ShareShape.portraitCropped,
      cropAt: 0.25,
    );
    final frame = shareFrame(copy, 3840, 2160);
    final run = shareVideoArgs(
      input: 'in.mp4',
      output: 'out.mp4',
      creationDate: naive(2026, 3, 14, 11, 30),
      duration: 12.6,
      encoder: h264EncoderFor(encoderVideoToolbox),
      frame: frame,
      sourceWidth: 3840,
      sourceHeight: 2160,
      tzOffsetMins: 120,
    );
    expect(run.duration, 12);
    final args = run.args;
    expect(
      args[args.indexOf('-filter_complex') + 1],
      'crop=1214:2160:657:0,scale=1080:1920,setsar=1',
    );
    expect(args[args.indexOf('-vcodec') + 1], 'h264_videotoolbox');
    expect(args[args.indexOf('-b:v') + 1], '8000000');
    expect(args[args.indexOf('-acodec') + 1], 'aac');
    expect(args, isNot(contains('hvc1')));
    expect(args, contains('creation_time=2026-03-14T11:30:00+0200'));
    expect(args.last, 'out.mp4');
  });

  test('an output size: a resolution only downwards, a copy as it is', () {
    const hd = OutputSize.resolution('720p');
    expect(hd.h264, isFalse);
    expect(hd.cropped, isFalse);
    expect(hd.frameFor(3840, 2160), (
      crop: null,
      width: 1280,
      height: 720,
      bitrate: 12000000,
    ));
    expect(hd.frameFor(1280, 720), isNull);
    expect(hd.frameFor(640, 360), isNull);
    const story = OutputSize.share(
      ShareCopy(shareInstagram, ShareShape.portraitCropped),
    );
    expect(story.h264, isTrue);
    expect(story.cropped, isTrue);
    expect(story.frameFor(3840, 2160)!.crop!.width, 1214);
    expect(story.label, 'Instagram / Facebook, portrait');
  });

  test('the run\'s filters: the crop first, the layers, then the scale', () {
    final (graph, label) = overlayFilterComplex(
      "lut3d=file='a.cube'",
      [(10, 20)],
      before: 'crop=1214:2160:0:0',
      after: 'scale=1080:1920,setsar=1',
    );
    expect(
      graph,
      "[0:v]crop=1214:2160:0:0,lut3d=file='a.cube'[v0];"
      '[1:v]format=rgba[h1];'
      '[v0][h1]overlay=x=10:y=20:eof_action=repeat[v1];'
      '[v1]scale=1080:1920,setsar=1[vout]',
    );
    expect(label, '[vout]');
    // Without a size, as before.
    expect(overlayFilterComplex(null, const []), ('[0:v]null[v0]', '[v0]'));
    // No layers and no colour, only a size.
    expect(
      overlayFilterComplex(null, const [], after: 'scale=640:360,setsar=1'),
      ('[0:v]null[v0];[v0]scale=640:360,setsar=1[vout]', '[vout]'),
    );

    final args = colorOutputArgs(
      output: 'o.mp4',
      creationDate: naive(2026, 3, 14, 11, 30),
      encoder: 'libx264',
      tenBit: true,
      sourceBitrate: 8000000,
      h264: true,
    );
    expect(args, isNot(contains('hvc1')));
    expect(args, isNot(contains('-tag:v')));
    expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p');
    expect(args[args.indexOf('-acodec') + 1], 'aac');
  });

  test('the H.264 encoder of the same hardware', () {
    expect(h264EncoderFor(encoderSoftware), 'libx264');
    expect(h264EncoderFor(encoderNvenc), 'h264_nvenc');
    expect(h264EncoderFor(encoderAmf), 'h264_amf');
    expect(h264EncoderFor(encoderQsv), 'h264_qsv');
  });

  test('a window of the picture\'s own shape, and the cut of a run (spec '
      '§10.75)', () {
    // The whole picture is no window.
    expect(cropWindow(3840, 2160), isNull);
    expect(cropWindow(3840, 2160, size: 0.5, at: 1, atY: 0), (
      x: 1920,
      y: 0,
      width: 1920,
      height: 1080,
    ));
    expect(cropWindow(1080, 1920, size: 0.5)!.height, 960);
    // Never smaller than the least.
    expect(cropWindow(3840, 2160, size: 0.01)!.width, 1152);

    // A copy for sharing, zoomed in: the window scaled into its frame.
    const zoomed = ShareCopy(shareWhatsApp, ShareShape.asShot, cropSize: 0.5);
    final frame = shareFrame(zoomed, 3840, 2160);
    expect((frame.crop!.width, frame.width, frame.height), (1920, 1280, 720));
    expect(const OutputSize.share(zoomed).cropped, isTrue);

    // Nothing cut out, the videos' own size: nothing to do.
    expect(
      const OutputSize.original(PictureCut()).frameFor(3840, 2160),
      isNull,
    );
    // The videos' own size, a part of the picture: the window as it is,
    // with its share of the video's bit rate (else by its pixels).
    const half = OutputSize.original(PictureCut(size: 0.5));
    expect(half.h264, isFalse);
    expect(half.cropped, isTrue);
    expect(half.frameFor(3840, 2160, sourceBitrate: 100000000), (
      crop: (x: 960, y: 540, width: 1920, height: 1080),
      width: 1920,
      height: 1080,
      bitrate: 25000000,
    ));
    expect(half.frameFor(3840, 2160)!.bitrate, 24000000);
    // Portrait cut out at the videos' own size: 9:16 of the full height.
    const upright = OutputSize.original(
      PictureCut(shape: ShareShape.portraitCropped),
    );
    final story = upright.frameFor(3840, 2160)!;
    expect((story.crop!.width, story.width, story.height), (1214, 1214, 2160));
    // ... and between bars: the video's own frame turned, nothing larger.
    const bars = OutputSize.original(
      PictureCut(shape: ShareShape.portraitBars),
    );
    final barred = bars.frameFor(3840, 2160)!;
    expect((barred.crop, barred.width, barred.height), (null, 2160, 3840));

    // A resolution with a cut: its frame turned the way the window is.
    const hd = OutputSize.resolution(
      '720p',
      cut: PictureCut(shape: ShareShape.portraitCropped),
    );
    final small = hd.frameFor(3840, 2160)!;
    expect((small.width, small.height), (720, 1280));
    expect(small.bitrate, 12000000);
    // A window smaller than the resolution is not made larger.
    const tiny = OutputSize.resolution('1080p', cut: PictureCut(size: 0.3));
    final kept = tiny.frameFor(1920, 1080)!;
    expect((kept.width, kept.height), (576, 324));
    // Without a cut a resolution is as before.
    expect(const OutputSize.resolution('720p').frameFor(1280, 720), isNull);
  });

  test('a landscape or a square window out of a picture', () {
    // 16:9 out of an upright video: its full width.
    expect(shapeCrop(ShareShape.landscapeCropped, 1080, 1920, atY: 0), (
      x: 0,
      y: 0,
      width: 1080,
      height: 608,
    ));
    // ... and nothing to cut out of one that is 16:9 already.
    expect(shapeCrop(ShareShape.landscapeCropped, 3840, 2160), isNull);
    expect(shapeCrop(ShareShape.squareCropped, 3840, 2160), (
      x: 840,
      y: 0,
      width: 2160,
      height: 2160,
    ));

    // A copy for sharing: the size's frame lying, or square on its short
    // side; a window smaller than that as it is.
    const lying = ShareCopy(shareInstagram, ShareShape.landscapeCropped);
    final wide = shareFrame(lying, 2160, 3840);
    expect((wide.crop!.height, wide.width, wide.height), (1214, 1920, 1080));
    expect(lying.label, 'Instagram / Facebook, landscape');
    expect(lying.filename('Dive 4K.MOV'), 'Dive Instagram landscape.mp4');
    const square = ShareCopy(shareWhatsApp, ShareShape.squareCropped);
    final box = shareFrame(square, 3840, 2160);
    expect((box.crop!.width, box.width, box.height), (2160, 720, 720));
    expect(square.filename('Dive 4K.MOV'), 'Dive WhatsApp square.mp4');
    final little = shareFrame(square, 640, 480);
    expect((little.width, little.height), (480, 480));
    expect(const OutputSize.share(square).cropped, isTrue);

    // The videos' own size and a resolution.
    const own = OutputSize.original(
      PictureCut(shape: ShareShape.squareCropped),
    );
    final whole = own.frameFor(3840, 2160)!;
    expect((whole.crop!.x, whole.width, whole.height), (840, 2160, 2160));
    const hd = OutputSize.resolution(
      '1080p',
      cut: PictureCut(shape: ShareShape.squareCropped),
    );
    final small = hd.frameFor(3840, 2160)!;
    expect((small.width, small.height), (1080, 1080));
    const lyingHd = OutputSize.resolution(
      '1080p',
      cut: PictureCut(shape: ShareShape.landscapeCropped),
    );
    final turned = lyingHd.frameFor(2160, 3840)!;
    expect(
      (turned.crop!.width, turned.width, turned.height),
      (2160, 1920, 1080),
    );
  });
}
