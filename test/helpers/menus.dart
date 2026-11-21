// A page's place menu in a widget test (lib/pages/shared/place_menu.dart,
// the phones' pick button): the button pressed, then the place chosen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the menu of [button] and chooses [place]. With [real] the choice
/// is given real time (file reads, an engine) to be acted on.
Future<void> choosePlace(
  WidgetTester tester,
  Finder button,
  String place, {
  bool real = false,
}) async {
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  Future<void> choose() async {
    await tester.tap(find.widgetWithText(MenuItemButton, place));
    // The choice is acted on once the menu has closed.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  if (real) {
    await tester.runAsync(() async {
      await choose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  } else {
    await choose();
  }
  await tester.pumpAndSettle();
}
