/// The Overlay Designer's document (Python `utils/overlay_document.py`):
/// one template page in memory, every edit of it, undo and redo.
///
/// The document wraps the layout exactly as it sits in the page's
/// `normal.json` and never drops a key it does not know, so loading a
/// bundled template and giving it back is the same data key for key. What
/// the renderer needs beside it (the skin's resolved path, the image's
/// size in pixels) is kept next to the layout, not in it, so that it
/// cannot leak into a saved file.
library;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/util/json_tree.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// How many steps can be undone.
const undoLimit = 100;

/// The decimals `rel_x` and `rel_y` are saved with.
const relDecimals = 5;

/// An element may hang off the skin, but not vanish.
const relMin = -0.5;
const relMax = 1.5;

/// Whether [path] says where it is by itself: absolute for [context], or a
/// Windows path with a drive letter or a share (`C:/…`, `C:\…`, `\\server`)
/// whatever the context, since a picked file comes with such a path.
bool isAbsolutePath(String path, p.Context context) =>
    context.isAbsolute(path) ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) ||
    path.startsWith(r'\\');

double _clampRel(num value) => pyMax(relMin, pyMin(relMax, value.toDouble()));

/// Which slot of the template tree a document came from, or is meant for.
class TemplateRef {
  const TemplateRef(this.brand, this.computer, this.page, [this.variant]);

  final String brand;
  final String computer;
  final String page;
  final String? variant;

  String get label => [
    brand,
    computer,
    page,
    if ((variant ?? '').isNotEmpty) variant,
  ].join('/');

  @override
  bool operator ==(Object other) =>
      other is TemplateRef &&
      other.brand == brand &&
      other.computer == computer &&
      other.page == page &&
      other.variant == variant;

  @override
  int get hashCode => Object.hash(brand, computer, page, variant);
}

/// The size in pixels of the image at a path, or `null` when there is no
/// image there that can be read.
typedef ImageSizeOf = (int width, int height)? Function(String path);

double _float(Map<String, dynamic> map, String key, num fallback) {
  final value = map[key];
  return (value is num ? value : fallback).toDouble();
}

class OverlayDocument {
  /// A document of [layout], which it keeps and edits (no copy is made).
  /// [sourcePath] is the file the layout came from: a skin path that is
  /// not absolute is looked for beside it. [imageSize] reads the skin
  /// image's size.
  OverlayDocument(
    this.layout, {
    this.sourcePath,
    this.ref,
    ImageSizeOf? imageSize,
    p.Context? context,
  }) : _imageSize = imageSize ?? ((_) => null),
       _path = context ?? p.posix,
       _savedSnapshot = jsonCopyMap(layout) {
    _resolveSkin();
  }

  /// The document of a layout file. A variant overlay file loads as its
  /// merged layout, tagged so that saving can split it again.
  factory OverlayDocument.load(
    String path,
    String Function(String path) readText, {
    TemplateRef? ref,
    ImageSizeOf? imageSize,
    p.Context? context,
  }) => OverlayDocument(
    loadLayoutFile(path, readText, context: context),
    sourcePath: path,
    ref: ref,
    imageSize: imageSize,
    context: context,
  );

  Map<String, dynamic> layout;
  final String? sourcePath;
  TemplateRef? ref;
  final ImageSizeOf _imageSize;
  final p.Context _path;

  /// Where the skin image is: its path as the layout has it, or, for a
  /// relative one, beside the layout's file (normalised, not made
  /// absolute). `null` for a shape skin or one without a path.
  String? skinAbsPath;

  /// The skin image's size in pixels; 0 when there is none to read.
  int nativeWidth = 0;
  int nativeHeight = 0;

  final List<Map<String, dynamic>> _undo = [];
  final List<Map<String, dynamic>> _redo = [];
  Map<String, dynamic> _savedSnapshot;

  /// The shared base file when this document is a variant overlay.
  String? get variantBasePath {
    final raw = layout[layoutBaseKey];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  void _resolveSkin() {
    final skin = this.skin;
    skinAbsPath = null;
    nativeWidth = nativeHeight = 0;
    if (skinType != 'image') {
      return;
    }
    final raw = skin['path'];
    if (raw is! String || raw.isEmpty) {
      return;
    }
    final source = sourcePath;
    final candidate = isAbsolutePath(raw, _path) || source == null
        ? raw
        : _path.normalize(_path.join(_path.dirname(source), raw));
    skinAbsPath = candidate;
    final size = _imageSize(candidate);
    if (size != null) {
      nativeWidth = size.$1;
      nativeHeight = size.$2;
    }
  }

  // --- Read access --------------------------------------------------------

  /// The `hud_skin` block (made when the layout has none).
  Map<String, dynamic> get skin =>
      layout.putIfAbsent('hud_skin', () => <String, dynamic>{})
          as Map<String, dynamic>;

  /// The elements, in drawing order (the list is made when there is none).
  List<Map<String, dynamic>> get elements =>
      // A view of the layout's own list: what is added here is in it.
      (skin.putIfAbsent('linked_elements', () => <dynamic>[]) as List<dynamic>)
          .cast<Map<String, dynamic>>();

  String get skinType => skin['type'] as String? ?? 'image';

  String get manufacturer => layout['manufacturer'] as String? ?? '';

  String get model => layout['model'] as String? ?? '';

  /// The manufacturer the rules are looked up by: `rules_profile` when
  /// set, else [manufacturer].
  String get rulesManufacturer {
    final profile = layout['rules_profile'];
    return profile is String && profile.isNotEmpty ? profile : manufacturer;
  }

  (int, int) get designSize => (
    _float(layout, 'design_width', 1920).truncate(),
    _float(layout, 'design_height', 1080).truncate(),
  );

  /// The skin's size in its own pixels, before the template's `scale`: an
  /// image's pixel size, a shape's width and height.
  (double, double) skinNativeSize() => skinType == 'shape'
      ? (_float(skin, 'width', 400), _float(skin, 'height', 200))
      : (nativeWidth.toDouble(), nativeHeight.toDouble());

  /// The skin's size in design pixels as the template draws it (an image's
  /// size times `scale`; a shape ignores scale).
  (double, double) skinScaledSize() {
    final (w, h) = skinNativeSize();
    if (skinType == 'shape') {
      return (w, h);
    }
    final scale = _float(skin, 'scale', 1.0);
    return (w * scale, h * scale);
  }

  // --- Layouts for the renderer -------------------------------------------

  /// A copy with the skin's path resolved: what the renderer wants for a
  /// whole frame.
  Map<String, dynamic> renderLayout() {
    final copy = jsonCopyMap(layout);
    final resolved = skinAbsPath;
    if (resolved != null) {
      (copy.putIfAbsent('hud_skin', () => <String, dynamic>{})
              as Map<String, dynamic>)['path'] =
          resolved;
    }
    return copy;
  }

  /// The layout for the telemetry-only mode: the skin alone at its own
  /// size times [zoom], the template's `scale` ignored (the design view is
  /// the authoring space; positions and font sizes are in skin pixels).
  /// The zoom goes in as the skin's scale; a shape's width and height are
  /// multiplied too.
  Map<String, dynamic> designViewLayout(double zoom) {
    final copy = renderLayout();
    final skin = copy.putIfAbsent(
      'hud_skin',
      () => <String, dynamic>{},
    ) as Map<String, dynamic>;
    if ((skin['type'] ?? 'image') == 'shape') {
      skin['width'] = _float(skin, 'width', 400) * zoom;
      skin['height'] = _float(skin, 'height', 200) * zoom;
    }
    skin['scale'] = zoom;
    return copy;
  }

  // The base point in the frame and the pivot in the skin for an anchor.
  (double, double, double, double) _anchorPoints(
    num frameW,
    num frameH,
    double wHud,
    double hHud,
  ) {
    final anchor = skin['anchor'] as String? ?? 'TOP_LEFT';
    final center = anchor.contains('CENTER');
    final right = anchor.contains('RIGHT');
    final middle = anchor.contains('MIDDLE');
    final bottom = anchor.contains('BOTTOM');
    return (
      center ? frameW / 2.0 : (right ? frameW.toDouble() : 0.0),
      middle ? frameH / 2.0 : (bottom ? frameH.toDouble() : 0.0),
      center ? wHud / 2.0 : (right ? wHud : 0.0),
      middle ? hHud / 2.0 : (bottom ? hHud : 0.0),
    );
  }

  double _resScale(num frameW) {
    final designW = designSize.$1.toDouble();
    return designW != 0 ? frameW / designW : 1.0;
  }

  /// Where the skin is on a frame of this size, as (x, y, width, height):
  /// the renderer's own anchor arithmetic and truncation, so that a click
  /// on the frame preview lands on the drawn pixels.
  (double, double, double, double) frameBox(num frameW, num frameH) {
    final resScale = _resScale(frameW);
    final (nativeW, nativeH) = skinNativeSize();
    final scale = skinType == 'shape' ? 1.0 : _float(skin, 'scale', 1.0);
    final wHud = skinType == 'shape'
        ? (nativeW * resScale).truncate()
        : (nativeW * scale * resScale).truncate();
    final hHud = skinType == 'shape'
        ? (nativeH * resScale).truncate()
        : (nativeH * scale * resScale).truncate();
    final (baseX, baseY, pivotX, pivotY) = _anchorPoints(
      frameW,
      frameH,
      wHud.toDouble(),
      hHud.toDouble(),
    );
    final x = (baseX + _float(skin, 'ref_offset_x', 0.0) * resScale - pivotX)
        .truncate();
    final y = (baseY + _float(skin, 'ref_offset_y', 0.0) * resScale - pivotY)
        .truncate();
    return (x.toDouble(), y.toDouble(), wHud.toDouble(), hHud.toDouble());
  }

  /// Moves the skin so that its top-left corner is at this point of a
  /// frame of this size, keeping the anchor: the inverse of [frameBox].
  /// The offsets are stored in design pixels.
  void setFramePosition(
    num frameX,
    num frameY,
    num frameW,
    num frameH, {
    bool recordUndo = true,
  }) {
    final resScale = _resScale(frameW);
    final (_, _, wHud, hHud) = frameBox(frameW, frameH);
    final (baseX, baseY, pivotX, pivotY) = _anchorPoints(
      frameW,
      frameH,
      wHud,
      hHud,
    );
    if (recordUndo) {
      pushUndo();
    }
    skin['ref_offset_x'] = pyRoundTo((frameX - baseX + pivotX) / resScale, 2);
    skin['ref_offset_y'] = pyRoundTo((frameY - baseY + pivotY) / resScale, 2);
  }

  // --- Element editing: every change records one undo step unless told
  // otherwise (a drag records once on press, then streams). ---------------

  Map<String, dynamic>? element(int index) {
    final list = elements;
    return index >= 0 && index < list.length ? list[index] : null;
  }

  /// Adds an element at the end and gives its index.
  int addElement(
    String field, {
    String kind = 'text',
    num relX = 0.5,
    num relY = 0.5,
    Map<String, dynamic> attrs = const {},
  }) {
    final elem = elementDefaults(kind, field)
      ..['rel_x'] = _clampRel(relX)
      ..['rel_y'] = _clampRel(relY)
      ..addAll(attrs);
    pushUndo();
    elements.add(elem);
    return elements.length - 1;
  }

  bool removeElement(int index) {
    if (element(index) == null) {
      return false;
    }
    pushUndo();
    elements.removeAt(index);
    return true;
  }

  /// Puts a copy of an element right after it, a little down and to the
  /// right, and gives the copy's index.
  int? duplicateElement(int index) {
    final source = element(index);
    if (source == null) {
      return null;
    }
    pushUndo();
    final clone = asNewElement(source);
    clone['rel_x'] = _clampRel(_float(clone, 'rel_x', 0.0) + 0.02);
    clone['rel_y'] = _clampRel(_float(clone, 'rel_y', 0.0) + 0.02);
    elements.insert(index + 1, clone);
    return index + 1;
  }

  void moveElement(int index, num relX, num relY, {bool recordUndo = true}) {
    final elem = element(index);
    if (elem == null) {
      return;
    }
    if (recordUndo) {
      pushUndo();
    }
    elem['rel_x'] = _clampRel(relX);
    elem['rel_y'] = _clampRel(relY);
  }

  /// The position in the skin's own pixels, which is what the inspector
  /// shows.
  void setElementPositionPx(
    int index,
    num xPx,
    num yPx, {
    bool recordUndo = true,
  }) {
    final (nativeW, nativeH) = skinNativeSize();
    if (nativeW <= 0 || nativeH <= 0) {
      return;
    }
    moveElement(index, xPx / nativeW, yPx / nativeH, recordUndo: recordUndo);
  }

  (double, double) elementPositionPx(int index) {
    final elem = element(index) ?? const <String, dynamic>{};
    final (nativeW, nativeH) = skinNativeSize();
    return (
      _float(elem, 'rel_x', 0.0) * nativeW,
      _float(elem, 'rel_y', 0.0) * nativeH,
    );
  }

  void nudgeElement(int index, num dxPx, num dyPx) {
    final (x, y) = elementPositionPx(index);
    setElementPositionPx(index, x + dxPx, y + dyPx);
  }

  /// Sets one attribute, or with a `null` value takes it away. `rel_x` and
  /// `rel_y` are clamped; a change of field also sets the element's type
  /// right. The type itself, and taking away the field or the position,
  /// are refused.
  void setElementAttr(int index, String key, Object? value) {
    final elem = element(index);
    if (elem == null || key == 'type') {
      return;
    }
    if (value == null) {
      if (elem.containsKey(key) &&
          key != 'field' &&
          key != 'rel_x' &&
          key != 'rel_y') {
        pushUndo();
        elem.remove(key);
      }
      return;
    }
    final next = key == 'rel_x' || key == 'rel_y'
        ? _clampRel(value as num)
        : value;
    if (jsonDeepEquals(elem[key], next)) {
      return;
    }
    pushUndo();
    elem[key] = next;
    if (key == 'field') {
      if (next == 'depth_graph') {
        elem['type'] = 'graph';
      } else if (next == 'state_badge') {
        elem['type'] = 'badge';
      } else if (const ['graph', 'badge'].contains(elementKind(elem))) {
        elem.remove('type');
      }
    }
  }

  /// Moves an element up or down the drawing order and gives its new
  /// index.
  int reorderElement(int index, int delta) {
    final list = elements;
    if (element(index) == null) {
      return index;
    }
    final target = index + delta;
    final newIndex = target < 0
        ? 0
        : (target > list.length - 1 ? list.length - 1 : target);
    if (newIndex == index) {
      return index;
    }
    pushUndo();
    list.insert(newIndex, list.removeAt(index));
    return newIndex;
  }

  // --- Skin editing --------------------------------------------------------

  /// Sets one attribute of the skin. An anchor that is not one, and the
  /// skin's type, path and elements, are refused.
  void setSkinAttr(String key, Object? value) {
    if (key == 'anchor' && !anchors.contains(value)) {
      return;
    }
    if (key == 'type' || key == 'path' || key == 'linked_elements') {
      return;
    }
    if (jsonDeepEquals(skin[key], value)) {
      return;
    }
    pushUndo();
    skin[key] = value;
  }

  /// Points an image skin at another file; the elements keep their
  /// relative places. False when the image cannot be read.
  bool setSkinImage(String path) {
    if (_imageSize(path) == null) {
      return false;
    }
    pushUndo();
    skin
      ..['type'] = 'image'
      ..['path'] = path
      ..putIfAbsent('scale', () => 1.0);
    for (final key in ['width', 'height', 'color', 'corner_radius']) {
      skin.remove(key);
    }
    _resolveSkin();
    return true;
  }

  // --- Serialization ------------------------------------------------------

  /// A copy of the layout. With [forSave] the skin's path is its bare file
  /// name (a template is a folder that holds all it needs) and `rel_x` and
  /// `rel_y` are rounded the way the hand-written files have them.
  Map<String, dynamic> toLayout({bool forSave = false}) {
    final copy = jsonCopyMap(layout);
    if (!forSave) {
      return copy;
    }
    final skin = copy.putIfAbsent(
      'hud_skin',
      () => <String, dynamic>{},
    ) as Map<String, dynamic>;
    final path = skin['path'];
    if (path is String && path.isNotEmpty) {
      skin['path'] = pyFileName(path);
    }
    for (final elem in skin['linked_elements'] as List<dynamic>? ?? const []) {
      for (final key in ['rel_x', 'rel_y']) {
        final value = (elem as Map<String, dynamic>)[key];
        if (value is double) {
          elem[key] = pyRoundTo(value, relDecimals);
        }
      }
    }
    return copy;
  }

  // --- Dirty tracking, undo and redo --------------------------------------

  bool get dirty => !jsonDeepEquals(layout, _savedSnapshot);

  void markSaved() => _savedSnapshot = jsonCopyMap(layout);

  /// Call before changing the layout: keeps the state as it is now.
  void pushUndo() {
    _undo.add(jsonCopyMap(layout));
    if (_undo.length > undoLimit) {
      _undo.removeAt(0);
    }
    _redo.clear();
  }

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  bool undo() => _step(_undo, _redo);

  bool redo() => _step(_redo, _undo);

  bool _step(List<Map<String, dynamic>> from, List<Map<String, dynamic>> to) {
    if (from.isEmpty) {
      return false;
    }
    to.add(jsonCopyMap(layout));
    layout = from.removeLast();
    _resolveSkin();
    return true;
  }
}
