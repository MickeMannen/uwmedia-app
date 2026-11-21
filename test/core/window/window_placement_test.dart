// The desktop window's placement (lib/core/window/window_placement.dart,
// spec §13.6): the first window from a screen's work area, a kept window
// put back, moved onto its screen or dropped (screen gone, too small),
// and the text of window.json both ways.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/window/window_placement.dart';

void main() {
  // A 1440 x 900 MacBook screen less its 25 px menu bar and 75 px Dock.
  const macbook = WindowRect(0, 25, 1440, 800);
  // A 2560 x 1440 screen less a 48 px taskbar.
  const big = WindowRect(0, 0, 2560, 1392);
  // A second screen to the right of [big].
  const right = WindowRect(2560, 0, 1920, 1040);

  group('the first window', () {
    test('85 % of a large work area, centred', () {
      expect(firstBounds(big), const WindowRect(192, 104, 2176, 1183));
    });

    test('at least 1280 x 800 on a smaller screen', () {
      // 85 % would be 1224 x 680.
      expect(firstBounds(macbook), const WindowRect(80, 25, 1280, 800));
    });

    test('never larger than the work area', () {
      const small = WindowRect(0, 30, 1024, 738);
      expect(firstBounds(small), small);
    });

    test('on a screen that does not start at the origin', () {
      final b = firstBounds(right);
      expect(b.width, 1632);
      expect(b.height, 884);
      expect(b.left, 2560 + (1920 - 1632) / 2);
      expect(b.top, (1040 - 884) / 2);
    });
  });

  group('the minimum', () {
    test('1100 x 720, or the work area of a smaller screen', () {
      expect(minimumSizeOn(big), (width: 1100.0, height: 720.0));
      expect(minimumSizeOn(const WindowRect(0, 0, 1024, 700)), (
        width: 1024.0,
        height: 700.0,
      ));
    });
  });

  group('placing the window', () {
    test('no file: the first window on the main screen', () {
      final placed = placeWindow(null, [big, right]);
      expect(placed.state, WindowState(firstBounds(big)));
      expect(placed.minWidth, minWindowWidth);
      expect(placed.minHeight, minWindowHeight);
    });

    test('the kept window where it was, maximised or not', () {
      const kept = WindowState(
        WindowRect(2700, 50, 1500, 900),
        maximized: true,
      );
      expect(placeWindow(kept, [big, right]).state, kept);
    });

    test('a screen that is gone: the first window on the main screen', () {
      const kept = WindowState(WindowRect(2700, 50, 1500, 900));
      expect(placeWindow(kept, [big]).state, WindowState(firstBounds(big)));
    });

    test('smaller than the minimum: the first window', () {
      const kept = WindowState(WindowRect(100, 100, 1000, 800));
      expect(placeWindow(kept, [big]).state, WindowState(firstBounds(big)));
    });

    test('larger than its screen now: fitted onto it', () {
      // Kept on a large screen, opened on the MacBook alone.
      const kept = WindowState(WindowRect(100, 60, 2000, 1200));
      expect(
        placeWindow(kept, [macbook]).state,
        const WindowState(WindowRect(0, 25, 1440, 800)),
      );
    });

    test('hanging off its screen: moved onto it', () {
      // The title bar above the screen, the right edge past it.
      const kept = WindowState(WindowRect(1800, -40, 1200, 800));
      expect(
        placeWindow(kept, [big]).state,
        const WindowState(WindowRect(1360, 0, 1200, 800)),
      );
    });

    test('a screen smaller than the minimum takes its whole work area', () {
      const tiny = WindowRect(0, 0, 1024, 700);
      final placed = placeWindow(null, [tiny]);
      expect(placed.state.bounds, tiny);
      expect((placed.minWidth, placed.minHeight), (1024.0, 700.0));
      // And the window kept there at that size is put back.
      expect(placeWindow(const WindowState(tiny), [tiny]).state.bounds, tiny);
    });

    test('no screen known: the kept window, else a 1280 x 800 one', () {
      const kept = WindowState(WindowRect(10, 20, 1300, 900));
      expect(placeWindow(kept, []).state, kept);
      expect(
        placeWindow(null, []).state,
        const WindowState(WindowRect(0, 0, 1280, 800)),
      );
    });
  });

  group('window.json', () {
    test('both ways', () {
      const state = WindowState(
        WindowRect(-1200, 40, 1500, 950),
        maximized: true,
      );
      final text = encodeWindowState(state);
      expect(text, contains('"maximized": true'));
      expect(decodeWindowState(text), state);
    });

    test('whole pixels', () {
      expect(
        encodeWindowState(
          const WindowState(WindowRect(10.4, 20.6, 1280.2, 800.7)),
        ),
        '{\n  "x": 10,\n  "y": 21,\n  "width": 1280,\n  "height": 801,\n'
        '  "maximized": false\n}',
      );
    });

    test('a file that is not one is none', () {
      for (final text in [
        '',
        'not json',
        '[]',
        '{"x": 1, "y": 2, "width": 3}',
        '{"x": 1, "y": 2, "width": "3", "height": 4}',
        '{"x": 1, "y": 2, "width": 0, "height": 4}',
        '{"x": 1, "y": 2, "width": 3, "height": -4}',
      ]) {
        expect(decodeWindowState(text), isNull, reason: text);
      }
    });

    test('without "maximized": not maximised', () {
      expect(
        decodeWindowState('{"x": 1, "y": 2, "width": 1300, "height": 900}'),
        const WindowState(WindowRect(1, 2, 1300, 900)),
      );
    });
  });
}
