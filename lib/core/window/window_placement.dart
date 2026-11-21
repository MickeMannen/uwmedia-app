/// Where the desktop window opens and how big it may be (spec §13.6): the
/// first launch at a share of the screen, the size and place of the last
/// run kept in `window.json` in the config folder, and the rules for when
/// that is no longer usable. Plain Dart: the window itself is moved by
/// `lib/engine/desktop/desktop_window.dart`.
///
/// Every rectangle is in logical pixels with the origin at the top left
/// of the main screen, as `window_manager` and `screen_retriever` give
/// them. A window's rectangle is its frame, title bar included.
library;

import 'dart:convert';
import 'dart:math' as math;

/// The file in the config folder that keeps the window between runs.
const windowStateFilename = 'window.json';

/// The smallest window the pages are laid out for (checked by
/// `test/app/window_min_size_test.dart`). A screen smaller than this
/// gets its whole work area instead.
const minWindowWidth = 1100.0;
const minWindowHeight = 720.0;

/// The size the first window should at least have (the Python app's).
const firstWindowWidth = 1280.0;
const firstWindowHeight = 800.0;

/// The share of the work area the first window takes.
const firstWindowShare = 0.85;

/// A rectangle on the desktop: a window's frame or a screen's work area
/// (the screen less the menu bar, the Dock or the taskbar).
class WindowRect {
  const WindowRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  /// Whether the point lies on this rectangle (its right and bottom edge
  /// excluded, so that two screens side by side do not share it).
  bool containsPoint(double x, double y) =>
      x >= left && x < right && y >= top && y < bottom;

  @override
  bool operator ==(Object other) =>
      other is WindowRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'WindowRect($left, $top, $width x $height)';
}

/// The window as kept between runs: its frame when neither maximised nor
/// full screen, and whether it was maximised.
class WindowState {
  const WindowState(this.bounds, {this.maximized = false});

  final WindowRect bounds;
  final bool maximized;

  @override
  bool operator ==(Object other) =>
      other is WindowState &&
      other.bounds == bounds &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(bounds, maximized);

  @override
  String toString() => 'WindowState($bounds, maximized: $maximized)';
}

/// The smallest window allowed on [workArea]: the minimum, or the whole
/// work area of a screen smaller than that.
({double width, double height}) minimumSizeOn(WindowRect workArea) => (
  width: math.min(minWindowWidth, workArea.width),
  height: math.min(minWindowHeight, workArea.height),
);

/// The first window on [workArea]: [firstWindowShare] of it, at least
/// [firstWindowWidth] x [firstWindowHeight] but never larger than the
/// work area, in whole pixels and centred.
WindowRect firstBounds(WindowRect workArea) {
  double side(double area, double least) =>
      math.min(math.max(area * firstWindowShare, least), area).floorToDouble();
  final width = side(workArea.width, firstWindowWidth);
  final height = side(workArea.height, firstWindowHeight);
  return WindowRect(
    (workArea.left + (workArea.width - width) / 2).floorToDouble(),
    (workArea.top + (workArea.height - height) / 2).floorToDouble(),
    width,
    height,
  );
}

/// Where the window opens and the smallest it may be made: [saved] (the
/// last run's) when its centre lies on one of [workAreas] and it is not
/// smaller than the minimum there, fitted onto that work area; otherwise
/// the first window on the first of [workAreas] (the main screen). With
/// no screen known at all, [saved] as it was, else the first window on a
/// made-up screen of [firstWindowWidth] x [firstWindowHeight].
({WindowState state, double minWidth, double minHeight}) placeWindow(
  WindowState? saved,
  List<WindowRect> workAreas,
) {
  ({WindowState state, double minWidth, double minHeight}) on(
    WindowRect area,
    WindowState state,
  ) {
    final minimum = minimumSizeOn(area);
    return (state: state, minWidth: minimum.width, minHeight: minimum.height);
  }

  if (workAreas.isEmpty) {
    const area = WindowRect(0, 0, firstWindowWidth, firstWindowHeight);
    return on(area, saved ?? WindowState(firstBounds(area)));
  }
  if (saved != null) {
    final b = saved.bounds;
    final cx = b.left + b.width / 2;
    final cy = b.top + b.height / 2;
    for (final area in workAreas) {
      if (!area.containsPoint(cx, cy)) {
        continue;
      }
      final minimum = minimumSizeOn(area);
      if (b.width < minimum.width || b.height < minimum.height) {
        break;
      }
      // Fitted onto its screen: no larger than the work area, and moved
      // in so that the title bar can be reached.
      final width = math.min(b.width, area.width);
      final height = math.min(b.height, area.height);
      final left = b.left.clamp(area.left, area.right - width).toDouble();
      final top = b.top.clamp(area.top, area.bottom - height).toDouble();
      return on(
        area,
        WindowState(
          WindowRect(left, top, width, height),
          maximized: saved.maximized,
        ),
      );
    }
  }
  final main = workAreas.first;
  return on(main, WindowState(firstBounds(main)));
}

/// [state] as the text of [windowStateFilename].
String encodeWindowState(WindowState state) =>
    const JsonEncoder.withIndent('  ').convert({
      'x': state.bounds.left.round(),
      'y': state.bounds.top.round(),
      'width': state.bounds.width.round(),
      'height': state.bounds.height.round(),
      'maximized': state.maximized,
    });

/// The window kept in [text]; `null` for a file that is not one (empty,
/// damaged, from a newer version without these fields, or with a size
/// that is no size).
WindowState? decodeWindowState(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic>) {
    return null;
  }
  final map = json;
  double? number(String key) {
    final value = map[key];
    return value is num && value.isFinite ? value.toDouble() : null;
  }

  final x = number('x');
  final y = number('y');
  final width = number('width');
  final height = number('height');
  if (x == null || y == null || width == null || height == null) {
    return null;
  }
  if (width <= 0 || height <= 0) {
    return null;
  }
  return WindowState(
    WindowRect(x, y, width, height),
    maximized: map['maximized'] == true,
  );
}
