import 'package:flutter/material.dart';
import 'package:uwmedia_app/app/theme.dart';

/// A titled card: a bold title over a column of content (the panes of the
/// Python pages).
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: [
          if (title != null)
            Text(
              title!,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ...children,
        ],
      ),
    ),
  );
}

/// A line in the hint grey.
class MutedText extends StatelessWidget {
  const MutedText(this.text, {super.key, this.size = 12, this.maxLines});

  final String text;
  final double size;

  /// With a number, the text is cut there with an ellipsis.
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    style: TextStyle(color: mutedText, fontSize: size),
  );
}

/// The frame of a page: its title over its cards, scrolling, no wider
/// than [maxWidth].
class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.title,
    required this.children,
    this.maxWidth = 700,
  });

  final String title;
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            ...children,
          ],
        ),
      ),
    ),
  );
}
