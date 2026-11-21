/// The Overlay Designer's state (Python `backends/overlay_designer_backend.py`):
/// a template page picked from the trees and edited as an
/// [OverlayDocument]; selection (one element, several, or the skin) moved
/// and nudged on the canvas with a marquee and snapping; the inspector's
/// attributes; added, removed, duplicated, reordered, aligned,
/// distributed, resized, copied and pasted elements; undo and redo; the
/// page saved, saved as another or reverted, and new custom pages; the
/// canvas in Design view (the skin alone, zoomed) or Frame preview (the
/// whole frame); and the dummy dive the canvas shows, at a time, in a
/// forced state, in the page's own units.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/app_paths.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_geometry.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/overlay_document.dart';
import 'package:uwmedia_app/core/hud/template_store.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/rules/hud_notices.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/core/util/json_tree.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/log_files.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/engine/template_files.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';
import 'package:uwmedia_app/pages/shared/template_picker.dart';

const viewDesign = 'design';
const viewFrame = 'frame';
const sourceDummy = 'dummy';
const sourceLog = 'log';

const zoomMin = 0.25;
const zoomMax = 4.0;
const zoomStep = 0.25;
const maxRenderWidth = 4096;
const frameW = 1920;
const frameH = 1080;
const checkerPx = 16;
const defaultViewport = (700.0, 440.0);
const dummyDefaultSeconds = 12 * 60;
const nudgePx = 1;
const nudgePxFast = 10;
const hitSlackDisplayPx = 3.0;
const snapTolerancePx = 4.0;
const gridSizes = [4, 8, 16, 32];
const defaultGridSize = 8;
const playSpeed = 10;
const playTickMs = 100;
const defaultStopsColor = '#FFA500';

const imageDirField = 'overlay_designer_image_dir';
const zipDirField = 'overlay_designer_zip_dir';

/// What a page zip says about the page, beside its state and skin.
const zipMetaFilename = 'template.json';
const backgroundDirField = 'overlay_designer_background_dir';
const logDirField = 'overlay_designer_log_dir';

// Attributes whose default is the key's absence: the inspector takes the
// key away instead of writing the default.
const _elementAttrDefaults = {
  'align': 'left',
  'valign': 'top',
  'outline': textOutlineDefault,
  'font_weight': 'regular',
  'font_family': defaultFontFamily,
};

const depthSmallDecimals = 'depth_small_decimals';
const diveTimeSmallSeconds = 'dive_time_small_seconds';

/// Add-element presets: a field with its small suffix style.
const addElementPresets = {
  depthSmallDecimals: ('depth', 'decimals'),
  diveTimeSmallSeconds: ('dive_time', 'seconds'),
};

const _numericElementAttrs = {
  'thickness', 'start_angle', 'sweep', 'range_min', 'range_max', //
  'font_size', 'value_font_size', 'caption_font_size', 'scale', //
  'max_width', 'unit_scale', 'unit_dx', 'unit_dy', 'width', 'height',
  'corner_radius', 'marker_size', 'small_suffix_scale', 'outline_width',
  'outline_gap', 'up_count', 'down_count', 'segments', 'segment_gap',
  'full_bar', 'empty_bar', 'fill_opacity', 'stops_opacity',
  'ceiling_opacity', 'background_opacity',
};
const _intElementAttrs = {
  'thickness', 'start_angle', 'sweep', //
  'font_size', 'value_font_size', 'caption_font_size', 'max_width', //
  'width', 'height', 'corner_radius', 'marker_size', 'outline_width',
  'outline_gap', 'up_count', 'down_count', 'segments', 'segment_gap',
  'full_bar', 'empty_bar',
};
const _styleDefaults = {
  'tissue_bar': 'segments',
  'tank_icon': 'fill',
  'notice': 'text',
};
const _numericSkinAttrs = {
  'scale', 'opacity', 'ref_offset_x', 'ref_offset_y', 'width', 'height', //
  'corner_radius',
};
const _intSkinAttrs = {'width', 'height', 'corner_radius'};
const addableKinds = [
  'text', 'badge', 'tank_icon', 'graph', 'tissue_bar', 'ascent_chevrons', //
  'notice', 'tank_switch_arrows', 'arc', 'segment_bar',
];

/// What the page needs of ffmpeg and exiftool for a background.
abstract interface class DesignerMedia {
  /// Every tag of a file; `null` when it cannot be read.
  Future<MediaTags?> metadata(String path);

  /// A video's frame rate and frame count.
  Future<({double fps, int frames})> videoFacts(String path);

  /// A video's width and height.
  Future<(int, int)> dimensions(String path);

  /// The frame at [seconds], as RGB at [width] x [height]; `null` when
  /// there is none.
  Future<RgbImage?> frameAt(String path, double seconds, int width, int height);
}

// The dives of one log file off the UI isolate: `null` dives for a file
// that is no log, or the reason it could not be read.
({List<Dive>? dives, String? error}) _readLogFile((String, TankConfig) job) {
  final (path, tanks) = job;
  final name = p.basename(path);
  if (!File(path).existsSync() || name.startsWith('.')) {
    return (dives: null, error: null);
  }
  try {
    final dives = parseLogFile(
      path,
      File(path).readAsBytesSync(),
      tanks: tanks,
    );
    for (final dive in dives ?? const <Dive>[]) {
      if ((dive.logPath ?? '').isEmpty) {
        dive.logPath = path;
      }
      if ((dive.logFilename ?? '').isEmpty) {
        dive.logFilename = name;
      }
    }
    return (dives: dives, error: null);
  } on FormatException catch (e) {
    return (dives: null, error: e.message);
  } on FileSystemException catch (e) {
    return (dives: null, error: e.message);
  } on Object catch (e) {
    // Any parser failure is this file's own; a folder goes on to the next.
    return (dives: null, error: '$e');
  }
}

// Every log of a folder off the UI isolate, and how many files were logs.
({List<Dive> dives, int files}) _readLogFolder((String, TankConfig) job) {
  final (folder, tanks) = job;
  final dives = <Dive>[];
  var files = 0;
  for (final path in logFilesIn(folder)) {
    final read = _readLogFile((path, tanks));
    if (read.dives != null) {
      dives.addAll(read.dives!);
      files++;
    }
  }
  return (dives: dives, files: files);
}

/// A choice of where a page is saved: an existing computer, or (computer
/// '') a new custom one.
typedef SaveTarget = ({String label, String brand, String computer});

/// One row of the element list.
typedef ElementRow = ({
  int index,
  String field,
  String kind,
  String label,
  bool hidden,
  bool shared,
});

/// A box on the canvas in display pixels: left, top, width, height.
typedef DisplayBox = (double, double, double, double);

typedef _NativeBox = (double, double, double, double);

class _Drag {
  _Drag.element(this.index, this.startNx, this.startNy, this.orig, this.bounds)
    : mode = 'element',
      startX = 0,
      startY = 0,
      origFx = 0,
      origFy = 0,
      onSkin = false;

  _Drag.skin(this.startX, this.startY, this.origFx, this.origFy)
    : mode = 'skin',
      index = -1,
      startNx = 0,
      startNy = 0,
      orig = const {},
      bounds = const [],
      onSkin = true;

  _Drag.marquee(this.startNx, this.startNy, this.onSkin, this.bounds)
    : mode = 'marquee',
      index = -1,
      startX = 0,
      startY = 0,
      origFx = 0,
      origFy = 0,
      orig = const {};

  final String mode;
  final int index;
  final double startNx;
  final double startNy;
  final double startX;
  final double startY;
  final double origFx;
  final double origFy;
  final Map<int, (double, double)> orig;
  final List<_NativeBox> bounds;
  final bool onSkin;
  bool pushed = false;
  bool moved = false;
}

String _prettify(String key) => prettifyKey(key);

double _clampZoom(double value) => value.clamp(zoomMin, zoomMax);

/// `0:12:00` for 720 seconds (Python `str(timedelta(seconds=…))`).
String timedeltaText(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return '$h:${'$m'.padLeft(2, '0')}:${'$s'.padLeft(2, '0')}';
}

class DesignerController extends ChangeNotifier {
  DesignerController({
    required this.config,
    required this.home,
    required this.kit,
    required this.loadFolders,
    required this.templateBytes,
    this.onTemplatesChanged,
    this.media,
    this.tempDir,
    this.checkout = false,
  });

  final ConfigStore config;
  final String home;
  final HudKit kit;

  /// The bundled and the user's template folders, listed again.
  final Future<(TemplateFolder?, TemplateFolder)> Function() loadFolders;

  /// The bytes of a template file (an asset or a file on disk).
  final Future<Uint8List?> Function(String path) templateBytes;

  /// Told after a page is saved, so that the pages offering templates list
  /// them again (Python's `templatesChanged`).
  final VoidCallback? onTemplatesChanged;

  /// ffmpeg and exiftool for a background video or photo; throws when they
  /// cannot be found.
  final Future<DesignerMedia> Function()? media;

  /// Makes a working folder (`appTempDir` in the app): an imported page's
  /// skin waits there until it is saved.
  final Directory Function(String prefix)? tempDir;

  /// Checkout mode (spec §10.84): the bundled tree is the source
  /// checkout's folder, and saves go straight into it.
  final bool checkout;

  HudRenderer get renderer => kit.renderer;
  HudPainter get painter => kit.painter;

  TemplateFolder? _bundled;
  TemplateFolder? _user;
  TemplateTree tree = TemplateTree();

  OverlayDocument? document;
  String status = '';
  bool _disposed = false;

  void _setStatus(String text) {
    status = text;
    notifyListeners();
  }

  /// Lists the trees and loads the first page.
  Future<void> start() async {
    await _listFolders();
    _enterDummyTimeRange();
    final first = brandChoices.values.firstOrNull;
    if (first != null) {
      await selectBrand(first);
    } else {
      notifyListeners();
    }
  }

  Future<void> _listFolders() async {
    final (bundled, user) = await loadFolders();
    _bundled = bundled;
    _user = user;
    tree = TemplateTree(bundled: bundled, user: user);
  }

  // -- the cascade -------------------------------------------------------------

  String? _brand;
  String? _computer;
  String? _page;
  String? _variant;
  Dive? currentDive;

  Map<String, Map<String, Map<String, dynamic>>> get _templates => tree.brands;

  Choices get brandChoices => {
    for (final key in _templates.keys.toList()..sort()) _prettify(key): key,
  };

  Choices get computerChoices {
    final computers = _brand == null ? null : _templates[_brand];
    return {
      for (final key in (computers?.keys.toList() ?? <String>[])..sort())
        _prettify(key): key,
    };
  }

  bool get computerVisible => (_templates[_brand]?.length ?? 0) > 1;

  Map<String, dynamic>? get _manifest => _brand == null || _computer == null
      ? null
      : _templates[_brand]?[_computer];

  Map<String, dynamic>? get _pageEntry {
    final pages = _manifest?['pages'];
    if (pages is! List || _page == null) {
      return null;
    }
    return pages
        .cast<Map<String, dynamic>>()
        .where((e) => e['id'] == _page)
        .firstOrNull;
  }

  Choices get pageChoices {
    final pages = _manifest?['pages'];
    return {
      if (pages is List)
        for (final page in pages.cast<Map<String, dynamic>>())
          pageDisplayName(page): page['id'] as String,
    };
  }

  Choices get variantChoices {
    final variants = _pageEntry?['variants'];
    return {
      if (variants is List)
        for (final v in variants.cast<String>()) variantDisplayName(v): v,
    };
  }

  String? get selectedBrand => _brand;
  String? get selectedComputer => _computer;
  String? get selectedPage => _page;
  String? get selectedVariant => _variant;

  Future<void> selectBrand(String key) async {
    _brand = key;
    _computer = computerChoices.values.firstOrNull;
    await _refreshPageChoices();
  }

  Future<void> selectComputer(String key) async {
    _computer = key;
    await _refreshPageChoices();
  }

  Future<void> _refreshPageChoices() async {
    _page = pageChoices.values.firstOrNull;
    await _refreshVariantChoices();
  }

  Future<void> selectPage(String key) async {
    _page = key;
    await _refreshVariantChoices();
  }

  // A page's variants: picked from the loaded dive's tanks (two or more:
  // sidemount), else single tank; the user may pick another.
  Future<void> _refreshVariantChoices() async {
    final variants = variantChoices.values.toList();
    if (variants.isEmpty) {
      _variant = null;
    } else {
      final resolved = resolveTankVariant(currentDive);
      _variant = variants.contains(resolved) ? resolved : variants.first;
    }
    await _loadSelectedTemplate();
  }

  Future<void> selectVariant(String key) async {
    if (key == _variant) {
      return;
    }
    _variant = key;
    await _loadSelectedTemplate();
  }

  // -- the document ----------------------------------------------------------

  final Map<String, Uint8List?> _bytes = {};
  final Map<String, HudSkinPixels?> _skins = {};
  String _pageOrigin = '';
  bool _canSave = false;

  bool _isAsset(String path) => path.startsWith('$bundledTemplatesRoot/');

  p.Context _contextFor(String path) => _isAsset(path) ? p.posix : p.context;

  Uint8List? _readBytesSync(String path) {
    if (_bytes.containsKey(path)) {
      return _bytes[path];
    }
    if (_isAsset(path)) {
      return null;
    }
    try {
      final file = File(path);
      return file.existsSync() ? file.readAsBytesSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  (int, int)? _imageSizeOf(String path) {
    final bytes = _readBytesSync(path);
    return bytes == null ? null : imageSize(bytes);
  }

  OverlayDocument _load(String state, TemplateRef ref) => OverlayDocument.load(
    state,
    (path) => tree.readText(path) ?? (throw FormatException('No file $path')),
    ref: ref,
    imageSize: _imageSizeOf,
    context: _contextFor(state),
  );

  // A later load wins over one still reading a skin.
  int _loadTicket = 0;

  Future<void> _loadSelectedTemplate() async {
    final ticket = ++_loadTicket;
    final brand = _brand;
    final computer = _computer;
    final page = _page;
    final entry = _pageEntry;
    if (brand == null || computer == null || page == null || entry == null) {
      document = null;
      _afterDocumentChanged();
      return;
    }
    final state = tree.resolveState(brand, computer, page, variant: _variant);
    if (state == null) {
      document = null;
      status = 'Template state file not found.';
      _afterDocumentChanged();
      return;
    }
    final ref = TemplateRef(brand, computer, page, _variant);
    OverlayDocument doc;
    try {
      doc = _load(state, ref);
      // A bundled skin is an asset: its bytes first, then its size.
      final skin = doc.skinAbsPath;
      if (skin != null && !_bytes.containsKey(skin) && _isAsset(skin)) {
        final bytes = await templateBytes(skin);
        if (ticket != _loadTicket || _disposed) {
          return;
        }
        if (bytes != null) {
          _bytes[skin] = bytes;
        }
        doc = _load(state, ref);
      }
    } on Object catch (e) {
      if (ticket != _loadTicket || _disposed) {
        return;
      }
      document = null;
      status = 'Could not load ${ref.label}: $e';
      _afterDocumentChanged();
      return;
    }
    if (ticket != _loadTicket || _disposed) {
      return;
    }
    document = doc;
    dummyDive = buildDummyDive(variant: _variant, ccr: entry['dive'] == 'ccr');
    _pageOrigin = entry['origin'] as String? ?? originBundled;
    // The bundled tree is the app's assets, never written; in checkout
    // mode it is the checkout's folder, and it is.
    _canSave = _pageOrigin == originUser || checkout;
    status = 'Loaded ${ref.label}';
    _afterDocumentChanged();
  }

  // Lists the trees again and selects [ref] (or the first at each level
  // where it is gone), then loads it: after a save, save-as or revert.
  Future<void> _selectRef(TemplateRef ref, {bool keepSelection = false}) async {
    final selected = _selectedIndex;
    final skin = _skinSelected;
    await _listFolders();
    if (_disposed) {
      return;
    }
    final brands = _templates;
    _brand = brands.containsKey(ref.brand)
        ? ref.brand
        : brands.keys.firstOrNull;
    final computers = brands[_brand] ?? const {};
    _computer = computers.containsKey(ref.computer)
        ? ref.computer
        : computerChoices.values.firstOrNull;
    final pages = pageChoices.values.toList();
    _page = pages.contains(ref.page) ? ref.page : pages.firstOrNull;
    final variants = variantChoices.values.toList();
    if (variants.isEmpty) {
      _variant = null;
    } else if (variants.contains(ref.variant)) {
      _variant = ref.variant;
    } else {
      final resolved = resolveTankVariant(currentDive);
      _variant = variants.contains(resolved) ? resolved : variants.first;
    }
    await _loadSelectedTemplate();
    final doc = document;
    if (keepSelection && doc != null) {
      _setPrimary(math.min(selected, doc.elements.length - 1));
      _skinSelected = skin && _selectedIndex < 0;
      _update();
    }
  }

  void _afterDocumentChanged() {
    if (_disposed) {
      return;
    }
    if (document == null) {
      _pageOrigin = '';
      _canSave = false;
    }
    _selectedIndex = -1;
    _selected = {};
    _skinSelected = false;
    _drag = null;
    _marquee = null;
    _hidden = {};
    _zoomFit = true;
    _applyFitZoom();
    _update();
  }

  // Everything derived from the document again: the boxes, the data line,
  // the canvas.
  void _update() {
    _updateDataText();
    _updateBoxes();
    _redraw();
    notifyListeners();
  }

  void _afterGeometryEdit() {
    if (_zoomFit) {
      _applyFitZoom();
    }
    _update();
  }

  // -- saving ------------------------------------------------------------------

  bool get hasDocument => document != null;
  String get pageOrigin => document == null ? '' : _pageOrigin;
  bool get canSave => document != null && _canSave;
  String get readOnlyHint => document == null || _canSave
      ? ''
      : 'Built-in template - read-only here. Use Save as… to make your own '
            'copy.';

  String get writeTargetText => checkout
      ? 'Checkout mode: saves go into the built-in templates in '
            '${displayRoot(_bundled?.root ?? '', home)}'
      : 'Your templates are saved to ${displayRoot(_user?.root ?? '', home)}';

  /// Every computer of the trees, then a new custom one.
  List<SaveTarget> get saveAsTargets {
    final targets = <SaveTarget>[];
    for (final brand in _templates.keys.toList()..sort()) {
      final computers = _templates[brand]!;
      for (final computer in computers.keys.toList()..sort()) {
        final manifest = computers[computer]!;
        final maker =
            manifest['manufacturer'] is String &&
                (manifest['manufacturer'] as String).isNotEmpty
            ? manifest['manufacturer'] as String
            : _prettify(brand);
        final model =
            manifest['model'] is String &&
                (manifest['model'] as String).isNotEmpty
            ? manifest['model'] as String
            : _prettify(computer);
        targets.add((
          label: '$maker · $model'.replaceAll(RegExp(r'^[ ·]+|[ ·]+$'), ''),
          brand: brand,
          computer: computer,
        ));
      }
    }
    targets.add((
      label: 'New Custom computer…',
      brand: customBrand,
      computer: '',
    ));
    return targets;
  }

  int get saveAsCurrentTargetIndex {
    final targets = saveAsTargets;
    final i = targets.indexWhere(
      (t) => t.brand == _brand && t.computer == _computer,
    );
    return i < 0 ? 0 : i;
  }

  String slugFor(String name) => slugify(name);

  TemplateStore _store() => TemplateStore(
    bundled: _bundled,
    user: _user!,
    target: checkout ? TemplateTarget.repo : TemplateTarget.user,
    fileExists: (path) => File(path).existsSync(),
    context: p.context,
  );

  // One save, Save as or new page at a time.
  bool _saving = false;

  bool get saving => _saving;

  Future<void> _carryOut(TemplateSave save) async {
    await carryOutTemplateSave(
      save,
      readBytes: (path) async => _bytes[path] ?? await templateBytes(path),
    );
    // What was written is read again when it is drawn next.
    for (final op in save.ops) {
      _bytes.remove(op.path);
      _skins.remove(op.path);
    }
  }

  /// The reason a save failed, for the status or the dialog.
  static String _saveError(Object e, String what) => switch (e) {
    TemplateStoreError(:final message) => message,
    FileSystemException(:final message) => '$what: $message',
    _ => '$what: $e',
  };

  /// Saves the page in place. False with the reason in the status when it
  /// cannot be.
  Future<bool> save() async {
    final doc = document;
    final ref = doc?.ref;
    if (doc == null || ref == null) {
      return false;
    }
    if (!_canSave) {
      _setStatus(readOnlyHint);
      return false;
    }
    if (_saving) {
      return false;
    }
    _saving = true;
    try {
      final done = _store().saveTemplate(ref, doc.renderLayout());
      await _carryOut(done);
      onTemplatesChanged?.call();
      await _selectRef(ref, keepSelection: true);
      _setStatus('Saved ${ref.label} → ${displayRoot(done.statePath, home)}');
      return true;
    } on Object catch (e) {
      _setStatus(_saveError(e, 'Could not save'));
    } finally {
      _saving = false;
    }
    return false;
  }

  /// Saves the page as a new user page; '' or the reason it could not.
  Future<String> saveAs(
    int targetIndex,
    String newComputerName,
    String pageName,
  ) async {
    final doc = document;
    if (doc == null) {
      return 'Nothing to save.';
    }
    final dst = _target(targetIndex, newComputerName, pageName);
    if (dst.error != null) {
      return dst.error!;
    }
    if (_saving) {
      return 'A save is still running.';
    }
    _saving = true;
    try {
      final done = _store().saveTemplateAs(
        doc.renderLayout(),
        dst.ref!,
        pageName.trim(),
        manufacturer: dst.manufacturer,
        model: dst.model,
        overwriteUser: false,
      );
      await _carryOut(done);
      onTemplatesChanged?.call();
      await _selectRef(dst.ref!, keepSelection: true);
      _setStatus(
        'Saved as ${dst.ref!.label} → ${displayRoot(done.statePath, home)}',
      );
      return '';
    } on Object catch (e) {
      return _saveError(e, 'Could not save');
    } finally {
      _saving = false;
    }
  }

  ({TemplateRef? ref, String? manufacturer, String? model, String? error})
  _target(int targetIndex, String newComputerName, String pageName) {
    final targets = saveAsTargets;
    if (targetIndex < 0 || targetIndex >= targets.length) {
      return (
        ref: null,
        manufacturer: null,
        model: null,
        error: 'Pick where to save the page.',
      );
    }
    final target = targets[targetIndex];
    final pageId = slugify(pageName.trim());
    if (pageId.isEmpty) {
      return (
        ref: null,
        manufacturer: null,
        model: null,
        error: 'Enter a page name.',
      );
    }
    if (target.computer.isNotEmpty) {
      return (
        ref: TemplateRef(target.brand, target.computer, pageId),
        manufacturer: null,
        model: null,
        error: null,
      );
    }
    final name = newComputerName.trim();
    final computer = slugify(name);
    if (computer.isEmpty) {
      return (
        ref: null,
        manufacturer: null,
        model: null,
        error: 'Enter a name for the new computer.',
      );
    }
    return (
      ref: TemplateRef(customBrand, computer, pageId),
      manufacturer: customManufacturer,
      model: name,
      error: null,
    );
  }

  /// The page back to its saved file.
  Future<void> revert() async {
    final ref = document?.ref;
    if (ref == null) {
      return;
    }
    // The files as they are now, not as they were drawn.
    _bytes.clear();
    _skins.clear();
    await _selectRef(ref, keepSelection: true);
    _setStatus('Reverted ${ref.label} to the saved file');
  }

  /// The rule sets a new custom computer may borrow.
  List<String> get rulesProfiles => [
    'Default',
    for (final key in renderer.rules.rules.keys)
      if (key != 'default' && !isAnnotationKey(key)) key,
  ];

  /// A new page from a background image or a rounded rectangle, under an
  /// existing computer or a new custom one; '' or the reason it could not.
  Future<String> createCustomTemplate({
    required int targetIndex,
    required String newComputerName,
    required String pageName,
    required String backgroundKind,
    String imagePath = '',
    String rulesProfile = 'Default',
    Object? shapeWidth = 400,
    Object? shapeHeight = 200,
    String shapeColor = '#000000',
  }) async {
    final dst = _target(targetIndex, newComputerName, pageName);
    if (dst.error != null) {
      return dst.error!.replaceFirst('save the page', 'create the page');
    }
    String? profile;
    if (dst.manufacturer != null &&
        rulesProfile.trim().isNotEmpty &&
        rulesProfile.trim().toLowerCase() != 'default') {
      profile = rulesProfile.trim();
    }
    final skin = <String, dynamic>{
      'anchor': 'BOTTOM_LEFT',
      'ref_offset_x': 16.0,
      'ref_offset_y': -16.0,
      'opacity': 1.0,
      'linked_elements': <dynamic>[],
    };
    String? skinSource;
    if (backgroundKind == 'image') {
      if (imagePath.isEmpty || !File(imagePath).existsSync()) {
        return 'Pick a background image.';
      }
      (int, int)? size;
      try {
        size = imageSize(File(imagePath).readAsBytesSync());
      } on FileSystemException {
        size = null;
      }
      if (size == null) {
        return 'Could not read image: ${p.basename(imagePath)}';
      }
      final (width, height) = size;
      // At most 40 % of the frame either way.
      final scale = [
        1.0,
        0.4 * frameH / height,
        0.4 * frameW / width,
      ].reduce(math.min);
      skin.addAll({
        'type': 'image',
        'path': File(imagePath).absolute.path,
        'scale': pyRoundTo(scale, 3),
      });
      skinSource = imagePath;
    } else if (backgroundKind == 'shape') {
      // As typed: a number Python's float() reads, else the reason.
      double? size(Object? v) {
        final n = v is num ? v.toDouble() : pyFloat('${v ?? ''}'.trim());
        return n != null && n.isFinite ? n : null;
      }

      final width = size(shapeWidth);
      final height = size(shapeHeight);
      if (width == null || height == null) {
        return 'Enter a width and height for the shape.';
      }
      final color = shapeColor.length == 7 && shapeColor.startsWith('#')
          ? shapeColor
          : '#000000';
      skin.addAll({
        'type': 'shape',
        'width': math.max(1, pyRound(width)),
        'height': math.max(1, pyRound(height)),
        'color': color,
        'corner_radius': 20,
        'opacity': 0.6,
      });
    } else {
      return 'Pick a background type.';
    }
    final layout = <String, dynamic>{
      'manufacturer': dst.manufacturer ?? '',
      'model': dst.model ?? '',
      'hud_skin': skin,
      'design_width': frameW,
      'design_height': frameH,
    };
    if (_saving) {
      return 'A save is still running.';
    }
    _saving = true;
    try {
      final done = _store().saveTemplateAs(
        layout,
        dst.ref!,
        pageName.trim(),
        skinSource: skinSource,
        manufacturer: dst.manufacturer,
        model: dst.model,
        rulesProfile: profile,
        overwriteUser: false,
      );
      await _carryOut(done);
      onTemplatesChanged?.call();
      await _selectRef(dst.ref!);
      _setStatus(
        'Created ${dst.ref!.label} → ${displayRoot(done.statePath, home)} - '
        'add elements with + Add',
      );
      return '';
    } on Object catch (e) {
      return _saveError(e, 'Could not create the template');
    } finally {
      _saving = false;
    }
  }

  // -- titles and the element list -------------------------------------------------

  String get templateTitle {
    final doc = document;
    if (doc == null) {
      return 'No template selected';
    }
    final entry = _pageEntry ?? const {};
    final parts = [
      '${doc.manufacturer} ${doc.model}'.trim(),
      (entry['name'] ?? doc.ref?.page ?? '') as String,
      if (doc.ref?.variant != null) _prettify(doc.ref!.variant!),
    ];
    return parts.where((s) => s.isNotEmpty).join(' · ');
  }

  String get skinInfoText {
    final doc = document;
    if (doc == null) {
      return '';
    }
    final skin = doc.skin;
    final (nw, nh) = doc.skinNativeSize();
    String f2(Object? v) => pyFormatFixed((v as num? ?? 1.0).toDouble(), 2);
    final base = doc.skinType == 'shape'
        ? 'Shape ${pyFormatFixed(nw, 0)}×${pyFormatFixed(nh, 0)} px · '
              '${skin['color'] ?? '#000000'} · opacity ${f2(skin['opacity'])}'
        : 'Image ${pyFormatFixed(nw, 0)}×${pyFormatFixed(nh, 0)} px · scale '
              '${f2(skin['scale'])} · opacity ${f2(skin['opacity'])}';
    final anchor = _prettify('${skin['anchor'] ?? 'TOP_LEFT'}');
    String f0(Object? v) => pyFormatFixed((v as num? ?? 0).toDouble(), 0);
    return '$base\nAnchor $anchor · offset ${f0(skin['ref_offset_x'])}, '
        '${f0(skin['ref_offset_y'])}';
  }

  static String elementLabel(Map<String, dynamic> elem) {
    final name = '${elem['label'] ?? ''}'.trim();
    if (name.isNotEmpty) {
      return name;
    }
    final field = '${elem['field'] ?? ''}';
    if (field.startsWith('custom:')) {
      return '“${field.substring(7).replaceAll('\n', '⏎')}”';
    }
    return field;
  }

  List<ElementRow> get elementRows {
    final doc = document;
    if (doc == null) {
      return const [];
    }
    return [
      for (final (i, e) in doc.elements.indexed)
        (
          index: i,
          field: '${e['field'] ?? ''}',
          kind: elementKind(e),
          label: elementLabel(e),
          hidden: _hidden.contains(i),
          shared: isSharedElement(e),
        ),
    ];
  }

  // -- selection ---------------------------------------------------------------------

  int _selectedIndex = -1;
  Set<int> _selected = {};
  bool _skinSelected = false;
  Set<int> _hidden = {};

  int get selectedIndex => _selectedIndex;
  List<int> get selectedIndices => _selection();
  int get selectionCount => _selection().length;
  bool get skinSelected => _skinSelected;
  bool get hasSelection => _skinSelected || _selectedIndex >= 0;
  List<int> get hiddenIndices => _hidden.toList()..sort();

  void _setPrimary(int index) {
    _selectedIndex = index;
    _selected = index >= 0 ? {index} : {};
  }

  List<int> _selection() {
    final n = document?.elements.length ?? 0;
    return _selected.where((i) => i >= 0 && i < n).toList()..sort();
  }

  void _sanitizeSelection() {
    final n = document?.elements.length ?? 0;
    _selected = _selected.where((i) => i >= 0 && i < n).toSet();
    if (_selectedIndex >= n || !_selected.contains(_selectedIndex)) {
      _selectedIndex = _selected.isEmpty ? -1 : _selected.reduce(math.max);
    }
    _hidden = _hidden.where((i) => i >= 0 && i < n).toSet();
  }

  void _selectionChanged() {
    _updateBoxes();
    notifyListeners();
  }

  void selectElement(int index) {
    if (document?.element(index) == null) {
      return;
    }
    _setPrimary(index);
    _skinSelected = false;
    _selectionChanged();
  }

  /// Cmd/Ctrl-click: in or out of the selection.
  void toggleElement(int index) {
    if (document?.element(index) == null) {
      return;
    }
    _skinSelected = false;
    if (_selected.contains(index)) {
      _selected.remove(index);
      if (_selectedIndex == index) {
        _selectedIndex = _selected.isEmpty ? -1 : _selected.reduce(math.max);
      }
    } else {
      _selected.add(index);
      _selectedIndex = index;
    }
    _selectionChanged();
  }

  void selectAll() {
    final doc = document;
    if (doc == null || doc.elements.isEmpty) {
      return;
    }
    _selected = {for (var i = 0; i < doc.elements.length; i++) i};
    _selectedIndex = doc.elements.length - 1;
    _skinSelected = false;
    _selectionChanged();
  }

  void selectSkin() {
    if (document == null) {
      return;
    }
    _setPrimary(-1);
    _skinSelected = true;
    _selectionChanged();
  }

  void clearSelection() {
    if (_selectedIndex < 0 && _selected.isEmpty && !_skinSelected) {
      return;
    }
    _setPrimary(-1);
    _skinSelected = false;
    _selectionChanged();
  }

  void toggleHidden(int index) {
    if (document?.element(index) == null) {
      return;
    }
    if (!_hidden.remove(index)) {
      _hidden.add(index);
    }
    _update();
  }

  void showAllElements() {
    if (_hidden.isEmpty) {
      return;
    }
    _hidden = {};
    _update();
  }

  Map<String, dynamic> _visibleLayout(Map<String, dynamic> layout) {
    if (_hidden.isEmpty) {
      return layout;
    }
    final skin =
        (layout['hud_skin'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    final elements = skin['linked_elements'] as List<dynamic>? ?? const [];
    skin['linked_elements'] = [
      for (final (i, e) in elements.indexed)
        if (!_hidden.contains(i)) e,
    ];
    return layout;
  }

  // -- the inspector -------------------------------------------------------------------

  /// What the inspector shows of the selected element, every key there.
  Map<String, Object?> get selectedElement {
    final doc = document;
    final elem = doc?.element(_selectedIndex);
    if (doc == null || elem == null) {
      // Every key, so that a form never meets a missing one.
      return {
        'index': -1, 'kind': '', 'field': '', 'is_custom': false, //
        'custom_text': '', 'x_px': 0, 'y_px': 0, 'font_size': 16,
        'value_font_size': 16, 'scale': 1.0, 'color': '#FFFFFF',
        'align': 'left', 'valign': 'top', 'orientation': 'horizontal',
        'font_family': defaultFontFamily, 'bold': false,
        'outline': textOutlineDefault, 'width': 0, 'height': 0,
        'corner_radius': 0, 'marker_style': 'dot', 'marker_size': 6,
        'ceiling_color': '#808080', 'label': '', 'deco_stops': false,
        'stops_color': defaultStopsColor, 'reveal_profile': false,
        'stop_label': false, 'fill_color': '#00FF00',
        'fill_opacity': graphFillOpacity, 'stops_opacity': graphStopsOpacity,
        'ceiling_opacity': graphBandOpacity, 'background_color': '#000000',
        'background_opacity': graphBackgroundOpacity, 'small_suffix': '',
        'small_suffix_scale': smallSuffixDefaultScale,
        'draw_outline': false, 'outline_color': '#FFFFFF',
        'outline_width': 2, 'outline_gap': 4, 'up_count': 4,
        'down_count': 1, 'bar': true, 'style': 'segments', 'gap': 13,
        'count': 2, 'segments': 5, 'segment_gap': 2, 'full_bar': 200,
        'empty_bar': 0, 'fill_level': false, 'caption_font_size': 18,
        'confirm_text': '', 'caption_color': '', 'hide_when_notice': false,
        'hide_when_switch': false, 'source': 'timed', 'unit_suffix': false,
        'unit_position': 'right', 'unit_scale': 0.35, 'unit_dx': 0.0,
        'unit_dy': 0.0, 'unit_color': '', 'unit_orientation': 'horizontal',
        'max_width': 0, 'shared': false,
        'thickness': 12, 'start_angle': 135, 'sweep': 270, 'range_min': 0,
        'range_max': 100, 'track_color': '#303030', 'color_mode': 'value',
        'box_color': '',
      };
    }
    Object? get(String key, Object? fallback) => elem[key] ?? fallback;
    final (x, y) = doc.elementPositionPx(_selectedIndex);
    final field = '${elem['field'] ?? ''}';
    final kind = elementKind(elem);
    final stops = elem['stops_color'];
    return {
      'index': _selectedIndex,
      'kind': kind,
      'shared': isSharedElement(elem),
      'field': field,
      'is_custom': field.startsWith('custom:'),
      'custom_text': field.startsWith('custom:') ? field.substring(7) : '',
      'x_px': pyRoundTo(x, 1),
      'y_px': pyRoundTo(y, 1),
      'font_size': get('font_size', 16),
      'value_font_size': get('value_font_size', get('font_size', 16)),
      'scale': get('scale', 1.0),
      'color': get('color', '#FFFFFF'),
      'align': get('align', 'left'),
      'valign': get('valign', 'top'),
      'orientation': elem['orientation'] ?? 'horizontal',
      'font_family': elem['font_family'] ?? defaultFontFamily,
      'bold': (elem['font_weight'] ?? 'regular') == 'bold',
      'outline': truthy(get('outline', textOutlineDefault)),
      'width': get('width', 0),
      'height': get('height', 0),
      'corner_radius': get('corner_radius', 0),
      'marker_style': get('marker_style', 'dot'),
      'marker_size': get('marker_size', 6),
      'ceiling_color': get('ceiling_color', '#808080'),
      'deco_stops': truthy(stops),
      'stops_color': truthy(stops) ? stops : defaultStopsColor,
      'background_color': truthy(elem['background_color'])
          ? elem['background_color']
          : '#000000',
      'background_opacity': get('background_opacity', graphBackgroundOpacity),
      'fill_color': truthy(elem['fill_color'])
          ? elem['fill_color']
          : get('color', '#00FF00'),
      'fill_opacity': get('fill_opacity', graphFillOpacity),
      'stops_opacity': get('stops_opacity', graphStopsOpacity),
      'ceiling_opacity': get(
        'ceiling_opacity',
        truthy(stops) ? graphCeilingOpacity : graphBandOpacity,
      ),
      'reveal_profile': truthy(get('reveal_profile', false)),
      'stop_label': truthy(get('stop_label', false)),
      'label': get('label', ''),
      'small_suffix': elem['small_suffix'] ?? '',
      'small_suffix_scale': get('small_suffix_scale', smallSuffixDefaultScale),
      'draw_outline': truthy(get('draw_outline', false)),
      'outline_color': get('outline_color', '#FFFFFF'),
      'outline_width': get('outline_width', 2),
      'outline_gap': get('outline_gap', 4),
      'up_count': get('up_count', 4),
      'down_count': get('down_count', 1),
      'bar': elem['bar'] != false,
      'style': truthy(elem['style'])
          ? elem['style']
          : _styleDefaults[kind] ?? 'segments',
      'segments': get('segments', 5),
      'segment_gap': get('segment_gap', 2),
      'full_bar': get('full_bar', 200),
      'empty_bar': get('empty_bar', 0),
      'fill_level': truthy(get('fill_level', false)),
      'caption_font_size': get('caption_font_size', 18),
      'confirm_text': get('confirm_text', ''),
      'caption_color': elem['caption_color'] ?? '',
      'hide_when_notice': truthy(get('hide_when_notice', false)),
      'hide_when_switch': truthy(get('hide_when_switch', false)),
      'source': elem['source'] == 'persistent' ? 'persistent' : 'timed',
      'max_width': get('max_width', 0),
      'unit_suffix': truthy(get('unit_suffix', false)),
      'unit_position': elem['unit_position'] ?? 'right',
      'unit_scale': get('unit_scale', 0.35),
      'unit_dx': get('unit_dx', 0.0),
      'unit_dy': get('unit_dy', 0.0),
      'unit_color': elem['unit_color'] ?? '',
      'unit_orientation': elem['unit_orientation'] ?? 'horizontal',
      // arc / segment bar
      'thickness': get('thickness', 12),
      'start_angle': get('start_angle', 135),
      'sweep': get('sweep', 270),
      'range_min': get('range_min', 0),
      'range_max': get('range_max', 100),
      'track_color': truthy(elem['track_color'])
          ? elem['track_color']
          : '#303030',
      'color_mode': elem['color_mode'] == 'position' ? 'position' : 'value',
      // a text element's own box behind it ("" = none)
      'box_color': truthy(elem['box_color']) ? elem['box_color'] : '',
    };
  }

  /// An inspector edit: numbers arrive as text and are read here; a
  /// default is kept as the key's absence.
  ///
  /// [element] is the element the edit was made for (the inspector's, when
  /// its field is left after another element was picked); the selected
  /// one by default.
  void setSelectedAttr(String key, Object? value, {int? element}) {
    final doc = document;
    final index = element ?? _selectedIndex;
    if (doc == null || doc.element(index) == null) {
      return;
    }
    // "nan" and "inf" read as numbers in Python too; neither is kept.
    double? number(Object? v) {
      final n = v is num ? v.toDouble() : pyFloat('${v ?? ''}'.trim());
      return n != null && n.isFinite ? n : null;
    }

    bool flag(Object? v) => v is bool ? v : truthy(v);
    void set(String k, Object? v) => doc.setElementAttr(index, k, v);
    switch (key) {
      case 'x_px' || 'y_px':
        final n = number(value);
        if (n == null) {
          notifyListeners();
          return;
        }
        final (x, y) = doc.elementPositionPx(index);
        doc.setElementPositionPx(
          index,
          key == 'x_px' ? n : x,
          key == 'y_px' ? n : y,
        );
      case 'custom_text':
        set('field', 'custom:${value ?? ''}');
      case 'bold':
        set('font_weight', flag(value) ? 'bold' : null);
      case 'font_family':
        set(
          'font_family',
          value == null || value == '' || value == defaultFontFamily
              ? null
              : '$value',
        );
      case 'align' || 'valign' || 'outline':
        var v = value;
        if (key == 'outline') {
          v = flag(value);
        } else if ((key == 'align' && !alignOptions.contains(value)) ||
            (key == 'valign' && !valignOptions.contains(value))) {
          return;
        }
        set(key, v == _elementAttrDefaults[key] ? null : v);
      case _ when _numericElementAttrs.contains(key):
        var n = number(value);
        if (n == null) {
          notifyListeners();
          return;
        }
        if (_intElementAttrs.contains(key)) {
          n = pyRound(n).toDouble();
        }
        switch (key) {
          case 'font_size' ||
              'value_font_size' ||
              'caption_font_size' ||
              'width' ||
              'height' ||
              'marker_size' ||
              'outline_width':
            n = math.max(1, n);
          case 'outline_gap' || 'up_count' || 'down_count' || 'segment_gap':
            n = math.max(0, n);
          case 'segments' || 'full_bar':
            n = math.max(1, n);
          case 'scale':
            n = math.max(0.05, n);
          case 'max_width':
            n = math.max(0, n);
            if (n == 0) {
              set(key, null);
              _update();
              return;
            }
          case 'small_suffix_scale':
            n = pyRoundTo(n, 3).clamp(0.1, 1.0);
          case 'unit_scale':
            n = pyRoundTo(n, 3).clamp(0.1, 1.5);
          case 'unit_dx' || 'unit_dy':
            n = pyRoundTo(n, 1);
          case 'fill_opacity' ||
              'stops_opacity' ||
              'ceiling_opacity' ||
              'background_opacity':
            n = pyRoundTo(n, 3).clamp(0.0, 1.0);
        }
        set(key, _intElementAttrs.contains(key) ? n.toInt() : n);
      case 'confirm_text':
        set('confirm_text', '${value ?? ''}');
      case 'hide_when_notice' ||
          'hide_when_switch' ||
          'fill_level' ||
          'unit_suffix' ||
          'draw_outline' ||
          'reveal_profile' ||
          'stop_label':
        set(key, flag(value) ? true : null);
      case 'unit_position':
        set(key, value == 'below' ? 'below' : null);
      case 'unit_orientation':
        set(key, value == 'stacked' ? 'stacked' : null);
      case 'unit_color' || 'box_color' || 'track_color':
        set(key, truthy(value) ? '$value' : null);
      case 'color_mode':
        set(key, value == 'position' ? 'position' : null);
      case 'source':
        set(key, value == 'persistent' ? 'persistent' : null);
      case 'field' ||
          'color' ||
          'ceiling_color' ||
          'marker_style' ||
          'outline_color' ||
          'fill_color' ||
          'background_color' ||
          'caption_color':
        if (key == 'marker_style' && !markerStyles.contains(value)) {
          return;
        }
        set(key, '$value');
      case 'deco_stops':
        set('stops_color', flag(value) ? defaultStopsColor : null);
      case 'stops_color':
        set('stops_color', '$value');
      case 'style':
        if (!const [
          'segments',
          'fill',
          'text',
          'banner',
          'box',
          'frame',
        ].contains(value)) {
          return;
        }
        final fallback =
            _styleDefaults[elementKind(doc.element(index)!)] ?? 'segments';
        set('style', value == fallback ? null : value);
      case 'label':
        final text = '${value ?? ''}'.trim();
        set('label', text.isEmpty ? null : text);
      case 'small_suffix':
        final style = '${value ?? ''}';
        if (style.isNotEmpty && !smallSuffixStyles.contains(style)) {
          return;
        }
        set('small_suffix', style.isEmpty ? null : style);
      case 'bar':
        set('bar', flag(value) ? null : false);
      case 'orientation':
        if (!textOrientations.contains(value)) {
          return;
        }
        set('orientation', value == 'horizontal' ? null : '$value');
      default:
        return;
    }
    _update();
  }

  /// The skin's attributes for the inspector.
  Map<String, Object?> get skinAttrs {
    final doc = document;
    if (doc == null) {
      return {'type': ''};
    }
    final skin = doc.skin;
    final (nw, nh) = doc.skinNativeSize();
    final anchor = skin['anchor'] ?? 'TOP_LEFT';
    return {
      'type': doc.skinType,
      'native_width': nw,
      'native_height': nh,
      'path': doc.skinAbsPath ?? '',
      'scale': skin['scale'] ?? 1.0,
      'opacity': skin['opacity'] ?? 1.0,
      'anchor': anchor,
      'ref_offset_x': skin['ref_offset_x'] ?? 0.0,
      'ref_offset_y': skin['ref_offset_y'] ?? 0.0,
      'width': skin['width'] ?? 400,
      'height': skin['height'] ?? 200,
      'color': skin['color'] ?? '#000000',
      'corner_radius': skin['corner_radius'] ?? 20,
    };
  }

  /// The anchors as the inspector names them.
  Map<String, String> get anchorChoices => {
    for (final a in anchors) _prettify(a): a,
  };

  void setSkinAttr(String key, Object? value) {
    final doc = document;
    if (doc == null) {
      return;
    }
    if (key == 'anchor') {
      final anchor = anchorChoices['$value'] ?? value;
      if (!anchors.contains(anchor)) {
        return;
      }
      doc.setSkinAttr('anchor', anchor);
    } else if (_numericSkinAttrs.contains(key)) {
      var n = value is num
          ? value.toDouble()
          : pyFloat('${value ?? ''}'.trim());
      if (n == null || !n.isFinite) {
        notifyListeners();
        return;
      }
      if (_intSkinAttrs.contains(key)) {
        n = pyRound(n).toDouble();
      }
      if (key == 'scale') {
        n = math.max(0.05, n);
      } else if (key == 'opacity') {
        n = n.clamp(0.0, 1.0);
      } else if (key == 'width' || key == 'height') {
        n = math.max(1, n);
      }
      doc.setSkinAttr(key, _intSkinAttrs.contains(key) ? n.toInt() : n);
    } else if (key == 'color') {
      doc.setSkinAttr('color', '$value');
    } else {
      return;
    }
    if (const {'scale', 'width', 'height'}.contains(key)) {
      _afterGeometryEdit();
    } else {
      _update();
    }
  }

  /// The folder an image was picked in, for the next image dialog.
  void rememberImageDir(String path) {
    try {
      config.rememberDialogDir(imageDirField, p.dirname(path));
    } on FileSystemException {
      // Only not kept.
    }
  }

  /// Points an image skin at a picture of the user's; false when it
  /// cannot be read.
  bool replaceSkinImage(String path) {
    final doc = document;
    if (doc == null) {
      return false;
    }
    rememberImageDir(path);
    final (oldW, oldH) = doc.skinNativeSize();
    if (!doc.setSkinImage(path)) {
      _setStatus('Could not read image: $path');
      return false;
    }
    final (newW, newH) = doc.skinNativeSize();
    var message =
        'Skin image replaced: ${p.basename(path)} (copied next to the '
        'template on Save)';
    if (oldW > 0 &&
        oldH > 0 &&
        newW > 0 &&
        newH > 0 &&
        (oldW / oldH - newW / newH).abs() > 0.02) {
      message +=
          ' - aspect ratio changed (${pyFormatFixed(oldW, 0)}×${pyFormatFixed(oldH, 0)} → '
          '${pyFormatFixed(newW, 0)}×${pyFormatFixed(newH, 0)}); element '
          'positions are proportional, so check their placement.';
    }
    status = message;
    _afterGeometryEdit();
    return true;
  }

  // -- options for the inspector -----------------------------------------------

  Dive get _fieldsDive => telemetrySource == sourceLog && currentDive != null
      ? currentDive!
      : dummyDive;

  List<String> get availableFields {
    final fields = [
      for (final f in availableTelemetryFields(_fieldsDive))
        if (f != 'timestamp' && f != 'dive_alerts') f,
    ];
    for (final extra in const [
      'ndl_before_clear',
      'depth_graph',
      'state_badge',
    ]) {
      if (!fields.contains(extra)) {
        fields.add(extra);
      }
    }
    return fields;
  }

  /// [availableFields] with the presets right after their fields.
  List<String> get addableFields {
    final fields = availableFields;
    addElementPresets.forEach((preset, entry) {
      final at = fields.indexOf(entry.$1);
      if (at >= 0) {
        fields.insert(at + 1, preset);
      }
    });
    return fields;
  }

  List<String> get fontFamilies => listFontFamilies();

  // -- structural edits ---------------------------------------------------------

  void addElement(String field, String kind) {
    final doc = document;
    if (doc == null || field.isEmpty) {
      return;
    }
    if (!addableKinds.contains(kind)) {
      kind = 'text';
    }
    var name = switch (kind) {
      'graph' => 'depth_graph',
      'notice' => 'notice',
      'badge' => 'state_badge',
      'tissue_bar' => 'n2_tissue_load',
      'ascent_chevrons' => 'ascent_rate',
      'tank_switch_arrows' => 'tank_switch',
      _ => field,
    };
    var attrs = <String, dynamic>{};
    if (kind == 'ascent_chevrons') {
      // The brand's own indicator over the Garmin defaults (hud_rules.json
      // alone, as in Python: not the page's own rule overrides).
      final rule = renderer.rules.getRuleConfig(
        doc.rulesManufacturer,
        doc.model,
        'ascent_chevrons',
      );
      if (rule is Map) {
        for (final key in const ['up_count', 'down_count']) {
          if (rule[key] is num) {
            attrs[key] = (rule[key] as num).truncate();
          }
        }
        if (rule['bar'] == false) {
          attrs['bar'] = false;
        }
      }
    }
    final preset = addElementPresets[name];
    if (preset != null) {
      name = preset.$1;
      if (kind == 'text') {
        attrs = {
          'small_suffix': preset.$2,
          'small_suffix_scale': smallSuffixDefaultScale,
        };
      }
    }
    final index = doc.addElement(name, kind: kind, attrs: attrs);
    _hidden = {};
    _setPrimary(index);
    _skinSelected = false;
    _update();
  }

  void addCustomLabel(String text) {
    final t = text.trim();
    if (t.isNotEmpty) {
      addElement('custom:$t', 'text');
    }
  }

  void removeSelected() {
    final doc = document;
    final selection = _selection();
    if (doc == null || selection.isEmpty) {
      return;
    }
    doc.pushUndo();
    for (final index in selection.reversed) {
      doc.elements.removeAt(index);
    }
    _hidden = {};
    _setPrimary(math.min(selection.first, doc.elements.length - 1));
    _update();
  }

  void _addClones(List<Map<String, dynamic>> sources) {
    final doc = document!;
    doc.pushUndo();
    final start = doc.elements.length;
    for (final source in sources) {
      final clone = asNewElement(source);
      clone['rel_x'] = math.min(
        1.5,
        ((clone['rel_x'] as num?) ?? 0).toDouble() + 0.02,
      );
      clone['rel_y'] = math.min(
        1.5,
        ((clone['rel_y'] as num?) ?? 0).toDouble() + 0.02,
      );
      doc.elements.add(clone);
    }
    _hidden = {};
    _selected = {for (var i = start; i < doc.elements.length; i++) i};
    _selectedIndex = doc.elements.length - 1;
    _skinSelected = false;
    _update();
  }

  void duplicateSelected() {
    final doc = document;
    final selection = _selection();
    if (doc == null || selection.isEmpty) {
      return;
    }
    _addClones([for (final i in selection) doc.elements[i]]);
  }

  void moveSelectedLayer(int delta) {
    final doc = document;
    if (doc == null || doc.element(_selectedIndex) == null) {
      return;
    }
    final next = doc.reorderElement(_selectedIndex, delta);
    _hidden = {};
    _setPrimary(next);
    _update();
  }

  void bringToFront() => moveSelectedLayer(document?.elements.length ?? 0);

  void sendToBack() => moveSelectedLayer(-(document?.elements.length ?? 0));

  double _rel(Map<String, dynamic> elem, String key) =>
      ((elem[key] as num?) ?? 0).toDouble();

  /// Arrow keys: the selection by [dx], [dy] skin pixels; in Frame
  /// preview with the skin selected, the skin on the frame.
  void nudgeSelected(int dx, int dy) {
    final doc = document;
    if (doc == null) {
      return;
    }
    final selection = _selection();
    if (selection.isNotEmpty) {
      final (nw, nh) = doc.skinNativeSize();
      if (nw <= 0 || nh <= 0) {
        return;
      }
      doc.pushUndo();
      for (final index in selection) {
        final elem = doc.elements[index];
        doc.moveElement(
          index,
          _rel(elem, 'rel_x') + dx / nw,
          _rel(elem, 'rel_y') + dy / nh,
          recordUndo: false,
        );
      }
    } else if (_skinSelected && viewMode == viewFrame) {
      final (x, y, _, _) = doc.frameBox(viewW, viewH);
      doc.setFramePosition(x + dx, y + dy, viewW, viewH);
    } else {
      return;
    }
    _update();
  }

  /// Aligns the selection's boxes to the primary element (else to the
  /// selection's outer edge): left, hcenter, right, top, vcenter, bottom.
  void alignSelected(String mode) {
    final doc = document;
    final selection = _selection();
    if (doc == null || selection.length < 2) {
      return;
    }
    final (nw, nh) = doc.skinNativeSize();
    if (nw <= 0 || nh <= 0) {
      return;
    }
    final bounds = _allNativeBounds();
    final boxes = {for (final i in selection) i: bounds[i]};
    final anchor = boxes[_selectedIndex];
    double edge(int lo, int hi, String pick) {
      double at(_NativeBox b, int i) => [b.$1, b.$2, b.$3, b.$4][i];
      if (anchor != null) {
        return pick == 'lo'
            ? at(anchor, lo)
            : pick == 'hi'
            ? at(anchor, hi)
            : (at(anchor, lo) + at(anchor, hi)) / 2;
      }
      final los = boxes.values.map((b) => at(b, lo));
      final his = boxes.values.map((b) => at(b, hi));
      return pick == 'lo'
          ? los.reduce(math.min)
          : pick == 'hi'
          ? his.reduce(math.max)
          : (los.reduce(math.min) + his.reduce(math.max)) / 2;
    }

    final Map<int, (double, double)> deltas;
    switch (mode) {
      case 'left':
        final t = edge(0, 2, 'lo');
        deltas = {
          for (final MapEntry(:key, :value) in boxes.entries)
            key: (t - value.$1, 0.0),
        };
      case 'right':
        final t = edge(0, 2, 'hi');
        deltas = {
          for (final MapEntry(:key, :value) in boxes.entries)
            key: (t - value.$3, 0.0),
        };
      case 'hcenter':
        final t = edge(0, 2, 'mid');
        deltas = {
          for (final MapEntry(:key, :value) in boxes.entries)
            key: (t - (value.$1 + value.$3) / 2, 0.0),
        };
      case 'top':
        final t = edge(1, 3, 'lo');
        deltas = {
          for (final MapEntry(:key, :value) in boxes.entries)
            key: (0.0, t - value.$2),
        };
      case 'bottom':
        final t = edge(1, 3, 'hi');
        deltas = {
          for (final MapEntry(:key, :value) in boxes.entries)
            key: (0.0, t - value.$4),
        };
      case 'vcenter':
        final t = edge(1, 3, 'mid');
        deltas = {
          for (final MapEntry(:key, :value) in boxes.entries)
            key: (0.0, t - (value.$2 + value.$4) / 2),
        };
      default:
        return;
    }
    _applyDeltas(deltas);
  }

  /// Every selected element about 5 % a step bigger or smaller.
  void resizeSelected(int steps) {
    final doc = document;
    final selection = _selection();
    if (doc == null || selection.isEmpty || steps == 0) {
      return;
    }
    final factor = math.pow(1.05, steps).toDouble();
    doc.pushUndo();
    int grow(num current) {
      var grown = current * factor;
      if ((grown - current).abs() < 1.0) {
        grown = current + (steps > 0 ? 1.0 : -1.0);
      }
      return math.max(1, pyRound(grown));
    }

    for (final index in selection) {
      final elem = doc.elements[index];
      final kind = elementKind(elem);
      const sized = {
        'tank_icon': (20, 30),
        'graph': (300, 150),
        'tissue_bar': (12, 33),
        'ascent_chevrons': (16, 47),
        'arc': (120, 120),
        'segment_bar': (12, 60),
      };
      final defaults = sized[kind];
      if (defaults != null) {
        elem['width'] = grow((elem['width'] as num?) ?? defaults.$1);
        elem['height'] = grow((elem['height'] as num?) ?? defaults.$2);
      } else {
        for (final key in const ['font_size', 'value_font_size']) {
          if (elem.containsKey(key) || key == 'font_size') {
            elem[key] = grow((elem[key] as num?) ?? 16);
          }
        }
      }
    }
    _update();
  }

  /// Even gaps between three or more selected elements' boxes, across
  /// ('h') or down ('v').
  void distributeSelected(String axis) {
    final doc = document;
    final selection = _selection();
    if (doc == null || selection.length < 3) {
      return;
    }
    final (nw, nh) = doc.skinNativeSize();
    if (nw <= 0 || nh <= 0) {
      return;
    }
    final bounds = _allNativeBounds();
    double lo(_NativeBox b) => axis == 'h' ? b.$1 : b.$2;
    double hi(_NativeBox b) => axis == 'h' ? b.$3 : b.$4;
    final ordered = [...selection]
      ..sort((a, b) => lo(bounds[a]).compareTo(lo(bounds[b])));
    final span = hi(bounds[ordered.last]) - lo(bounds[ordered.first]);
    final total = ordered
        .map((i) => hi(bounds[i]) - lo(bounds[i]))
        .fold(0.0, (a, b) => a + b);
    final gap = (span - total) / (ordered.length - 1);
    final deltas = <int, (double, double)>{};
    var cursor = lo(bounds[ordered.first]);
    for (final i in ordered) {
      final delta = cursor - lo(bounds[i]);
      deltas[i] = axis == 'h' ? (delta, 0.0) : (0.0, delta);
      cursor += hi(bounds[i]) - lo(bounds[i]) + gap;
    }
    _applyDeltas(deltas);
  }

  void _applyDeltas(Map<int, (double, double)> deltas) {
    final doc = document!;
    final (nw, nh) = doc.skinNativeSize();
    if (!deltas.values.any((d) => d.$1.abs() > 1e-6 || d.$2.abs() > 1e-6)) {
      return;
    }
    doc.pushUndo();
    deltas.forEach((index, d) {
      final elem = doc.elements[index];
      doc.moveElement(
        index,
        _rel(elem, 'rel_x') + d.$1 / nw,
        _rel(elem, 'rel_y') + d.$2 / nh,
        recordUndo: false,
      );
    });
    _update();
  }

  // The clipboard lives here, so a copy pastes into another page too.
  List<Map<String, dynamic>> _clipboard = [];

  bool get canPaste => _clipboard.isNotEmpty;

  void copySelected() {
    final doc = document;
    final selection = _selection();
    if (doc == null || selection.isEmpty) {
      return;
    }
    _clipboard = [for (final i in selection) jsonCopyMap(doc.elements[i])];
    notifyListeners();
  }

  void cutSelected() {
    copySelected();
    removeSelected();
  }

  void paste() {
    if (document == null || _clipboard.isEmpty) {
      return;
    }
    _addClones(_clipboard);
  }

  bool get canUndo => document?.canUndo ?? false;
  bool get canRedo => document?.canRedo ?? false;
  bool get isDirty => document?.dirty ?? false;

  void undo() {
    final doc = document;
    if (doc == null || !doc.undo()) {
      return;
    }
    _hidden = {};
    _sanitizeSelection();
    _afterGeometryEdit();
  }

  void redo() {
    final doc = document;
    if (doc == null || !doc.redo()) {
      return;
    }
    _hidden = {};
    _sanitizeSelection();
    _afterGeometryEdit();
  }

  // -- canvas geometry -------------------------------------------------------------

  double viewW = frameW.toDouble();
  double viewH = frameH.toDouble();

  // display = offset + native * k
  (double, double, double) _transform() {
    final doc = document;
    if (doc == null || viewMode == viewDesign) {
      return (0, 0, _zoom);
    }
    final (sx, sy, wHud, _) = doc.frameBox(viewW, viewH);
    final (nw, _) = doc.skinNativeSize();
    final k = nw > 0 ? wHud / nw : 1.0;
    return (sx * _zoom, sy * _zoom, k * _zoom);
  }

  (double, double) _displayToNative(double x, double y) {
    final (ox, oy, k) = _transform();
    return k == 0 ? (0, 0) : ((x - ox) / k, (y - oy) / k);
  }

  DisplayBox _toDisplay(_NativeBox b) {
    final (ox, oy, k) = _transform();
    return (
      ox + b.$1 * k,
      oy + b.$2 * k,
      math.max(1, (b.$3 - b.$1) * k),
      math.max(1, (b.$4 - b.$2) * k),
    );
  }

  u.UnitSystem get _settingsUnits =>
      u.normalizeUnits(config.settings()['units']);

  /// The unit system the canvas shows: the page's own choice, else the
  /// Advanced setting.
  u.UnitSystem get units => _previewUnits ?? _settingsUnits;
  u.UnitSystem? _previewUnits;

  List<_NativeBox> _allNativeBounds() {
    final doc = document;
    if (doc == null) {
      return const [];
    }
    final (wp, waypoints) = telemetryForRender();
    final (nw, nh) = doc.skinNativeSize();
    final ctx = HudContext.of(doc.layout, renderer.rules, units);
    final designer = HudDesigner(renderer);
    return [
      for (final elem in doc.elements)
        _boundsOf(designer, ctx, elem, wp, waypoints, nw, nh),
    ];
  }

  _NativeBox _boundsOf(
    HudDesigner designer,
    HudContext ctx,
    Map<String, dynamic> elem,
    Waypoint? wp,
    List<Waypoint>? waypoints,
    double nw,
    double nh,
  ) {
    try {
      final kind = elementKind(elem);
      String? text;
      List<BadgeLine>? lines;
      if (kind == 'text') {
        final (value, raw) = resolveElementText(
          ctx,
          '${elem['field'] ?? ''}',
          wp,
          waypoints,
        );
        text = value == null || value.isEmpty
            ? null
            : applyValueFormat(elem, value, raw, ctx.units);
      } else if (kind == 'badge') {
        lines = badgeLines(ctx, elem, wp, waypoints);
      }
      return designer.elementNativeBounds(
        elem,
        nw,
        nh,
        text: text,
        badgeLines: lines,
        units: ctx.units,
      );
    } on Object {
      final x = _rel(elem, 'rel_x') * nw;
      final y = _rel(elem, 'rel_y') * nh;
      return (x, y, x + 10, y + 10);
    }
  }

  List<DisplayBox> elementBoxes = const [];
  DisplayBox? selectionBox;
  String selectionLabel = '';
  bool showBounds = true;

  List<DisplayBox> get secondarySelectionBoxes => [
    for (final i in _selection())
      if (i != _selectedIndex && i < elementBoxes.length) elementBoxes[i],
  ];

  DisplayBox? get marqueeBox {
    final m = _marquee;
    if (m == null) {
      return null;
    }
    return _toDisplay((
      math.min(m.$1, m.$3),
      math.min(m.$2, m.$4),
      math.max(m.$1, m.$3),
      math.max(m.$2, m.$4),
    ));
  }

  void _updateBoxes() {
    final doc = document;
    if (doc == null) {
      elementBoxes = const [];
      selectionBox = null;
      selectionLabel = '';
      return;
    }
    elementBoxes = [for (final b in _allNativeBounds()) _toDisplay(b)];
    if (_selectedIndex >= 0 && _selectedIndex < elementBoxes.length) {
      selectionBox = elementBoxes[_selectedIndex];
      final count = _selection().length;
      selectionLabel =
          elementLabel(doc.elements[_selectedIndex]) +
          (count > 1 ? '  (+${count - 1})' : '');
    } else if (_skinSelected) {
      final (nw, nh) = doc.skinNativeSize();
      selectionBox = _toDisplay((0, 0, nw, nh));
      selectionLabel = 'Skin';
    } else {
      selectionBox = null;
      selectionLabel = '';
    }
  }

  void setShowBounds(bool value) {
    showBounds = value;
    notifyListeners();
  }

  bool showGrid = false;
  bool snapEnabled = false;
  int gridSize = defaultGridSize;

  void setShowGrid(bool value) {
    showGrid = value;
    _redraw();
    notifyListeners();
  }

  void setSnapEnabled(bool value) {
    snapEnabled = value;
    notifyListeners();
  }

  void setGridSize(int value) {
    if (value < 1 || value == gridSize) {
      return;
    }
    gridSize = value;
    if (showGrid) {
      _redraw();
    }
    notifyListeners();
  }

  // A proposed move of element [index] adjusted so its anchor lands on the
  // grid and its edges line up with other elements', within the tolerance.
  (double, double) _snapDelta(
    int index,
    double dx,
    double dy,
    List<_NativeBox> bounds,
  ) {
    if (!snapEnabled) {
      return (dx, dy);
    }
    final doc = document!;
    final (nw, nh) = doc.skinNativeSize();
    final elem = doc.elements[index];
    final ax = _rel(elem, 'rel_x') * nw + dx;
    final ay = _rel(elem, 'rel_y') * nh + dy;
    double? bestX;
    double? bestY;
    final g = gridSize.toDouble();
    final gx = pyRound(ax / g) * g;
    final gy = pyRound(ay / g) * g;
    if ((gx - ax).abs() <= snapTolerancePx) {
      bestX = gx - ax;
    }
    if ((gy - ay).abs() <= snapTolerancePx) {
      bestY = gy - ay;
    }
    final b = bounds[index];
    final moved = (b.$1 + dx, b.$2 + dy, b.$3 + dx, b.$4 + dy);
    final mineX = [moved.$1, (moved.$1 + moved.$3) / 2, moved.$3];
    final mineY = [moved.$2, (moved.$2 + moved.$4) / 2, moved.$4];
    for (final (j, other) in bounds.indexed) {
      if (_selected.contains(j) || _hidden.contains(j)) {
        continue;
      }
      for (final ox in [other.$1, (other.$1 + other.$3) / 2, other.$3]) {
        for (final mx in mineX) {
          final d = ox - mx;
          if (d.abs() <= snapTolerancePx &&
              (bestX == null || d.abs() < bestX.abs())) {
            bestX = d;
          }
        }
      }
      for (final oy in [other.$2, (other.$2 + other.$4) / 2, other.$4]) {
        for (final my in mineY) {
          final d = oy - my;
          if (d.abs() <= snapTolerancePx &&
              (bestY == null || d.abs() < bestY.abs())) {
            bestY = d;
          }
        }
      }
    }
    return (dx + (bestX ?? 0), dy + (bestY ?? 0));
  }

  _Drag? _drag;

  /// Whether a press on the canvas is being followed (a drag, a marquee or
  /// a click to finish on release).
  bool get pressing => _drag != null;
  (double, double, double, double)? _marquee;

  /// A press on the canvas at display ([x], [y]); [toggle] for Cmd/Ctrl/
  /// Shift: an element in or out of the selection. A plain press on a
  /// selected element starts a group drag; on empty skin a marquee (Design
  /// view) or a skin drag (Frame preview).
  void press(double x, double y, {bool toggle = false}) {
    final doc = document;
    _drag = null;
    _marquee = null;
    if (doc == null) {
      return;
    }
    final (nx, ny) = _displayToNative(x, y);
    final (_, _, k) = _transform();
    final slack = k != 0 ? hitSlackDisplayPx / k : 2.0;
    final bounds = _allNativeBounds();
    final hittable = [
      for (final (i, b) in bounds.indexed)
        _hidden.contains(i) ? (1e9, 1e9, 1e9, 1e9) : b,
    ];
    final hit = hitTestBounds(nx, ny, hittable, slack: slack);
    if (hit != null) {
      _skinSelected = false;
      if (toggle) {
        toggleElement(hit);
        return;
      }
      if (!_selected.contains(hit)) {
        _setPrimary(hit);
      } else {
        _selectedIndex = hit;
      }
      _drag = _Drag.element(hit, nx, ny, {
        for (final i in _selection())
          i: (_rel(doc.elements[i], 'rel_x'), _rel(doc.elements[i], 'rel_y')),
      }, bounds);
    } else {
      final (nw, nh) = doc.skinNativeSize();
      final onSkin = nx >= 0 && nx <= nw && ny >= 0 && ny <= nh;
      if (toggle) {
        return;
      }
      if (onSkin && viewMode == viewFrame) {
        _setPrimary(-1);
        _skinSelected = true;
        final (sx, sy, _, _) = doc.frameBox(viewW, viewH);
        _drag = _Drag.skin(x, y, sx, sy);
      } else {
        _drag = _Drag.marquee(nx, ny, onSkin, bounds);
        _setPrimary(-1);
        _skinSelected = false;
      }
    }
    _selectionChanged();
  }

  void drag(double x, double y) {
    final d = _drag;
    final doc = document;
    if (d == null || doc == null) {
      return;
    }
    if (d.mode == 'marquee') {
      final (nx, ny) = _displayToNative(x, y);
      d.moved = true;
      _marquee = (d.startNx, d.startNy, nx, ny);
      notifyListeners();
      return;
    }
    if (!d.pushed) {
      final still = d.mode == 'skin'
          ? x == d.startX && y == d.startY
          : _displayToNative(x, y) == (d.startNx, d.startNy);
      if (still) {
        return;
      }
      doc.pushUndo();
      d.pushed = true;
    }
    if (d.mode == 'element') {
      final (nx, ny) = _displayToNative(x, y);
      final (nw, nh) = doc.skinNativeSize();
      if (nw <= 0 || nh <= 0) {
        return;
      }
      var dxPx = nx - d.startNx;
      var dyPx = ny - d.startNy;
      // Snapped on the primary; the group follows by the same amount.
      final (ox, oy) = d.orig[d.index]!;
      final elem = doc.elements[d.index];
      final curDx = (ox * nw + dxPx) - _rel(elem, 'rel_x') * nw;
      final curDy = (oy * nh + dyPx) - _rel(elem, 'rel_y') * nh;
      final (sdx, sdy) = _snapDelta(
        d.index,
        curDx,
        curDy,
        snapEnabled ? _allNativeBounds() : d.bounds,
      );
      dxPx += sdx - curDx;
      dyPx += sdy - curDy;
      d.orig.forEach((index, rel) {
        if (doc.element(index) != null) {
          doc.moveElement(
            index,
            rel.$1 + dxPx / nw,
            rel.$2 + dyPx / nh,
            recordUndo: false,
          );
        }
      });
    } else {
      final zoom = _zoom == 0 ? 1.0 : _zoom;
      doc.setFramePosition(
        d.origFx + (x - d.startX) / zoom,
        d.origFy + (y - d.startY) / zoom,
        viewW,
        viewH,
        recordUndo: false,
      );
    }
    _updateBoxes();
    notifyListeners();
  }

  void release() {
    final d = _drag;
    _drag = null;
    if (d == null) {
      return;
    }
    if (d.mode == 'marquee') {
      final m = _marquee;
      _marquee = null;
      if (m == null || !d.moved) {
        // A plain click: the skin (or nothing off it).
        _setPrimary(-1);
        _skinSelected = d.onSkin;
      } else {
        final x0 = math.min(m.$1, m.$3);
        final x1 = math.max(m.$1, m.$3);
        final y0 = math.min(m.$2, m.$4);
        final y1 = math.max(m.$2, m.$4);
        final picked = [
          for (final (i, b) in d.bounds.indexed)
            if (!_hidden.contains(i) &&
                b.$3 >= x0 &&
                b.$1 <= x1 &&
                b.$4 >= y0 &&
                b.$2 <= y1)
              i,
        ];
        _selected = picked.toSet();
        _selectedIndex = picked.isEmpty ? -1 : picked.last;
        _skinSelected = false;
      }
      _selectionChanged();
      return;
    }
    if (d.pushed) {
      _update();
    }
  }

  // -- view mode and zoom -------------------------------------------------------------

  String viewMode = viewDesign;
  double _zoom = 1.0;
  bool _zoomFit = true;
  (double, double) _viewport = defaultViewport;

  double get zoom => _zoom;
  int get zoomPercent => pyRound(_zoom * 100);
  bool get zoomIsFit => _zoomFit;

  void setViewMode(String mode) {
    if (!const [viewDesign, viewFrame].contains(mode) || mode == viewMode) {
      return;
    }
    viewMode = mode;
    _zoomFit = true;
    _applyFitZoom();
    _drag = null;
    _update();
  }

  (double, double) get _nativeCanvasSize {
    if (viewMode == viewDesign) {
      final doc = document;
      if (doc != null) {
        final (w, h) = doc.skinNativeSize();
        if (w > 0 && h > 0) {
          return (w, h);
        }
      }
      return (400, 200);
    }
    return (viewW, viewH);
  }

  double _fitZoom() {
    final (w, h) = _nativeCanvasSize;
    if (w <= 0 || h <= 0) {
      return 1.0;
    }
    return _clampZoom(math.min(_viewport.$1 / w, _viewport.$2 / h));
  }

  void _applyFitZoom() {
    if (_zoomFit) {
      _zoom = _fitZoom();
    }
  }

  void _setZoom(double value) {
    _zoomFit = false;
    _zoom = _clampZoom(value);
    _update();
  }

  void setZoomPercent(int percent) => _setZoom(percent / 100);

  void zoomIn() => _setZoom((pyRound(_zoom / zoomStep) + 1) * zoomStep);

  void zoomOut() => _setZoom((pyRound(_zoom / zoomStep) - 1) * zoomStep);

  void zoomFit() {
    _zoomFit = true;
    _applyFitZoom();
    _update();
  }

  /// The canvas's viewport resized: Fit follows it.
  void setViewportSize(double width, double height) {
    if (fitViewport(width, height)) {
      _update();
    }
  }

  /// The screen's pixels to a logical pixel: the design view is drawn at
  /// as many pixels as the screen shows it with, so that a display scaled
  /// to 125 or 150 % (Windows) does not blow it up from fewer pixels.
  double get pixelRatio => _pixelRatio;
  double _pixelRatio = 1.0;

  /// [pixelRatio] from the page's layout; true when it changed (the caller
  /// then calls [viewportFitted] after the frame to draw again).
  bool setPixelRatio(double ratio) {
    final next = ratio.isFinite && ratio > 0 ? ratio : 1.0;
    if (next == _pixelRatio) {
      return false;
    }
    _pixelRatio = next;
    return true;
  }

  /// [setViewportSize] from inside the canvas's own layout: the zoom and the
  /// element boxes follow the viewport at once, so the canvas laid out next
  /// is already at the new size, and no listener is told. True when the zoom
  /// changed; the caller then calls [viewportFitted] after the frame.
  bool fitViewport(double width, double height) {
    // Whole pixels, as Python's int().
    final size = (
      math.max(1.0, width.truncateToDouble()),
      math.max(1.0, height.truncateToDouble()),
    );
    if (size == _viewport) {
      return false;
    }
    _viewport = size;
    if (!_zoomFit) {
      return false;
    }
    final before = _zoom;
    _applyFitZoom();
    if (before == _zoom) {
      return false;
    }
    _updateBoxes();
    return true;
  }

  /// After [fitViewport] changed the zoom: the picture is redrawn at it and
  /// the rest of the page (the zoom percent, the status) told.
  void viewportFitted() => _update();

  int get canvasDisplayWidth =>
      math.max(1, pyRound(_nativeCanvasSize.$1 * _zoom));
  int get canvasDisplayHeight =>
      math.max(1, pyRound(_nativeCanvasSize.$2 * _zoom));

  // -- the canvas picture -----------------------------------------------------------

  ui.Image? canvasImage;
  int _renderTicket = 0;

  /// A background picture for Frame preview (set by the background
  /// loader); `null` for the synthetic one.
  ui.Image? background;

  Future<void> _lastRender = Future.value();

  /// Done when the latest picture asked for is drawn (or given up for a
  /// later one).
  Future<void> get rendered => _lastRender;

  void _redraw() => unawaited(_lastRender = _render());

  Future<HudSkinPixels?> _skinPixels(Map<String, dynamic> layout) async {
    final skin = layout['hud_skin'];
    final path = skin is Map ? skin['path'] : null;
    if (path is! String || path.isEmpty || (skin as Map)['type'] == 'shape') {
      return null;
    }
    if (_skins.containsKey(path)) {
      return _skins[path];
    }
    final bytes = _readBytesSync(path) ?? await templateBytes(path);
    final pixels = await PhotoRun.skinOf(
      HudLayerSource(layout, skinBytes: bytes),
    );
    // A skin that could not be read is tried again next time.
    if (pixels != null) {
      _skins[path] = pixels;
    }
    return pixels;
  }

  Future<void> _render() async {
    if (_disposed) {
      return;
    }
    final doc = document;
    final ticket = ++_renderTicket;
    if (doc == null) {
      _setCanvas(null);
      return;
    }
    final (wp, waypoints) = telemetryForRender();
    final run = PhotoRun(renderer: renderer, painter: painter, units: units);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    // The picture's size even when the renderer stumbles.
    var width = canvasDisplayWidth;
    var height = canvasDisplayHeight;
    try {
      if (viewMode == viewDesign) {
        final (nw, nh) = _nativeCanvasSize;
        // In the screen's own pixels (pixelRatio), the page showing it at
        // canvasDisplayWidth logical pixels.
        var zoom = _zoom * _pixelRatio;
        if (nw * zoom > maxRenderWidth) {
          zoom = maxRenderWidth / nw;
        }
        width = math.max(1, pyRound(nw * zoom));
        height = math.max(1, pyRound(nh * zoom));
        _checkerboard(
          canvas,
          width,
          height,
          math.max(1, pyRound(checkerPx * _pixelRatio)),
        );
        if (showGrid) {
          _grid(canvas, width, height, zoom);
        }
        final layout = _visibleLayout(doc.designViewLayout(zoom));
        final waypoint =
            wp ??
            Waypoint(
              timestamp: dummyStart,
              timeSinceStart: 0,
              depth: 0,
              temp: 0,
            );
        await run.paintLayout(
          canvas,
          layout,
          await _skinPixels(layout),
          waypoint,
          waypoints,
          width,
          height,
          renderLog: true,
        );
        _screenEdge(canvas, layout, width, height);
      } else {
        width = viewW.toInt();
        height = viewH.toInt();
        final bg = background;
        if (bg != null) {
          canvas.drawImageRect(
            bg,
            ui.Rect.fromLTWH(0, 0, bg.width.toDouble(), bg.height.toDouble()),
            ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            ui.Paint(),
          );
        } else {
          _syntheticBackground(canvas, width, height);
        }
        final layout = _visibleLayout(doc.renderLayout());
        final waypoint =
            wp ??
            Waypoint(
              timestamp: dummyStart,
              timeSinceStart: 0,
              depth: 0,
              temp: 0,
            );
        await run.paintLayout(
          canvas,
          layout,
          await _skinPixels(layout),
          waypoint,
          waypoints,
          width,
          height,
        );
      }
    } on Object catch (e) {
      // A layout the renderer stumbles on: the picture as far as it got.
      if (ticket == _renderTicket) {
        status = 'Overlay Designer render error: $e';
      }
    }
    final picture = recorder.endRecording();
    ui.Image image;
    try {
      image = await picture.toImage(math.max(1, width), math.max(1, height));
    } on Object {
      return;
    } finally {
      picture.dispose();
    }
    if (ticket != _renderTicket || _disposed) {
      image.dispose();
      return;
    }
    _setCanvas(image);
  }

  void _setCanvas(ui.Image? image) {
    canvasImage?.dispose();
    canvasImage = image;
    notifyListeners();
  }

  void _checkerboard(ui.Canvas canvas, int width, int height, int cell) {
    final dark = ui.Paint()..color = const ui.Color(0xFF363636);
    final light = ui.Paint()..color = const ui.Color(0xFF4A4A4A);
    for (var y = 0; y < height; y += cell) {
      for (var x = 0; x < width; x += cell) {
        canvas.drawRect(
          ui.Rect.fromLTWH(
            x.toDouble(),
            y.toDouble(),
            cell.toDouble(),
            cell.toDouble(),
          ),
          ((x ~/ cell + y ~/ cell) % 2 == 1) ? light : dark,
        );
      }
    }
  }

  void _grid(ui.Canvas canvas, int width, int height, double zoom) {
    final step = gridSize * zoom;
    if (step < 4) {
      return;
    }
    final paint = ui.Paint()..color = const ui.Color(0xFF696969);
    for (var x = 0.0; x < width; x += step) {
      canvas.drawLine(
        ui.Offset(x.roundToDouble(), 0),
        ui.Offset(x.roundToDouble(), height.toDouble()),
        paint,
      );
    }
    for (var y = 0.0; y < height; y += step) {
      canvas.drawLine(
        ui.Offset(0, y.roundToDouble()),
        ui.Offset(width.toDouble(), y.roundToDouble()),
        paint,
      );
    }
  }

  // A thin cyan line along the computer's screen (the skin's `screen`
  // area): the renderer draws nothing outside it.
  void _screenEdge(
    ui.Canvas canvas,
    Map<String, dynamic> layout,
    int width,
    int height,
  ) {
    final skin = layout['hud_skin'];
    if (skin is! Map<String, dynamic> || skin['screen'] is! Map) {
      return;
    }
    final (w, h) = skinPixelSize(skin);
    final (x, y) = resolveSkinPosition(skin, width, height, w, h);
    final box = screenBox(skin, x.toInt(), y.toInt(), w.toInt(), h.toInt());
    if (box == null) {
      return;
    }
    final (x0, y0, x1, y1) = box;
    final paint = ui.Paint()
      ..color = const ui.Color(0xFF00DCFF)
      ..style = ui.PaintingStyle.stroke;
    final rect = ui.Rect.fromLTRB(
      x0.toDouble(),
      y0.toDouble(),
      x1.toDouble(),
      y1.toDouble(),
    );
    if ((skin['screen'] as Map)['shape'] == 'ellipse') {
      canvas.drawOval(rect, paint);
    } else {
      canvas.drawRect(rect, paint);
    }
  }

  // A neutral underwater gradient with a soft vignette.
  void _syntheticBackground(ui.Canvas canvas, int width, int height) {
    final rect = ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    canvas
      ..drawRect(
        rect,
        ui.Paint()
          ..shader = ui.Gradient.linear(
            ui.Offset.zero,
            ui.Offset(0, height.toDouble()),
            const [ui.Color(0xFF227096), ui.Color(0xFF0C2648)],
          ),
      )
      ..drawRect(
        rect,
        ui.Paint()
          ..shader = ui.Gradient.radial(
            rect.center,
            math.sqrt(width * width + height * height) / 2,
            const [ui.Color(0x00000000), ui.Color(0x59000000)],
          ),
      );
  }

  // -- telemetry -------------------------------------------------------------------

  Dive dummyDive = buildDummyDive();
  String telemetrySource = sourceDummy;
  String stateOverride = 'auto';
  Waypoint? currentWaypoint;
  String dataText = '';

  void setTelemetrySource(String source) {
    if (!const [sourceDummy, sourceLog].contains(source) ||
        (source == sourceLog && currentDive == null) ||
        source == telemetrySource) {
      return;
    }
    telemetrySource = source;
    _update();
  }

  /// The page's own units: picking the setting's own system follows the
  /// setting again.
  void selectUnits(u.UnitSystem system) {
    _previewUnits = system == _settingsUnits ? null : system;
    _update();
  }

  /// The Advanced setting changed: the page follows it again.
  void unitsChanged() {
    _previewUnits = null;
    _update();
  }

  void selectState(String state) {
    if (!stateOptions.contains(state) || state == stateOverride) {
      return;
    }
    stateOverride = state;
    _update();
  }

  // A video's slider counts frames.
  double get _currentSeconds => _videoPath != null
      ? (_fps > 0 ? timeValue / _fps : 0.0)
      : timeValue.toDouble();

  /// The sample and history the canvas shows: the log's when chosen and in
  /// range, else the dummy dive's at the slider time; a forced state brings
  /// its own short history.
  (Waypoint?, List<Waypoint>?) telemetryForRender() {
    final seconds = _currentSeconds;
    List<Waypoint>? waypoints;
    Waypoint? wp;
    if (telemetrySource == sourceLog && currentDive != null) {
      waypoints = currentDive!.waypoints;
      wp = currentWaypoint;
    }
    if (wp == null) {
      wp = waypointAt(dummyDive, seconds);
      waypoints ??= dummyDive.waypoints;
    }
    if (wp != null && stateOverride != 'auto') {
      final (forced, history) = forcedDive(wp, stateOverride);
      wp = forced;
      if (history != null) {
        waypoints = history;
      }
    }
    return (wp, waypoints);
  }

  void _updateDataText() {
    final (wp, waypoints) = telemetryForRender();
    final usingLog =
        telemetrySource == sourceLog &&
        currentDive != null &&
        currentWaypoint != null;
    if (wp == null) {
      dataText = 'No telemetry.';
      return;
    }
    var source = usingLog ? 'Log telemetry' : 'Dummy telemetry';
    if (telemetrySource == sourceLog && !usingLog && currentDive != null) {
      source = 'Out of dive range - showing dummy telemetry';
    }
    final doc = document;
    final rules = renderer.rules.withOverrides(doc?.layout['rules']);
    final maker = doc?.rulesManufacturer;
    final model = doc?.model;
    final (state, phase, _, _) = rules.stopPhase(maker, model, wp, waypoints);
    final notice = activeNotice(
      rules,
      maker,
      model,
      wp,
      waypoints: waypoints,
      units: units,
    );
    final depth = wp.depth == null
        ? '--'
        : '${pyFormatFixed(u.depth(wp.depth!, units), 1)} ${u.depthLabel(units)}';
    final temp = wp.temp == null
        ? '--'
        : '${pyFormatFixed(u.temperature(wp.temp!, units), 0)} ${u.temperatureLabel(units)}';
    final stateText = phase == null || phase.isEmpty
        ? state
        : '$state ($phase)';
    final noticeText = notice == null ? '' : ' · Notice: ${notice.text}';
    dataText =
        '$source · Depth $depth · Temp $temp · State: $stateText$noticeText';
  }

  // -- the time slider -------------------------------------------------------------------

  int timeValue = 0;
  int timeMin = 0;
  int timeMax = 0;
  bool timeEnabled = false;
  String timeText = '0:00:00';
  bool playing = false;
  Timer? _play;

  void setTime(int minimum, int maximum, int value, bool enabled, String text) {
    _stopPlaying();
    timeMin = minimum;
    timeMax = maximum;
    timeValue = value;
    timeEnabled = enabled;
    timeText = text;
  }

  void _enterDummyTimeRange() => setTime(
    0,
    dummyDurationS,
    dummyDefaultSeconds,
    true,
    timedeltaText(dummyDefaultSeconds),
  );

  /// Play: the slider runs at ten times real time (from the start again at
  /// the end), or stops.
  void togglePlay() {
    if (playing) {
      _stopPlaying();
      notifyListeners();
      return;
    }
    if (!timeEnabled) {
      return;
    }
    if (timeValue >= timeMax) {
      onTimeChanged(timeMin);
    }
    playing = true;
    _play = Timer.periodic(
      const Duration(milliseconds: playTickMs),
      (_) => _playTick(),
    );
    notifyListeners();
  }

  void _stopPlaying() {
    _play?.cancel();
    _play = null;
    playing = false;
  }

  /// Slider units per tick: seconds, or a video's frames.
  int get playStep {
    const seconds = playSpeed * playTickMs / 1000;
    return _videoPath != null && _fps > 0
        ? math.max(1, pyRound(seconds * _fps))
        : math.max(1, pyRound(seconds));
  }

  void _playTick() {
    if (!playing) {
      return;
    }
    final value = math.min(timeMax, timeValue + playStep);
    onTimeChanged(value);
    if (value >= timeMax) {
      _stopPlaying();
      notifyListeners();
    }
  }

  /// The slider moved: the canvas shows that moment, of the dummy dive, of
  /// a log previewed on its own, or of the background video (frame
  /// [value]) and the log sample at its time.
  void onTimeChanged(int value) {
    if (_videoPath != null) {
      unawaited(_showVideoFrame(value));
      return;
    }
    timeValue = value;
    timeText = timedeltaText(value);
    if (_previewFromLog) {
      _syncByDiveTime(value.toDouble());
    }
    _update();
  }

  // -- background and dive logs (the More menu) -----------------------------------

  String? _videoPath;
  double _fps = 30;
  DateTime? _creationDate;
  bool _previewFromLog = false;
  DiveManager _dives = DiveManager();
  Map<String, Dive> _logChoices = {};
  String? selectedLogLabel;
  int tzValue = 0;
  String logText = '';
  int _backgroundTicket = 0;
  int _logTicket = 0;
  int? _frameWanted;
  bool _framing = false;

  bool get hasBackground => background != null;
  bool get logTelemetryAvailable => currentDive != null;
  String get tzText => '${tzValue}h';
  List<String> get logFileList => _logChoices.keys.toList();
  bool get logFileEnabled => _logChoices.isNotEmpty;

  void _remember(String field, String folder) {
    try {
      config.rememberDialogDir(field, folder);
    } on FileSystemException {
      // Only not kept.
    }
  }

  void _setBackground(ui.Image? image) {
    if (identical(image, background)) {
      return;
    }
    background?.dispose();
    background = image;
  }

  /// A photo or video behind Frame preview, its date matched to the
  /// loaded dives (Python `_load_background_from_path`).
  Future<void> loadBackground(String path) async {
    final ticket = ++_backgroundTicket;
    _remember(backgroundDirField, p.dirname(path));
    DesignerMedia? tools;
    String? toolsError;
    try {
      tools = await media?.call();
    } on Exception catch (e) {
      toolsError = e is EngineException ? e.message : '$e';
    }
    DateTime created;
    try {
      created = localCreationDate(
        tools == null ? null : await tools.metadata(path),
        fileModified: fileModified(path),
      );
    } on Object {
      // No tags (or no exiftool): the file's own time, as exiftool's file
      // tags give it in Python, else now.
      created = fileModified(path) ?? naiveNow();
    }
    if (ticket != _backgroundTicket || _disposed) {
      return;
    }
    final suffix = p.extension(path).toLowerCase();
    bool loaded;
    if (suffix == '.mp4' || suffix == '.mov') {
      if (tools == null) {
        _setStatus(toolsError ?? 'Could not read video: $path');
        return;
      }
      loaded = await _loadVideo(path, tools, ticket, created);
    } else {
      loaded = await _loadImage(path, ticket, created);
    }
    // A background that could not be read leaves the one shown, and its
    // date, as they were (Python takes the new file's date regardless).
    if (!loaded || ticket != _backgroundTicket || _disposed) {
      return;
    }
    await _matchDiveToMedia();
  }

  Future<bool> _loadVideo(
    String path,
    DesignerMedia tools,
    int ticket,
    DateTime created,
  ) async {
    ui.Image? frame;
    double fps;
    int total;
    int width;
    int height;
    try {
      final facts = await tools.videoFacts(path);
      final (w, h) = await tools.dimensions(path);
      fps = facts.fps > 0 ? facts.fps : 30.0;
      total = math.max(1, facts.frames);
      width = frameW;
      height = w > 0 ? width * h ~/ w : frameH;
      final rgb = await tools.frameAt(path, 0, width, height);
      frame = rgb == null ? null : await _imageOf(rgb);
    } on Exception {
      frame = null;
      fps = 30;
      total = 1;
      width = frameW;
      height = frameH;
    }
    if (ticket != _backgroundTicket || _disposed) {
      frame?.dispose();
      return false;
    }
    if (frame == null) {
      _setStatus('Could not read video: $path');
      return false;
    }
    _creationDate = created;
    _previewFromLog = false;
    _frameWanted = null;
    _videoPath = path;
    _fps = fps;
    viewW = width.toDouble();
    viewH = height.toDouble();
    _setBackground(frame);
    setTime(0, math.max(1, total - 1), 0, true, '00:00:00');
    _afterBackgroundChanged();
    return true;
  }

  Future<bool> _loadImage(String path, int ticket, DateTime created) async {
    ui.Image? image;
    var height = frameH;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(
        File(path).readAsBytesSync(),
      );
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      // 1920 wide, as Python's resize.
      height = math.max(1, frameW * descriptor.height ~/ descriptor.width);
      codec = await descriptor.instantiateCodec(
        targetWidth: frameW,
        targetHeight: height,
      );
      image = (await codec.getNextFrame()).image;
    } on Object {
      image = null;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
    if (ticket != _backgroundTicket || _disposed) {
      image?.dispose();
      return false;
    }
    if (image == null) {
      _setStatus('Could not read image: $path');
      return false;
    }
    _creationDate = created;
    _previewFromLog = false;
    _frameWanted = null;
    _videoPath = null;
    viewW = frameW.toDouble();
    viewH = height.toDouble();
    _setBackground(image);
    setTime(0, 0, 0, false, 'Photo Mode');
    _syncDataToFrame(0);
    _afterBackgroundChanged();
    return true;
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

  // The video's frame [index]: the slider follows at once; frames are read
  // one at a time, the latest asked for next.
  Future<void> _showVideoFrame(int index) async {
    timeValue = index;
    timeText = timedeltaText(_fps > 0 ? index ~/ _fps : 0);
    notifyListeners();
    _frameWanted = index;
    if (_framing) {
      return;
    }
    _framing = true;
    try {
      while (_frameWanted != null) {
        final want = _frameWanted!;
        _frameWanted = null;
        final path = _videoPath;
        final ticket = _backgroundTicket;
        if (path == null || media == null) {
          break;
        }
        RgbImage? rgb;
        try {
          final tools = await media!();
          rgb = await tools.frameAt(
            path,
            want / _fps,
            viewW.toInt(),
            viewH.toInt(),
          );
        } on Exception {
          rgb = null;
        }
        if (_disposed) {
          break;
        }
        // A frame of a video no longer shown: the next one asked for (of
        // the video shown now) is still read.
        if (rgb == null || ticket != _backgroundTicket || _videoPath != path) {
          continue;
        }
        final image = await _imageOf(rgb);
        if (_disposed) {
          image.dispose();
          break;
        }
        if (ticket != _backgroundTicket || _videoPath != path) {
          image.dispose();
          continue;
        }
        _setBackground(image);
        _syncDataToFrame(want / _fps);
        _update();
      }
    } finally {
      _framing = false;
    }
  }

  /// Back to the made-up backdrop and the dummy dive's time range.
  void clearBackground() {
    ++_backgroundTicket;
    _frameWanted = null;
    _videoPath = null;
    _setBackground(null);
    _creationDate = null;
    _previewFromLog = false;
    viewW = frameW.toDouble();
    viewH = frameH.toDouble();
    _enterDummyTimeRange();
    _afterBackgroundChanged();
  }

  void _afterBackgroundChanged() {
    _zoomFit = true;
    _applyFitZoom();
    _update();
  }

  /// One log file (one saved from the Dive Profile Builder, say): its
  /// dives, matched to the background's time, or the first one previewed
  /// on its own.
  Future<void> loadLogFile(String path) async {
    final ticket = ++_logTicket;
    _remember(logDirField, p.dirname(path));
    final name = p.basename(path);
    final tanks = config.tankConfig().tanks;
    final ({List<Dive>? dives, String? error}) read;
    try {
      read = await compute(_readLogFile, (path, tanks));
    } on Object catch (e) {
      if (ticket == _logTicket && !_disposed) {
        _setStatus('Error parsing $name: $e');
      }
      return;
    }
    if (ticket != _logTicket || _disposed) {
      return;
    }
    final dives = read.dives;
    if (read.error != null) {
      _setStatus('Error parsing $name: ${read.error}');
      return;
    }
    if (dives == null) {
      _setStatus(
        'Unsupported log file: $name (use .uddf, .fit, .ssrf, a '
        'Subsurface/Shearwater .xml or .csv export or a Suunto app .json)',
      );
      return;
    }
    if (dives.isEmpty) {
      _setStatus('No dives found in $name');
      return;
    }
    _dives = DiveManager()..addDives(dives);
    status = 'Loaded ${dives.length} dive(s) from $name';
    _refreshLogChoices();
    if (_creationDate != null) {
      await _matchDiveToMedia();
    } else if (_logChoices.isNotEmpty) {
      await selectLogFile(_logChoices.keys.first);
    } else {
      notifyListeners();
    }
  }

  /// Every log in a folder (not its subfolders), matched to the
  /// background's time. The logs kept in the app ([kept]) are not
  /// remembered as the folder to pick from.
  Future<void> loadLogFolder(String folder, {bool kept = false}) async {
    final ticket = ++_logTicket;
    if (!kept) {
      _remember(logDirField, folder);
    }
    if (!Directory(folder).existsSync()) {
      return;
    }
    final tanks = config.tankConfig().tanks;
    final ({List<Dive> dives, int files}) read;
    try {
      read = await compute(_readLogFolder, (folder, tanks));
    } on Object catch (e) {
      if (ticket == _logTicket && !_disposed) {
        _setStatus('Could not read ${p.basename(folder)}: $e');
      }
      return;
    }
    if (ticket != _logTicket || _disposed) {
      return;
    }
    _dives = DiveManager()..addDives(read.dives);
    status =
        'Loaded ${read.files} log files from '
        '${kept ? 'the imported logs' : p.basename(folder)}';
    _refreshLogChoices();
    await _matchDiveToMedia();
    notifyListeners();
  }

  void _refreshLogChoices() {
    final choices = <String, Dive>{};
    final seen = <String, int>{};
    String two(int v) => '$v'.padLeft(2, '0');
    for (final dive in _dives.dives.values) {
      final name = (dive.logFilename ?? '').isEmpty
          ? 'Unknown log'
          : dive.logFilename!;
      final t = dive.startTime;
      final when =
          '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
      final device = (dive.device ?? '').isNotEmpty
          ? dive.device!
          : dive.manufactor ?? '';
      final base = '$name — $when${device.isEmpty ? '' : ' ($device)'}';
      final n = seen[base] = (seen[base] ?? 0) + 1;
      choices[n == 1 ? base : '$base #$n'] = dive;
    }
    _logChoices = choices;
    selectedLogLabel = null;
  }

  /// A loaded dive previewed on its own: the slider runs over its dive
  /// time, on the made-up backdrop.
  Future<void> selectLogFile(String label) async {
    final dive = _logChoices[label];
    if (dive == null || dive.waypoints.isEmpty) {
      return;
    }
    ++_backgroundTicket;
    selectedLogLabel = label;
    _frameWanted = null;
    _videoPath = null;
    // No media to match against any more.
    _creationDate = null;
    _setBackground(null);
    viewW = frameW.toDouble();
    viewH = frameH.toDouble();
    _previewFromLog = true;
    currentDive = dive;
    telemetrySource = sourceLog;
    final duration = dive.waypoints
        .map((w) => w.timeSinceStart)
        .reduce(math.max);
    setTime(0, math.max(1, duration.ceil()), 0, true, '00:00:00');
    _syncByDiveTime(0);
    await _variantForDive();
  }

  // The tank setup the dive asks for: the page loaded again when that is
  // another variant (Python reloads it always, losing what was not saved).
  Future<void> _variantForDive() async {
    final variants = variantChoices.values.toList();
    if (variants.isEmpty) {
      _afterBackgroundChanged();
      return;
    }
    final resolved = resolveTankVariant(currentDive);
    final wanted = variants.contains(resolved) ? resolved : variants.first;
    if (wanted == _variant) {
      _afterBackgroundChanged();
      return;
    }
    _variant = wanted;
    await _loadSelectedTemplate();
  }

  /// The hours between the media's clock and the log's.
  bool _tzUnmatched = false;

  /// The hours between the media's clock and the log's; [match] false
  /// while the slider is dragged (the dive is matched when it is let go).
  Future<void> setTz(int value, {bool match = true}) async {
    if (value != tzValue) {
      tzValue = value;
      _tzUnmatched = true;
      notifyListeners();
    }
    if (match && _tzUnmatched) {
      _tzUnmatched = false;
      await _matchDiveToMedia();
    }
  }

  Future<void> _matchDiveToMedia() async {
    final created = _creationDate;
    if (created == null) {
      notifyListeners();
      return;
    }
    currentDive = _dives.findDiveForTimestamp(
      created.add(Duration(hours: tzValue)),
    );
    if (currentDive != null) {
      telemetrySource = sourceLog;
      _syncDataToFrame(_videoPath != null ? _currentSeconds : 0);
      await _variantForDive();
    } else {
      logText = 'Current Log: None (No Match)';
      _updateBoxes();
      _redraw();
      dataText =
          'No matching dive found for this date/offset - showing dummy '
          'telemetry.';
      notifyListeners();
    }
  }

  // The log sample at the media's time plus [offsetSeconds].
  void _syncDataToFrame(double offsetSeconds) {
    final dive = currentDive;
    final created = _creationDate;
    if (dive == null || created == null) {
      return;
    }
    final target = created.add(
      Duration(hours: tzValue, microseconds: (offsetSeconds * 1e6).round()),
    );
    currentWaypoint = dive.waypoints
        .where((w) => !w.timestamp.isBefore(target))
        .firstOrNull;
    _setLogText();
    _updateDataText();
  }

  // The log sample at [offsetSeconds] into the dive, else its last.
  void _syncByDiveTime(double offsetSeconds) {
    final dive = currentDive;
    if (dive == null) {
      return;
    }
    currentWaypoint =
        dive.waypoints
            .where((w) => w.timeSinceStart >= offsetSeconds)
            .firstOrNull ??
        dive.waypoints.lastOrNull;
    _setLogText();
    _updateDataText();
  }

  void _setLogText() {
    final wp = currentWaypoint;
    logText = wp == null
        ? 'Current Log: None (No Match)'
        : 'Current Log: ${(wp.logFilename ?? '').isEmpty ? 'Unknown' : wp.logFilename}';
  }

  /// The sample the canvas shows, as JSON for the raw data window; `null`
  /// (with the status saying so) when there is none.
  String? waypointJson() {
    final (wp, _) = telemetryForRender();
    if (wp == null) {
      _setStatus('No waypoint data for current frame.');
      return null;
    }
    return const JsonEncoder.withIndent('    ').convert(wp.toJson());
  }

  // -- a page as a zip ------------------------------------------------------------

  /// The name the export dialog suggests.
  String get exportZipName {
    final ref = document?.ref;
    return ref == null ? 'overlay_page.zip' : '${ref.computer}_${ref.page}.zip';
  }

  /// The page, its skin and what it is as a zip at [path] (`.zip` put on
  /// when missing); false with the reason in the status when it could not
  /// be written.
  Future<bool> exportZip(String path) async {
    final doc = document;
    if (doc == null) {
      return false;
    }
    _remember(zipDirField, p.dirname(path));
    final target = p.extension(path).toLowerCase() == '.zip'
        ? path
        : p.setExtension(path, '.zip');
    final ref = doc.ref;
    final entry = _pageEntry ?? const <String, dynamic>{};
    final meta = <String, dynamic>{
      'brand': ref?.brand ?? '',
      'computer': ref?.computer ?? '',
      'page': ref?.page ?? '',
      'page_name': entry['name'] ?? ref?.page ?? '',
      'manufacturer': doc.manufacturer,
      'model': doc.model,
      'rules_profile': doc.layout['rules_profile'],
    };
    final archive = Archive();
    void addText(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    // As Python's json.dumps: no line break at the end.
    addText(
      stateFilename,
      templateJsonText(normalizedLayout(doc.renderLayout())).trimRight(),
    );
    addText(zipMetaFilename, templateJsonText(meta).trimRight());
    final fresh = File('$target.new');
    try {
      final skin = doc.skinAbsPath;
      if (doc.skinType == 'image' && skin != null) {
        final bytes = _readBytesSync(skin) ?? await templateBytes(skin);
        if (bytes != null) {
          archive.addFile(ArchiveFile(skinFilename, bytes.length, bytes));
        }
      }
      fresh.writeAsBytesSync(ZipEncoder().encode(archive), flush: true);
      fresh.renameSync(target);
    } on Object catch (e) {
      try {
        if (fresh.existsSync()) {
          fresh.deleteSync();
        }
      } on FileSystemException {
        // Swept with nothing else; the export failed either way.
      }
      _setStatus(
        'Could not export: ${e is FileSystemException ? e.message : e}',
      );
      return false;
    }
    _setStatus('Exported ${displayRoot(target, home)}');
    return true;
  }

  ({Map<String, dynamic> layout, Map<String, dynamic> meta, String? skin})?
  _import;

  bool get importPending => _import != null;

  /// Reads a page zip to import; the page name to suggest, or '' when it
  /// cannot be read (the status says why).
  String importZip(String path) {
    _remember(zipDirField, p.dirname(path));
    final error = _readImportZip(path);
    if (error.isNotEmpty) {
      _setStatus(error);
      return '';
    }
    final name = _import!.meta['page_name'];
    return name is String && name.isNotEmpty ? name : 'Imported';
  }

  // The working folder of a zip read before, no longer wanted.
  void _dropStaged() {
    final skin = _import?.skin;
    _import = null;
    if (skin == null) {
      return;
    }
    try {
      Directory(p.dirname(skin)).deleteSync(recursive: true);
    } on FileSystemException {
      // Swept at the next start.
    }
  }

  String _readImportZip(String path) {
    _dropStaged();
    final name = p.basename(path);
    try {
      final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
      ArchiveFile? file(String n) => archive.findFile(n);
      final state = file(stateFilename);
      if (state == null) {
        return '$name has no $stateFilename.';
      }
      final layout =
          jsonDecode(utf8.decode(state.content)) as Map<String, dynamic>;
      final metaFile = file(zipMetaFilename);
      final meta = metaFile == null
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(metaFile.content)) as Map<String, dynamic>;
      String? skinPath;
      final skin =
          (layout['hud_skin'] ??= <String, dynamic>{}) as Map<String, dynamic>;
      if ((skin['type'] ?? 'image') == 'image') {
        final image = file(skinFilename);
        if (image == null) {
          return '$name has no $skinFilename skin image.';
        }
        final folder = tempDir != null
            ? tempDir!('uwmedia_import_')
            : appTempDir('uwmedia_import_');
        skinPath = p.join(folder.path, skinFilename);
        File(skinPath).writeAsBytesSync(image.content);
        skin['path'] = skinPath;
      }
      _import = (layout: layout, meta: meta, skin: skinPath);
    } on Object catch (e) {
      final reason = switch (e) {
        FileSystemException(:final message) => message,
        FormatException(:final message) => message,
        _ => '$e',
      };
      return 'Could not read $name: $reason';
    }
    notifyListeners();
    return '';
  }

  void cancelImport() {
    _dropStaged();
    notifyListeners();
  }

  /// Saves the zip read by [importZip] as a new page, as [saveAs] does;
  /// '' or the reason it could not.
  Future<String> finishImport(
    int targetIndex,
    String newComputerName,
    String pageName,
  ) async {
    final staged = _import;
    if (staged == null) {
      return 'Nothing to import.';
    }
    final dst = _target(targetIndex, newComputerName, pageName);
    if (dst.error != null) {
      return dst.error!;
    }
    if (_saving) {
      return 'A save is still running.';
    }
    _saving = true;
    try {
      final profile = dst.manufacturer == null
          ? null
          : staged.meta['rules_profile'];
      final done = _store().saveTemplateAs(
        staged.layout,
        dst.ref!,
        pageName.trim(),
        skinSource: staged.skin,
        manufacturer: dst.manufacturer,
        model: dst.model,
        rulesProfile: profile is String ? profile : null,
        overwriteUser: false,
      );
      await _carryOut(done);
      // The skin is copied into the page now.
      _dropStaged();
      onTemplatesChanged?.call();
      await _selectRef(dst.ref!);
      _setStatus(
        'Imported as ${dst.ref!.label} → ${displayRoot(done.statePath, home)}',
      );
      return '';
    } on Object catch (e) {
      return _saveError(e, 'Could not import');
    } finally {
      _saving = false;
    }
  }

  @override
  void dispose() {
    // The page and whoever made the controller may both let it go.
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stopPlaying();
    canvasImage?.dispose();
    canvasImage = null;
    background?.dispose();
    background = null;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }
}
