/// The colour correction of the live previews on the graphics card (spec
/// §6): the fragment shaders `shaders/color_correct.frag` and
/// `shaders/unsharp.frag` doing what [ColorEngine.applyFilter] does, to
/// within a level or two. The analysis of the frame stays in Dart; the
/// videos and photos written are still the engine's own.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:uwmedia_app/core/color/color_engine.dart';

const colorCorrectShaderAsset = 'shaders/color_correct.frag';
const unsharpShaderAsset = 'shaders/unsharp.frag';

class ColorShader {
  ColorShader._(this._correct, this._unsharp);

  final ui.FragmentProgram _correct;
  final ui.FragmentProgram _unsharp;

  static Future<ColorShader?>? _loaded;

  /// The shaders, loaded once; `null` where they cannot be (the previews
  /// then correct with the engine).
  static Future<ColorShader?> load() => _loaded ??= () async {
    try {
      return ColorShader._(
        await ui.FragmentProgram.fromAsset(colorCorrectShaderAsset),
        await ui.FragmentProgram.fromAsset(unsharpShaderAsset),
      );
    } on Object {
      return null;
    }
  }();

  /// [source] corrected by [filter] with [profile], and sharpened when the
  /// profile asks for it. The caller disposes of the result.
  ui.Image apply(ui.Image source, ColorProfile profile, Float32List filter) {
    // The numbers the engine works them out to, as 32-bit floats.
    final derived = Float32List(3);
    derived[0] = 1.0 - profile.darkness;
    derived[0] = filter[9] * derived[0];
    derived[1] = profile.bhFallback;
    derived[1] = derived[1] - filter[10];
    derived[2] = profile.cifval;
    final width = source.width.toDouble();
    final height = source.height.toDouble();
    final correct = _correct.fragmentShader()
      ..setFloat(0, width)
      ..setFloat(1, height);
    for (var i = 0; i < 8; i++) {
      // The colour factors, the black point and the grey world.
      correct.setFloat(2 + i, filter[i]);
    }
    correct
      ..setFloat(10, filter[8])
      ..setFloat(11, derived[0])
      ..setFloat(12, derived[1])
      ..setFloat(13, derived[2])
      ..setFloat(14, profile.vibrance)
      ..setFloat(15, profile.contrast)
      ..setFloat(16, profile.bhFallback)
      ..setImageSampler(0, source);
    final corrected = _drawn(correct, source.width, source.height);
    correct.dispose();
    if (profile.sharpness <= 0.0) {
      return corrected;
    }
    final kernel = fixedGaussianKernel(7, 1.0);
    final unsharp = _unsharp.fragmentShader()
      ..setFloat(0, width)
      ..setFloat(1, height)
      ..setFloat(2, kernel[3] / 256.0)
      ..setFloat(3, kernel[2] / 256.0)
      ..setFloat(4, kernel[1] / 256.0)
      ..setFloat(5, kernel[0] / 256.0)
      ..setFloat(6, profile.sharpness)
      ..setImageSampler(0, corrected);
    try {
      return _drawn(unsharp, source.width, source.height);
    } finally {
      unsharp.dispose();
      corrected.dispose();
    }
  }

  static ui.Image _drawn(ui.FragmentShader shader, int width, int height) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..shader = shader,
    );
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, height);
    } finally {
      picture.dispose();
    }
  }
}
