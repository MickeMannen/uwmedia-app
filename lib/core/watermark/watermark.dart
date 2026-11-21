/// The diver's own watermarks (owner, 2026-11-14; spec §10.45): a
/// picture or a line of text put on every photo and video a run writes.
/// A watermark is drawn by the overlay renderer: [watermarkLayout] makes
/// the layout of one, a page with the picture as its skin (or the text as
/// its one element) placed on the frame, so that it takes the same share
/// of every frame whatever its size or shape. A watermark has a place for
/// landscape frames and one for portrait ones (owner, 2026-11-16; spec
/// §10.63), each one of the nine places or anywhere between them, and
/// may be for one of the two kinds of frame only (owner, 2026-11-17).
library;

/// The nine places of a watermark, as the layouts name their anchors.
const watermarkAnchors = [
  'TOP_LEFT',
  'TOP_CENTER',
  'TOP_RIGHT',
  'MIDDLE_LEFT',
  'MIDDLE_CENTER',
  'MIDDLE_RIGHT',
  'BOTTOM_LEFT',
  'BOTTOM_CENTER',
  'BOTTOM_RIGHT',
];

/// The anchors as the pages say them.
const watermarkAnchorLabels = {
  'TOP_LEFT': 'Top left',
  'TOP_CENTER': 'Top',
  'TOP_RIGHT': 'Top right',
  'MIDDLE_LEFT': 'Left',
  'MIDDLE_CENTER': 'Centre',
  'MIDDLE_RIGHT': 'Right',
  'BOTTOM_LEFT': 'Bottom left',
  'BOTTOM_CENTER': 'Bottom',
  'BOTTOM_RIGHT': 'Bottom right',
};

/// A place on a frame: where the mark lies between the frame's margins,
/// 0 to 1 each way (0 against the left or top margin, 1 against the right
/// or bottom one, 0.5 centred). The nine [watermarkAnchors] are the places
/// of 0, 0.5 and 1; whatever the frame's and the mark's size, a mark at a
/// place lies wholly inside the margins.
typedef WatermarkPlace = ({double x, double y});

/// The place the anchor [anchor] names.
WatermarkPlace placeOfAnchor(String anchor) => (
  x: anchor.endsWith('LEFT')
      ? 0.0
      : anchor.endsWith('RIGHT')
      ? 1.0
      : 0.5,
  y: anchor.startsWith('TOP')
      ? 0.0
      : anchor.startsWith('BOTTOM')
      ? 1.0
      : 0.5,
);

/// The anchor whose place [place] is; `null` for a place between them.
String? anchorOfPlace(WatermarkPlace place) {
  String? side(double v, String low, String middle, String high) => v == 0
      ? low
      : v == 0.5
      ? middle
      : v == 1
      ? high
      : null;
  final row = side(place.y, 'TOP', 'MIDDLE', 'BOTTOM');
  final column = side(place.x, 'LEFT', 'CENTER', 'RIGHT');
  return row == null || column == null ? null : '${row}_$column';
}

/// How near one of the nine places' lines (an edge or the middle, as a
/// share of the way across) a dragged mark is taken onto it.
const watermarkSnap = 0.05;

/// [place] kept on the frame, each way taken onto the edge or the middle
/// it is within [watermarkSnap] of.
WatermarkPlace snappedPlace(WatermarkPlace place) {
  double snap(double v) {
    final kept = v.isNaN ? 0.5 : v.clamp(0.0, 1.0).toDouble();
    for (final line in const [0.0, 0.5, 1.0]) {
      if ((kept - line).abs() <= watermarkSnap) {
        return line;
      }
    }
    return kept;
  }

  return (x: snap(place.x), y: snap(place.y));
}

/// How wide and high [mark] is drawn, as shares of the frame's width: a
/// picture of [pictureSize] by its size, a text by its measured box (not
/// measured: about what bold letters take).
(double, double) watermarkShare(Watermark mark, {(int, int)? pictureSize}) {
  if (pictureSize != null) {
    return (mark.size, mark.size * pictureSize.$2 / pictureSize.$1);
  }
  final box = mark.textBox ?? (0.58 * mark.text.length, 0.75);
  return (box.$1 * mark.size, box.$2 * mark.size);
}

/// Where the top left corner of a mark of [markW] by [markH] lies on a
/// frame of [frameW] by [frameH] at [place], as [watermarkLayout] puts it.
(double, double) watermarkCorner(
  WatermarkPlace place,
  double frameW,
  double frameH,
  double markW,
  double markH,
) {
  final margin = watermarkMargin * frameW;
  return (
    margin + place.x * (frameW - 2 * margin - markW),
    margin + place.y * (frameH - 2 * margin - markH),
  );
}

/// The place of a mark whose top left corner was dragged to ([x], [y]),
/// taken onto the nine's lines near them ([snappedPlace]).
WatermarkPlace watermarkPlaceAt(
  double x,
  double y,
  double frameW,
  double frameH,
  double markW,
  double markH,
) {
  final margin = watermarkMargin * frameW;
  double share(double at, double room) =>
      room <= 0 ? 0.5 : (at - margin) / room;
  return snappedPlace((
    x: share(x, frameW - 2 * margin - markW),
    y: share(y, frameH - 2 * margin - markH),
  ));
}

/// What the pages say of [place]: its anchor's name, or that it was put
/// there by hand.
String watermarkPlaceText(WatermarkPlace place) =>
    watermarkAnchorLabels[anchorOfPlace(place)] ?? 'Placed by hand';

/// The width the layouts are designed on; a frame of another width
/// scales everything by its own over this.
const _designWidth = 1920;

/// How far from the frame's edges a watermark lies, as a share of the
/// frame's width.
const watermarkMargin = 0.02;

/// The limits of a watermark's size and opacity.
const watermarkMinSize = 0.02;
const watermarkMaxSize = 1.0;
const watermarkMinOpacity = 0.1;

/// The frames a watermark is put on ([Watermark.frames]).
const watermarkFramesBoth = 'both';
const watermarkFramesLandscape = 'landscape';
const watermarkFramesPortrait = 'portrait';

class Watermark {
  /// [anchor] is the place on both kinds of frame, for a watermark that
  /// is given neither [place] nor [placePortrait].
  const Watermark({
    required this.name,
    this.picture,
    this.text = '',
    this.color = '#FFFFFF',
    this._anchor = 'BOTTOM_RIGHT',
    this._place,
    this._placePortrait,
    this.textBox,
    double? size,
    this.opacity = 0.8,
    this.frames = watermarkFramesBoth,
  }) : size = size ?? (picture == null ? 0.03 : 0.15);

  /// A watermark as the settings keep it; `null` for an entry that is
  /// none (no name, or neither a picture nor a text).
  static Watermark? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final name = json['name'];
    final picture = json['picture'];
    final text = json['text'];
    // A file name in the watermarks folder, never a path out of it.
    final hasPicture =
        picture is String &&
        picture.isNotEmpty &&
        !picture.contains('/') &&
        !picture.contains(r'\') &&
        picture != '..';
    final hasText = text is String && text.trim().isNotEmpty;
    if (name is! String || name.trim().isEmpty || !(hasPicture || hasText)) {
      return null;
    }
    final anchor = json['anchor'];
    final color = json['color'];
    final size = json['size'];
    final opacity = json['opacity'];
    // One kept before the two places has its anchor for both.
    final place = _placeFromJson(json['place']);
    final box = _pair(json['text_box']);
    final frames = json['frames'];
    return Watermark(
      frames:
          frames == watermarkFramesLandscape ||
              frames == watermarkFramesPortrait
          ? frames as String
          : watermarkFramesBoth,
      name: name,
      picture: hasPicture ? picture : null,
      text: hasPicture || !hasText ? '' : text,
      color: color is String && _hexColor.hasMatch(color) ? color : '#FFFFFF',
      anchor: watermarkAnchors.contains(anchor)
          ? anchor as String
          : 'BOTTOM_RIGHT',
      place: place,
      placePortrait: _placeFromJson(json['place_portrait']) ?? place,
      textBox: box != null && box.$1 > 0 && box.$2 > 0 ? box : null,
      size: size is num
          ? size.toDouble().clamp(watermarkMinSize, watermarkMaxSize)
          : null,
      opacity: opacity is num
          ? opacity.toDouble().clamp(watermarkMinOpacity, 1.0)
          : 0.8,
    );
  }

  static (double, double)? _pair(Object? json) =>
      json is List && json.length == 2 && json[0] is num && json[1] is num
      ? ((json[0] as num).toDouble(), (json[1] as num).toDouble())
      : null;

  static WatermarkPlace? _placeFromJson(Object? json) {
    final pair = _pair(json);
    return pair == null || pair.$1.isNaN || pair.$2.isNaN
        ? null
        : (x: pair.$1.clamp(0.0, 1.0), y: pair.$2.clamp(0.0, 1.0));
  }

  /// What the pages call it.
  final String name;

  /// The picture's file name in the watermarks folder; `null` for a text.
  final String? picture;

  /// The text of a text watermark.
  final String text;

  /// The text's colour, as `#RRGGBB`.
  final String color;

  final String _anchor;
  final WatermarkPlace? _place;
  final WatermarkPlace? _placePortrait;

  /// Where it lies on a landscape (or square) frame.
  WatermarkPlace get place => _place ?? placeOfAnchor(_anchor);

  /// Where it lies on a portrait frame.
  WatermarkPlace get placePortrait => _placePortrait ?? place;

  /// The frames it is put on: [watermarkFramesBoth], or landscape (and
  /// square) ones only, or portrait ones only, for a diver who has one
  /// mark for each.
  final String frames;

  bool get onLandscape => frames != watermarkFramesPortrait;
  bool get onPortrait => frames != watermarkFramesLandscape;

  /// Whether it is put on a frame of [frameW] by [frameH].
  bool usedOn(int frameW, int frameH) =>
      frameH > frameW ? onPortrait : onLandscape;

  /// The place on a frame of [frameW] by [frameH].
  WatermarkPlace placeOn(int frameW, int frameH) =>
      frameH > frameW ? placePortrait : place;

  /// How wide and high the text is drawn, in letter heights ([size]), as
  /// the editor measured it with the renderer's font: what lets a text lie
  /// at a place between the nine. `null` until it was measured (the text
  /// then goes to the nearest of the nine).
  final (double, double)? textBox;

  /// A picture's width, or a text's letter height, as a share of the
  /// frame's width.
  final double size;

  /// How solid a picture is drawn, 0 to 1. A text is always solid, with a
  /// dark outline so that it reads on light and dark water.
  final double opacity;

  bool get isPicture => picture != null;

  Map<String, Object?> toJson() => {
    'name': name,
    if (picture != null) 'picture': picture else 'text': text,
    if (picture == null) 'color': color,
    'place': [place.x, place.y],
    'place_portrait': [placePortrait.x, placePortrait.y],
    if (picture == null && textBox != null)
      'text_box': [textBox!.$1, textBox!.$2],
    'size': size,
    if (picture != null) 'opacity': opacity,
    if (frames != watermarkFramesBoth) 'frames': frames,
  };

  /// A changed [text] is not measured yet: its [textBox] goes unless a
  /// new one comes with it.
  Watermark copyWith({
    String? name,
    String? text,
    String? color,
    WatermarkPlace? place,
    WatermarkPlace? placePortrait,
    (double, double)? textBox,
    double? size,
    double? opacity,
    String? frames,
  }) => Watermark(
    frames: frames ?? this.frames,
    name: name ?? this.name,
    picture: picture,
    text: text ?? this.text,
    color: color ?? this.color,
    place: place ?? this.place,
    placePortrait: placePortrait ?? this.placePortrait,
    textBox:
        textBox ?? (text == null || text == this.text ? this.textBox : null),
    size: size ?? this.size,
    opacity: opacity ?? this.opacity,
  );
}

final _hexColor = RegExp(r'^#[0-9A-Fa-f]{6}$');

/// The element of a text watermark, without where it hangs on its box.
Map<String, dynamic> watermarkTextElement(Watermark mark) => {
  'id': 'watermark',
  'field': 'custom:${mark.text}',
  'font_size': mark.size * _designWidth,
  'font_weight': 'bold',
  'color': mark.color,
  'outline': true,
};

/// The layout that draws [mark] on a frame of [frameW] by [frameH] (the
/// shape decides between its two places, and where a place between the
/// nine comes to lie): for a picture, [pictureSize] is the picture's own
/// size in pixels and [skinPath] the name the layout gives its skin (the
/// run hands the bytes over itself). `null` for a picture without a size.
/// On a frame the mark is not for ([Watermark.usedOn]) the layout draws
/// nothing.
///
/// At one of the nine places the layout hangs on that anchor, as a
/// watermark always did. Between them it hangs on the top left corner,
/// moved to where the place puts a mark of its size: a picture by its own
/// shape, a text by its [Watermark.textBox] (without one it goes to the
/// nearest of the nine).
Map<String, dynamic>? watermarkLayout(
  Watermark mark, {
  (int, int)? pictureSize,
  String skinPath = 'watermark',
  int frameW = 1920,
  int frameH = 1080,
}) {
  if (mark.isPicture &&
      (pictureSize == null || pictureSize.$1 < 1 || pictureSize.$2 < 1)) {
    return null;
  }
  if (!mark.usedOn(frameW, frameH)) {
    return {
      'design_width': _designWidth,
      'hud_skin': {
        'type': 'shape',
        'width': 8.0,
        'height': 8.0,
        'corner_radius': 0,
        'color': '#000000',
        'opacity': 0.0,
        'scale': 1.0,
        'anchor': 'TOP_LEFT',
        'ref_offset_x': 0.0,
        'ref_offset_y': 0.0,
        'linked_elements': <dynamic>[],
      },
    };
  }
  final margin = watermarkMargin * _designWidth;
  var place = mark.placeOn(frameW, frameH);
  final textBox = mark.textBox;
  var anchor = anchorOfPlace(place);
  // The mark's size in design pixels, where it is known.
  final (double, double)? box = mark.isPicture
      ? (
          mark.size * _designWidth,
          mark.size * _designWidth * pictureSize!.$2 / pictureSize.$1,
        )
      : textBox == null
      ? null
      : (
          textBox.$1 * mark.size * _designWidth,
          textBox.$2 * mark.size * _designWidth,
        );
  if (anchor == null && box == null) {
    double near(double v) => (v * 2).round() / 2;
    place = (x: near(place.x), y: near(place.y));
    anchor = anchorOfPlace(place);
  }
  // A measured text lies by its box at the nine places too, so that it
  // does not shift when it is dragged off one.
  final byBox = box != null && (anchor == null || !mark.isPicture);
  final double dx;
  final double dy;
  if (byBox) {
    final designHeight = _designWidth * frameH / frameW;
    dx = margin + place.x * (_designWidth - 2 * margin - box.$1);
    dy = margin + place.y * (designHeight - 2 * margin - box.$2);
    anchor = 'TOP_LEFT';
  } else {
    // Inward from the edge the anchor names; none along a centred side.
    dx = margin * (1 - 2 * place.x);
    dy = margin * (1 - 2 * place.y);
  }
  if (mark.isPicture) {
    return {
      'design_width': _designWidth,
      'hud_skin': {
        'type': 'image',
        'path': skinPath,
        'scale': mark.size * _designWidth / pictureSize!.$1,
        'anchor': anchor,
        'ref_offset_x': dx,
        'ref_offset_y': dy,
        'opacity': mark.opacity,
        'linked_elements': <dynamic>[],
      },
    };
  }
  // A text hangs on an unseen box: its own measured one, the text in the
  // middle of it; or a small one at the anchor, the text hanging on it by
  // the side that lies towards the frame's edge, so that it never runs
  // out of the frame.
  const small = 8.0;
  final (align, relX) = byBox || place.x == 0.5
      ? ('center', 0.5)
      : place.x == 0
      ? ('left', 0.0)
      : ('right', 1.0);
  final (valign, relY) = byBox || place.y == 0.5
      ? ('middle', 0.5)
      : place.y == 0
      ? ('top', 0.0)
      : ('bottom', 1.0);
  return {
    'design_width': _designWidth,
    'hud_skin': {
      'type': 'shape',
      'width': byBox ? box.$1 : small,
      'height': byBox ? box.$2 : small,
      'corner_radius': 0,
      'color': '#000000',
      'opacity': 0.0,
      'scale': 1.0,
      'anchor': anchor,
      'ref_offset_x': dx,
      'ref_offset_y': dy,
      'linked_elements': <dynamic>[
        {
          ...watermarkTextElement(mark),
          'rel_x': relX,
          'rel_y': relY,
          'align': align,
          'valign': valign,
        },
      ],
    },
  };
}
