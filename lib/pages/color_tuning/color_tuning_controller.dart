/// The Color Tuning page's state (Python `backends/color_tuning_backend.py`):
/// a sample picture, the colour profile's 26 parameters on sliders, the
/// picture corrected with them, and saving them as the profile or as a new
/// one in the user's `color.yaml`. Nothing is kept between sessions but the
/// folder the dialog starts in, as in Python.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/color/color_shader.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_params.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart'
    show bundledProfileNames;
import 'package:uwmedia_app/core/config/config_store.dart';

/// The longest side of the sample the page works on.
const tuningPreviewMaxDim = 600;

/// The folder the dialog starts in, kept in the settings' fields.
const tuningImageDirField = 'color_tuning_image_dialog_dir';

const noImageText = 'No image loaded';

/// What a save under the bundled profile [name] answers (spec §10.103).
String bundledProfileText(String name) =>
    "'$name' comes with the app and is not changed: save as a new profile";

/// [rgb] corrected with [profile]: its own analysis, then the filter.
RgbImage correctedSample((ColorProfile, RgbImage) job) {
  final (profile, rgb) = job;
  final engine = ColorEngine(profile);
  return engine.applyFilter(rgb, engine.analyze(rgb).filter);
}

/// The filter of [rgb]'s own analysis with [profile].
Float32List sampleFilter((ColorProfile, RgbImage) job) {
  final (profile, rgb) = job;
  return ColorEngine(profile).analyze(rgb).filter;
}

/// The preview's shaders, unless the correction is the caller's own (a
/// test's): then the previews are corrected by that.
Future<ColorShader?> Function() previewShader(Object? correct) =>
    correct == null ? ColorShader.load : () async => null;

class ColorTuningController extends ChangeNotifier {
  ColorTuningController({
    required this.config,
    required this.home,
    required this.bundledColorYaml,
    Future<RgbImage> Function((ColorProfile, RgbImage) job)? correct,
    Future<ColorShader?> Function()? shader,
  }) : _correct = correct ?? ((job) => compute(correctedSample, job)),
       _shader = shader ?? previewShader(correct) {
    _profiles = _loadProfiles();
    _current = _profiles.keys.first;
    _defaults = _profiles['default'] ?? const {};
    // The sliders start at the profile shown, not at the code's defaults
    // (spec §10.79: the Python app shows "default" with Sharpness and
    // Darkness at 0, which is not what a run with "default" does).
    _show(_profiles[_current] ?? const {});
  }

  void _show(Map<String, Object?> profile) {
    for (final param in colorParamsByKey.values) {
      final value = profile[param.key];
      _values[param.key] = value is num ? value.toDouble() : param.defaultValue;
    }
  }

  final ConfigStore config;
  final String home;

  /// The bundled `color.yaml`'s text.
  final String? bundledColorYaml;
  final Future<RgbImage> Function((ColorProfile, RgbImage) job) _correct;

  // The shaders that draw the correction (spec §6); without them the
  // engine corrects the sample.
  final Future<ColorShader?> Function() _shader;

  late Map<String, Map<String, Object?>> _profiles;
  late String _current;
  late Map<String, Object?> _defaults;
  final Map<String, double> _values = {};
  String _newName = '';
  String _status = noImageText;
  RgbImage? _original;
  ui.Image? _originalImage;
  ui.Image? _resultImage;
  int _loadTicket = 0;
  bool _pending = false;
  bool _correcting = false;
  bool _disposed = false;

  Map<String, Map<String, Object?>> _loadProfiles() {
    final profiles = config.colorProfiles(bundledColorYaml);
    return profiles.isEmpty ? {'default': {}} : profiles;
  }

  List<String> get profileList => _profiles.keys.toList();

  /// The bundled profiles' names: never saved over (spec §10.103).
  late final Set<String> bundledProfiles = bundledProfileNames(
    bundledColorYaml,
  );

  /// Whether the profile shown is a bundled one: its sliders can be moved
  /// and saved as a new profile, not saved over it.
  bool get currentIsBundled => bundledProfiles.contains(_current);
  String get currentProfile => _current;
  String get newProfileName => _newName;
  String get statusText => _status;
  ui.Image? get originalImage => _originalImage;
  ui.Image? get resultImage => _resultImage;

  /// A parameter's value as the preview uses it.
  double valueOf(String key) => _values[key]!;

  /// Where its slider stands.
  double sliderValueOf(String key) {
    final param = colorParamsByKey[key]!;
    return onSliderGrid(_values[key]!, param.isInt).clamp(param.min, param.max);
  }

  String textOf(String key) =>
      colorValueText(_values[key]!, colorParamsByKey[key]!.isInt);

  set newProfileName(String value) {
    // By characters (code points), as Python slices.
    final runes = value.runes;
    final cut = runes.length > newProfileNameMax
        ? String.fromCharCodes(runes.take(newProfileNameMax))
        : value;
    if (cut != _newName) {
      _newName = cut;
      notifyListeners();
    }
  }

  void _setStatus(String text) {
    _status = text;
    notifyListeners();
  }

  /// A slider moved to [value].
  void setValue(String key, double value) {
    _values[key] = onSliderGrid(value, colorParamsByKey[key]!.isInt);
    notifyListeners();
    unawaited(_update());
  }

  /// What a slider of the phones' lite page shows for the values now.
  double liteValueOf(LiteSlider slider) =>
      slider.read(_values).clamp(slider.min, slider.max);

  /// A lite slider moved: the parameters it stands for set together.
  void setLite(LiteSlider slider, double value) {
    slider.write(value).forEach((key, v) {
      final param = colorParamsByKey[key]!;
      _values[key] = v.clamp(param.min, param.max);
    });
    notifyListeners();
    unawaited(_update());
  }

  /// A parameter back to the default profile's value.
  void reset(String key) {
    final param = colorParamsByKey[key]!;
    final saved = _defaults[key];
    setValue(key, saved is num ? saved.toDouble() : param.defaultValue);
  }

  /// Another profile picked: its values on the sliders.
  set currentProfile(String name) {
    if (name.isEmpty || name == _current) {
      return;
    }
    _current = name;
    _show(_loadProfiles()[name] ?? const {});
    notifyListeners();
    unawaited(_update());
  }

  ColorProfile get _profile => ColorProfile.fromMap(_values);

  // What a save writes: each slider's position, whole numbers as such.
  Map<String, Object?> get _sliderValues => {
    for (final param in colorParamsByKey.values)
      param.key: param.isInt
          ? onSliderGrid(_values[param.key]!, true).toInt()
          : onSliderGrid(_values[param.key]!, false),
  };

  String get dialogDir => config.dialogDirFor(
    tuningImageDirField,
    home: home,
    start: StartFolder.pictures,
  );

  /// The picture picked in the dialog, at most [tuningPreviewMaxDim] on its
  /// longest side. A later pick wins over one still loading.
  Future<void> loadImage(String path, {bool remember = true}) async {
    final ticket = ++_loadTicket;
    if (remember) {
      try {
        config.rememberDialogDir(tuningImageDirField, p.dirname(path));
      } on FileSystemException {
        // Only not kept.
      }
    }
    ui.Image? image;
    RgbImage original;
    try {
      final bytes = File(path).readAsBytesSync();
      final size = await ui.ImageDescriptor.encoded(
        await ui.ImmutableBuffer.fromUint8List(bytes),
      );
      final scale =
          tuningPreviewMaxDim /
          (size.width > size.height ? size.width : size.height);
      final codec = await size.instantiateCodec(
        targetWidth: (size.width * scale).truncate(),
        targetHeight: (size.height * scale).truncate(),
      );
      image = (await codec.getNextFrame()).image;
      codec.dispose();
      size.dispose();
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      final rgb = Uint8List(image.width * image.height * 3);
      for (var i = 0, o = 0; i < rgba.length; i += 4, o += 3) {
        rgb[o] = rgba[i];
        rgb[o + 1] = rgba[i + 1];
        rgb[o + 2] = rgba[i + 2];
      }
      original = RgbImage(image.width, image.height, rgb);
    } on Object {
      image?.dispose();
      if (ticket == _loadTicket && !_disposed) {
        _setStatus('Could not load: $path');
      }
      return;
    }
    if (_disposed || ticket != _loadTicket) {
      image.dispose();
      return;
    }
    _original = original;
    _originalImage?.dispose();
    _originalImage = image;
    // The old result does not go with the new picture.
    _resultImage?.dispose();
    _resultImage = null;
    _setStatus(path);
    await _update();
  }

  /// Whether the sample is being corrected again: [resultImage] is for
  /// the sliders as they were until it is done.
  bool get updating => _correcting;

  /// The sample corrected with the sliders: one correction at a time, and
  /// when the sliders moved meanwhile, one more with where they are now.
  Future<void> _update() async {
    if (_original == null) {
      return;
    }
    _pending = true;
    if (_correcting) {
      return;
    }
    _correcting = true;
    try {
      while (_pending && !_disposed) {
        _pending = false;
        final original = _original!;
        final loaded = _loadTicket;
        ui.Image image;
        try {
          final profile = _profile;
          final source = _originalImage!.clone();
          try {
            final shader = await _shader();
            image = shader == null
                ? await _imageOf(await _correct((profile, original)))
                : shader.apply(
                    source,
                    profile,
                    await compute(sampleFilter, (profile, original)),
                  );
          } finally {
            source.dispose();
          }
        } on Object {
          if (!_disposed) {
            _setStatus('Could not correct the picture');
          }
          continue;
        }
        if (_disposed || _pending || loaded != _loadTicket) {
          // Stale: the next round draws what is wanted now.
          image.dispose();
          continue;
        }
        _resultImage?.dispose();
        _resultImage = image;
        notifyListeners();
      }
    } finally {
      _correcting = false;
    }
  }

  static Future<ui.Image> _imageOf(RgbImage rgb) {
    final rgba = Uint8List(rgb.width * rgb.height * 4);
    for (var i = 0, o = 0; i < rgb.rgb.length; i += 3, o += 4) {
      rgba[o] = rgb.rgb[i];
      rgba[o + 1] = rgb.rgb[i + 1];
      rgba[o + 2] = rgb.rgb[i + 2];
      rgba[o + 3] = 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      rgb.width,
      rgb.height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  /// The sliders saved as the current profile (the user's own copy of it).
  void saveProfile() {
    if (currentIsBundled) {
      _setStatus(bundledProfileText(_current));
      return;
    }
    try {
      config.saveUserProfile(_current, _sliderValues);
      _setStatus("Saved profile '$_current'");
    } on FileSystemException catch (e) {
      _setStatus('Could not save the profile: ${e.message}');
    }
  }

  /// The sliders saved as a new profile named [newProfileName].
  void saveNewProfile() {
    final name = _newName.trim();
    if (name.isEmpty) {
      return;
    }
    if (bundledProfiles.contains(name)) {
      _setStatus(bundledProfileText(name));
      return;
    }
    try {
      config.saveUserProfile(name, _sliderValues);
    } on FileSystemException catch (e) {
      _setStatus('Could not save the profile: ${e.message}');
      return;
    }
    _newName = '';
    _profiles = _loadProfiles();
    _current = name;
    _setStatus("Saved new profile '$name'");
  }

  @override
  void dispose() {
    _disposed = true;
    _originalImage?.dispose();
    _resultImage?.dispose();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }
}
