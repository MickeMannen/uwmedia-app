/// The size an overlay starts at when it is put on a frame: true to life
/// between dive computers (spec §10.100). A Descent X50i is wider than a
/// Perdix on the arm, so it is on the frame; a watch is smaller than
/// both.
///
/// The templates keep the scale they have (`hud_skin.scale`, which the
/// Python reference's drawings were made with): what is worked out here
/// is the scale an overlay *instance* gets when it is added, the same
/// number a person changes by dragging a handle.
library;

/// How wide a Perdix (81 mm) is drawn, as a share of the frame's width
/// (owner, 2026-11-24). Every other computer follows from it.
const trueSizeReferenceShare = 0.25;

/// The width of the Perdix's case, in millimetres.
const trueSizeReferenceMm = 81.0;

/// The real width, in millimetres, of what each bundled computer's
/// picture shows from its left edge to its right, by `brand/computer`
/// folder. A handset's picture is its case; a watch's also shows the
/// buttons, measured off the picture against the case's diameter. From
/// the makers' data sheets and retailers' listings (2026-11-24; the
/// sources are in spec §10.100).
///
/// Here and not in each `manifest.json`: the bundled manifests are held
/// to the Python reference's copy by `template_tree_test.dart`. A
/// computer of the user's own may give `width_mm` in its manifest.
const bundledPictureWidthsMm = <String, double>{
  'garmin/x50i': 98.3,
  'garmin/mk3i': 62,
  'shearwater/perdix_2': 81,
  'shearwater/perdix_3': 81,
  'shearwater/petrel': 83,
  'shearwater/peregrine': 77,
  'shearwater/teric': 60,
  'shearwater/tern': 54,
  'suunto/eon_core': 80,
  'suunto/eon_steel_black': 104.6,
  'suunto/nautic': 101,
};

/// The real width of a computer's picture in millimetres: its manifest's
/// `width_mm` when that is a number above zero, else the bundled table's;
/// `null` when neither says.
double? pictureWidthMm(
  String brand,
  String computer,
  Map<String, dynamic> manifest,
) {
  final own = manifest['width_mm'];
  if (own is num && own > 0) {
    return own.toDouble();
  }
  return bundledPictureWidthsMm['$brand/$computer'];
}

/// The scale an overlay instance of [layout] starts at so that its
/// picture, [skinSize] pixels as it is, is drawn [widthMm] millimetres
/// wide where a Perdix takes [trueSizeReferenceShare] of the frame's
/// width. 1 (the template's own size) when the width is not known, the
/// skin is a drawn shape and not a picture, or the picture's size is not
/// known.
double trueSizeScale({
  required double? widthMm,
  required Map<String, dynamic> layout,
  required (int, int)? skinSize,
}) {
  final hudSkin = layout['hud_skin'];
  if (widthMm == null ||
      widthMm <= 0 ||
      skinSize == null ||
      skinSize.$1 <= 0 ||
      hudSkin is! Map<String, dynamic> ||
      (hudSkin['type'] ?? 'image') == 'shape') {
    return 1;
  }
  final designWidth = layout['design_width'];
  final design = designWidth is num && designWidth > 0 ? designWidth : 1920;
  final templateScale = hudSkin['scale'];
  final own = templateScale is num && templateScale > 0 ? templateScale : 1.0;
  final wanted =
      widthMm * trueSizeReferenceShare / trueSizeReferenceMm * design;
  return wanted / (skinSize.$1 * own);
}

/// [layout] with its skin's scale set so that it is drawn at its true
/// size ([trueSizeScale]), for where an overlay has no scale of its own
/// to carry it: the Overlay Generator's working copy of a template,
/// whose overlay-only video is the skin's size. A copy; [layout] is left
/// alone, and returned as it is when there is nothing to change.
Map<String, dynamic> trueSizedLayout(
  Map<String, dynamic> layout, {
  required double? widthMm,
  required (int, int)? skinSize,
}) {
  final factor = trueSizeScale(
    widthMm: widthMm,
    layout: layout,
    skinSize: skinSize,
  );
  if (factor == 1) {
    return layout;
  }
  final hudSkin = layout['hud_skin'] as Map<String, dynamic>;
  final templateScale = hudSkin['scale'];
  final own = templateScale is num && templateScale > 0 ? templateScale : 1.0;
  return {
    ...layout,
    'hud_skin': {...hudSkin, 'scale': own * factor},
  };
}
