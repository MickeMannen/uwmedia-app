/// The app's look: the Python app's dark Material theme with its blue
/// accent (`qml/main.qml`, `qml/Card.qml`).
library;

import 'package:flutter/material.dart';

const accent = Color(0xFF00A6ED);
const pageBackground = Color(0xFF1F1F1F);
const navBackground = Color(0xFF171717);
const cardBackground = Color(0xFF262626);
const cardBorder = Color(0xFF333333);

/// The grey of hints, labels beside controls and status lines.
const mutedText = Color(0xFF9AA0A6);

ThemeData appTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    primary: accent,
    surface: pageBackground,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: pageBackground,
    cardTheme: const CardThemeData(
      color: cardBackground,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: cardBorder),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    // A light box with dark text: Material's own dark tooltip hardly
    // stands out on these dark pages (Python 2026-10-17).
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      textStyle: const TextStyle(color: Color(0xFF1A1A1A), fontSize: 13),
      decoration: BoxDecoration(
        color: const Color(0xFFECECEC),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFB0B0B0)),
      ),
    ),
  );
}
