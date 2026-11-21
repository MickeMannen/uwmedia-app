import 'package:flutter/material.dart';

/// A read-only path with a browse button beside it: the path as
/// [display] shows it, in full in the tooltip.
class PathField extends StatelessWidget {
  const PathField({
    super.key,
    required this.label,
    required this.path,
    required this.display,
    required this.browseIcon,
    required this.browseTooltip,
    required this.onBrowse,
  });

  final String label;
  final String path;
  final String display;
  final IconData browseIcon;
  final String browseTooltip;
  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 2,
    children: [
      Text(label),
      Row(
        spacing: 2,
        children: [
          Expanded(
            child: Tooltip(
              message: path,
              child: InputDecorator(
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ),
          ),
          IconButton(
            icon: Icon(browseIcon),
            tooltip: browseTooltip,
            onPressed: onBrowse,
          ),
        ],
      ),
    ],
  );
}
