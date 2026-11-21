import 'package:flutter/material.dart';

/// A text field whose text is a controller's: it follows [value] when the
/// controller changes it (a file opened, the units switched) unless the
/// user is typing in it, and reports every edit.
class BoundField extends StatefulWidget {
  const BoundField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.label,
    this.width,
    this.enabled = true,
    this.tooltip,
    this.onSubmitted,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? label;
  final double? width;
  final bool enabled;
  final String? tooltip;
  final ValueChanged<String>? onSubmitted;

  @override
  State<BoundField> createState() => _BoundFieldState();
}

class _BoundFieldState extends State<BoundField> {
  late final _text = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void didUpdateWidget(BoundField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _text.text != widget.value) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget field = TextField(
      controller: _text,
      focusNode: _focus,
      enabled: widget.enabled,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        labelText: widget.label,
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
    );
    if (widget.width != null) {
      field = SizedBox(width: widget.width, child: field);
    }
    return widget.tooltip == null
        ? field
        : Tooltip(message: widget.tooltip, child: field);
  }
}
