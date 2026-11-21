/// The Overlay Designer's inspector (Python
/// `qml/OverlayElementInspector.qml`): with several elements selected, the
/// align and distribute buttons; with one, its form by kind in folding
/// sections; with the skin, its size, look and placement. Numbers are
/// applied when the field is left or Enter is pressed, and the controller
/// reads and clamps them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/pages/overlay_designer/designer_controller.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const _numW = 70.0;
const _textW = 150.0;
const _colorW = 84.0;

const _smallSuffixLabels = {
  '': 'None',
  'seconds': 'Seconds (MM:SS)',
  'decimals': 'Decimals (x.y)',
};

String _str(Object? value) => value == null ? '' : '$value';

/// A text field that shows the controller's value and hands an edit back
/// when the field is left or Enter is pressed.
class CommitField extends StatefulWidget {
  const CommitField({
    super.key,
    required this.value,
    required this.onCommit,
    this.width = _numW,
    this.hint,
    this.tooltip,
  });

  final String value;
  final ValueChanged<String> onCommit;
  final double width;
  final String? hint;
  final String? tooltip;

  @override
  State<CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<CommitField> {
  late final _text = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        _commit();
      }
    });
  }

  // The text last handed back, so that Enter and then leaving the field
  // hand it back once.
  String? _committed;

  void _commit() {
    final text = _text.text;
    if (text != widget.value && text != _committed) {
      _committed = text;
      widget.onCommit(text);
    }
  }

  @override
  void didUpdateWidget(CommitField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      _committed = null;
    }
    if (!_focus.hasFocus && _text.text != widget.value) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    // Another element picked while a value was typed and not handed back:
    // it goes to the element it was typed for, once this build is over.
    final text = _text.text;
    if (text != widget.value && text != _committed) {
      final commit = widget.onCommit;
      scheduleMicrotask(() => commit(text));
    }
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = SizedBox(
      width: widget.width,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(isDense: true, hintText: widget.hint),
        onSubmitted: (_) => _commit(),
      ),
    );
    return widget.tooltip == null
        ? field
        : Tooltip(message: widget.tooltip, child: field);
  }
}

Color? _parseHex(String text) {
  final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(text.trim());
  return match == null
      ? null
      : Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
}

/// A colour as a swatch and its `#RRGGBB`; only a whole hex colour is
/// handed back, or with [clearable] an emptied field, as `''` (none).
class ColorField extends StatelessWidget {
  const ColorField({
    super.key,
    required this.value,
    required this.onCommit,
    this.clearable = false,
  });

  final String value;
  final ValueChanged<String> onCommit;
  final bool clearable;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 6,
    children: [
      Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: _parseHex(value) ?? Colors.transparent,
          border: Border.all(color: const Color(0xFF606060)),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      CommitField(
        value: value,
        width: _colorW,
        hint: '#RRGGBB',
        onCommit: (text) {
          if (_parseHex(text) != null) {
            onCommit(text.trim().toUpperCase());
          } else if (clearable && text.trim().isEmpty) {
            onCommit('');
          }
        },
      ),
    ],
  );
}

/// A folding group of inspector rows; the open state is kept for the
/// session.
class _Section extends StatefulWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  State<_Section> createState() => _SectionState();
}

final Map<String, bool> _sectionOpen = {};

class _SectionState extends State<_Section> {
  @override
  Widget build(BuildContext context) {
    final open = _sectionOpen[widget.title] ?? true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _sectionOpen[widget.title] = !open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${open ? '▾' : '▸'}  ${widget.title}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}

class DesignerInspector extends StatelessWidget {
  const DesignerInspector({
    super.key,
    required this.controller,
    required this.onReplaceImage,
  });

  final DesignerController controller;
  final VoidCallback onReplaceImage;

  DesignerController get c => controller;

  // A typed value belongs to the element it was typed for, even when the
  // field is left by picking another one.
  ValueChanged<String> _commitTo(String attr) {
    final element = c.selectedIndex;
    return (text) => c.setSelectedAttr(attr, text, element: element);
  }

  Widget _label(String text, {double width = 64}) => SizedBox(
    width: width,
    child: Text(text, style: const TextStyle(fontSize: 13)),
  );

  /// A label and its field on one line of the wrap; a tooltip goes on the
  /// label.
  Widget _pair(String label, Widget field, {String? tooltip}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [_tip(tooltip, _label(label)), field],
  );

  Widget _num(
    String label,
    String attr,
    Map<String, Object?> values, {
    String? tooltip,
    bool skin = false,
  }) => _pair(
    label,
    CommitField(
      key: ValueKey(skin ? 'skin:$attr' : 'el:${c.selectedIndex}:$attr'),
      value: _str(values[attr]),
      tooltip: tooltip,
      onCommit: skin ? (text) => c.setSkinAttr(attr, text) : _commitTo(attr),
    ),
  );

  Widget _color(
    String label,
    String attr,
    Map<String, Object?> values, {
    bool skin = false,
    bool clearable = false,
    String? tooltip,
  }) => _pair(
    label,
    ColorField(
      key: ValueKey(skin ? 'skin:$attr' : 'el:${c.selectedIndex}:$attr'),
      value: _str(values[attr]),
      clearable: clearable,
      onCommit: skin ? (text) => c.setSkinAttr(attr, text) : _commitTo(attr),
    ),
    tooltip: tooltip,
  );

  Widget _check(String label, String attr, Object? value, {String? tooltip}) {
    final box = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value == true,
          onChanged: (v) => c.setSelectedAttr(attr, v ?? false),
        ),
        Flexible(child: Text(label, style: const TextStyle(fontSize: 13))),
      ],
    );
    return tooltip == null ? box : Tooltip(message: tooltip, child: box);
  }

  Widget _choice(
    String label,
    String attr,
    Object? current,
    List<String> options,
    List<String> labels, {
    List<String>? tips,
  }) => _pair(
    label,
    // Flexible: the buttons wrap within the inspector's width instead of
    // running past it on one line.
    Flexible(
      child: Wrap(
        spacing: 2,
        children: [
          for (final (i, option) in options.indexed)
            _tip(
              tips?[i],
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(36, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  backgroundColor: current == option
                      ? accent.withValues(alpha: 0.25)
                      : null,
                ),
                onPressed: () => c.setSelectedAttr(attr, option),
                child: Text(labels[i], style: const TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _tip(String? message, Widget child) =>
      message == null ? child : Tooltip(message: message, child: child);

  Widget _dropdown(
    String label,
    Object? current,
    Map<String, String> items,
    ValueChanged<String> onChanged, {
    double width = _textW,
  }) => _pair(
    label,
    SizedBox(
      width: width,
      child: DropdownButton<String>(
        isExpanded: true,
        isDense: true,
        value: items.containsKey(current) ? '$current' : null,
        items: [
          for (final MapEntry(:key, :value) in items.entries)
            DropdownMenuItem(
              value: key,
              child: Text(
                value,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => onChanged(v!),
      ),
    ),
  );

  Widget _icon(String glyph, String tooltip, VoidCallback onPressed) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onPressed,
      child: SizedBox(width: 28, height: 28, child: Center(child: Text(glyph))),
    ),
  );

  Widget _quickSize(String what) => _pair(
    'Quick size',
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _icon(
          '−',
          'Shrink $what 5 % (or the − key)',
          () => c.resizeSelected(-1),
        ),
        _icon('+', 'Grow $what 5 % (or the + key)', () => c.resizeSelected(1)),
        const MutedText('5 % per step', size: 11),
      ],
    ),
  );

  Widget _multi() => SectionCard(
    children: [
      Text(
        '${c.selectionCount} elements selected',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      Row(
        children: [
          _label('Align'),
          for (final (mode, glyph) in const [
            ('left', '⇤'),
            ('hcenter', '↔'),
            ('right', '⇥'),
            ('top', '⤒'),
            ('vcenter', '↕'),
            ('bottom', '⤓'),
          ])
            _icon(glyph, 'Align $mode', () => c.alignSelected(mode)),
        ],
      ),
      Row(
        children: [
          _label('Distribute'),
          if (c.selectionCount >= 3) ...[
            _icon(
              '⋯',
              'Distribute horizontally',
              () => c.distributeSelected('h'),
            ),
            _icon(
              '⋮',
              'Distribute vertically',
              () => c.distributeSelected('v'),
            ),
          ],
          const Spacer(),
          _icon('⎘', 'Copy (Cmd/Ctrl-C)', c.copySelected),
          _icon('🗑', 'Remove (Delete)', c.removeSelected),
        ],
      ),
      const MutedText(
        'Align moves the others onto the last-clicked element (the one with '
        'the label). The form below edits that element.',
        size: 11,
      ),
    ],
  );

  Widget _element(BuildContext context) {
    final sel = c.selectedElement;
    final kind = '${sel['kind']}';
    final custom = sel['is_custom'] == true;
    final textLike = kind == 'text' || kind == 'badge';
    final gauge = kind == 'arc' || kind == 'segment_bar';
    final sized =
        gauge ||
        const {
          'tank_icon',
          'graph',
          'tissue_bar',
          'ascent_chevrons',
          'notice',
          'tank_switch_arrows',
        }.contains(kind) ||
        (kind == 'badge' && sel['style'] == 'box');
    final style = '${sel['style']}';
    final title = switch (kind) {
      'tissue_bar' => 'tissue bar',
      'ascent_chevrons' => 'ascent chevrons',
      'segment_bar' => 'segment bar',
      _ => kind,
    };
    final fields = c.availableFields;
    final field = '${sel['field']}';
    return SectionCard(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Element · $title',
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (sel['shared'] == true)
              const Tooltip(
                message:
                    'Shared by every tank-setup variant of this page: moving '
                    'or editing it changes them all',
                child: MutedText('shared ', size: 10),
              ),
            _icon('⤒', 'Send to back (Shift-Cmd/Ctrl-[)', c.sendToBack),
            _icon(
              '▲',
              'Send backward (Cmd/Ctrl-[)',
              () => c.moveSelectedLayer(-1),
            ),
            _icon(
              '▼',
              'Bring forward (Cmd/Ctrl-])',
              () => c.moveSelectedLayer(1),
            ),
            _icon('⤓', 'Bring to front (Shift-Cmd/Ctrl-])', c.bringToFront),
            _icon('⧉', 'Duplicate (Cmd/Ctrl-D)', c.duplicateSelected),
            _icon('🗑', 'Remove (Delete)', c.removeSelected),
          ],
        ),
        _Section('Element', [
          _pair(
            'Name',
            CommitField(
              key: ValueKey('el:${c.selectedIndex}:label'),
              value: _str(sel['label']),
              width: _textW,
              hint: 'optional',
              tooltip: 'Shown in the element list',
              onCommit: _commitTo('label'),
            ),
          ),
          if (custom)
            _pair(
              'Text',
              CommitField(
                key: ValueKey('el:${c.selectedIndex}:custom_text'),
                value: _str(sel['custom_text']),
                width: _textW,
                onCommit: _commitTo('custom_text'),
              ),
            )
          else if (kind == 'text' ||
              kind == 'tank_icon' ||
              kind == 'tissue_bar' ||
              gauge)
            _dropdown('Field', field, {
              for (final f in fields) f: f,
              if (!fields.contains(field)) field: field,
            }, (v) => c.setSelectedAttr('field', v))
          else if (kind == 'badge' || kind == 'graph')
            _pair('Field', MutedText(field)),
        ]),
        _Section('Position and size', [
          _num('X', 'x_px', sel),
          _num('Y', 'y_px', sel),
          if (textLike || kind == 'notice')
            _num(kind == 'badge' ? 'Label size' : 'Size', 'font_size', sel),
          if (kind == 'text')
            _num(
              'Max width',
              'max_width',
              sel,
              tooltip:
                  'Skin px; a wider value (3002 psi where 207 bar fits) '
                  'shrinks to this. 0 = no limit',
            ),
          if (kind == 'notice')
            _num(
              'Caption size',
              'caption_font_size',
              sel,
              tooltip:
                  'Size of the Warning / Alert caption and the Confirm hint',
            ),
          if (kind == 'badge') _num('Value size', 'value_font_size', sel),
          if (kind == 'text') _num('Scale', 'scale', sel),
          if (textLike) _quickSize('the text'),
          if (sized) _num('Width', 'width', sel),
          if (sized && !(kind == 'notice' && style == 'text'))
            _num('Height', 'height', sel),
          if (kind == 'ascent_chevrons') ...[
            _num(
              'Up',
              'up_count',
              sel,
              tooltip: 'Number of upward (ascent) chevrons',
            ),
            _num(
              'Down',
              'down_count',
              sel,
              tooltip: 'Number of downward (descent) chevrons',
            ),
            _check(
              'Divider bar',
              'bar',
              sel['bar'],
              tooltip:
                  'The white bar between the up and down chevrons (Garmin). '
                  'A Perdix shows arrows only.',
            ),
          ],
          if (gauge ||
              const {
                'tank_icon',
                'graph',
                'tissue_bar',
                'ascent_chevrons',
              }.contains(kind))
            _quickSize('width and height'),
          if (kind == 'tank_icon') _num('Radius', 'corner_radius', sel),
        ]),
        if (textLike)
          _Section('Text', [
            _dropdown('Font', sel['font_family'], {
              for (final f in c.fontFamilies) f: f,
            }, (v) => c.setSelectedAttr('font_family', v)),
            if (kind == 'text') ...[
              _color('Color', 'color', sel),
              _color(
                'Box',
                'box_color',
                sel,
                clearable: true,
                tooltip:
                    "A filled box behind the value (a Nautic's stop timer). "
                    'Empty the field for none.',
              ),
              _dropdown(
                'Small suffix',
                sel['small_suffix'],
                _smallSuffixLabels,
                (v) => c.setSelectedAttr('small_suffix', v),
              ),
              if (_str(sel['small_suffix']).isNotEmpty)
                _num(
                  'Suffix size',
                  'small_suffix_scale',
                  sel,
                  tooltip: 'Fraction of the main font size (0.33 = one third)',
                ),
            ],
            _choice(
              'Align',
              'align',
              sel['align'],
              alignOptions,
              const ['L', 'C', 'R'],
              tips: const [
                "Left: the text starts at the element's position and grows "
                    'to the right',
                "Centre: the text is centred on the element's position, so a "
                    'number stays centred as it gets wider or narrower',
                "Right: the text ends at the element's position and grows to "
                    'the left',
              ],
            ),
            _choice(
              'V-align',
              'valign',
              sel['valign'],
              valignOptions,
              const ['T', 'M', 'B'],
              tips: const [
                "Top: the text hangs below the element's position",
                "Middle: the text is centred vertically on the element's "
                    'position',
                "Bottom: the text sits on top of the element's position",
              ],
            ),
            if (kind == 'text')
              _choice(
                'Orientation',
                'orientation',
                sel['orientation'],
                textOrientations,
                const ['H', 'S', '↑', '↓'],
                tips: const [
                  'Horizontal',
                  'Stacked: one upright letter under the other',
                  'Turned on its side, reading bottom to top',
                  'Turned on its side, reading top to bottom',
                ],
              ),
            _check('Bold', 'bold', sel['bold']),
            _check('Black outline', 'outline', sel['outline']),
            _check(
              'Hide while a notice shows',
              'hide_when_notice',
              sel['hide_when_notice'],
              tooltip:
                  "Step aside while the template's notice element shows a "
                  'notification (a Perdix replaces its bottom row with the '
                  'message)',
            ),
            if (kind == 'text')
              _check(
                'Hide during a tank switch',
                'hide_when_switch',
                sel['hide_when_switch'],
                tooltip:
                    'Step aside while the sidemount tanks differ by more than '
                    "the switch pressure (a Descent's SM label makes room for "
                    'the arrows)',
              ),
          ]),
        if (kind == 'text' && !custom)
          _Section('Unit', [
            _check(
              'Unit after the value',
              'unit_suffix',
              sel['unit_suffix'],
              tooltip:
                  "Draw the value's unit with it (m or ft, BAR or PSI, °C or "
                  '°F) so it follows the Units setting - instead of a '
                  'separate label',
            ),
            if (sel['unit_suffix'] == true) ...[
              _choice(
                'Place',
                'unit_position',
                sel['unit_position'],
                const ['right', 'below'],
                const ['Right', 'Below'],
                tips: const [
                  'The unit after the value',
                  "The unit under the value's last digits",
                ],
              ),
              _num(
                'Size',
                'unit_scale',
                sel,
                tooltip: "Fraction of the value's size (0.35 = about a third)",
              ),
              _color('Colour', 'unit_color', sel),
              _num(
                'Offset X',
                'unit_dx',
                sel,
                tooltip: 'Skin px from its natural place',
              ),
              _num('Offset Y', 'unit_dy', sel),
              _choice(
                'Stacked',
                'unit_orientation',
                sel['unit_orientation'],
                const ['horizontal', 'stacked'],
                const ['H', 'S'],
                tips: const [
                  'The unit on one line',
                  "The unit's letters one under the other, as a Shearwater's "
                      'B A R tag',
                ],
              ),
            ],
          ]),
        if (kind == 'notice')
          _Section('Notice', [
            _choice(
              'Style',
              'style',
              style,
              const ['text', 'banner', 'box', 'frame'],
              const ['Text', 'Banner', 'Box', 'Frame'],
              tips: const [
                'Caption and message in the notice colour (Perdix)',
                'A filled band with black text (Teric)',
                'A dark outlined box with a warning triangle (Descent X50i)',
                "An outlined box with stacked lines (a Perdix's MOD box)",
              ],
            ),
            _choice(
              'Shows',
              'source',
              sel['source'],
              const ['timed', 'persistent'],
              const ['Alerts', 'Persistent'],
              tips: const [
                "The computer's notifications, shown for a few seconds when "
                    'the log triggers them',
                'The box that stays while a situation lasts (MOD exceeded, '
                    'Near MOD, High CNS on a Perdix)',
              ],
            ),
            _pair(
              'Confirm hint',
              CommitField(
                key: ValueKey('el:${c.selectedIndex}:confirm_text'),
                value: _str(sel['confirm_text']),
                width: _textW,
                hint: 'Confirm',
                tooltip:
                    'The button hint at the right (Confirm on a Perdix, CLEAR '
                    'on a Teric); empty for none',
                onCommit: _commitTo('confirm_text'),
              ),
            ),
            _color('Caption colour', 'caption_color', sel),
            _check('Black outline', 'outline', sel['outline']),
          ]),
        if (kind == 'tank_icon') _tankIcon(sel, style),
        if (gauge) _gauge(sel, arc: kind == 'arc'),
        if (kind == 'tissue_bar')
          _Section('Tissue bar', [
            _choice(
              'Style',
              'style',
              style,
              const ['segments', 'fill'],
              const ['Seg', 'Fill'],
            ),
            if (style != 'fill')
              _num(
                'Marker',
                'marker_size',
                sel,
                tooltip: 'Radius of the white load marker',
              )
            else
              _color('Frame', 'outline_color', sel),
          ]),
        if (kind == 'graph') ..._graph(sel),
      ],
    );
  }

  Widget _tankIcon(Map<String, Object?> sel, String style) {
    final segments = style == 'segments';
    return _Section('Tank icon', [
      _check(
        'Hide while a notice shows',
        'hide_when_notice',
        sel['hide_when_notice'],
      ),
      _check(
        'Hide during a tank switch',
        'hide_when_switch',
        sel['hide_when_switch'],
        tooltip:
            'Step aside while the sidemount tanks differ by more than the '
            "switch pressure (a Descent's icons make room for the arrows)",
      ),
      _choice(
        'Style',
        'style',
        style,
        const ['fill', 'segments'],
        const ['Fill', 'Seg'],
      ),
      if (!segments) ...[
        _check(
          'Fill by pressure',
          'fill_level',
          sel['fill_level'],
          tooltip:
              'The fill empties as the pressure drops - full at Full, empty '
              'at Empty - the way a Descent X50i draws its sidemount icons',
        ),
        if (sel['fill_level'] == true) ...[
          _num(
            'Full',
            'full_bar',
            sel,
            tooltip: "Pressure (bar) that fills the icon - the tank's rated pressure",
          ),
          _num(
            'Empty',
            'empty_bar',
            sel,
            tooltip: 'Pressure (bar) at which the icon is empty - the critical pressure',
          ),
        ],
        _check(
          'Draw outline',
          'draw_outline',
          sel['draw_outline'],
          tooltip:
              'Rounded rectangle + cap drawn around the fill, for skins '
              'without a baked tank outline',
        ),
        if (sel['draw_outline'] == true) ...[
          _color('Outline', 'outline_color', sel),
          _num('Stroke', 'outline_width', sel),
          _num('Gap', 'outline_gap', sel),
        ],
      ] else ...[
        _num('Segments', 'segments', sel),
        _num('Gap', 'segment_gap', sel),
        _num(
          'Full at',
          'full_bar',
          sel,
          tooltip: 'Pressure (bar) at which every segment is lit',
        ),
        _color('Outline', 'outline_color', sel),
        _num('Stroke', 'outline_width', sel),
        _num('Padding', 'outline_gap', sel),
      ],
    ]);
  }

  /// An arc gauge or a segment bar (Python `_draw_arc` /
  /// `_draw_segment_bar`): its range in the field's raw units, the arc's
  /// thickness and angles, the segments and the colours.
  Widget _gauge(Map<String, Object?> sel, {required bool arc}) {
    CommitField field(String attr, String tooltip) => CommitField(
      key: ValueKey('el:${c.selectedIndex}:$attr'),
      value: _str(sel[attr]),
      tooltip: tooltip,
      onCommit: _commitTo(attr),
    );
    return _Section(arc ? 'Arc gauge' : 'Segment bar', [
      _pair(
        'Range',
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            field(
              'range_min',
              "The value at the empty end, in the field's raw units "
                  '(seconds for NDL / TTS, bar, m/min)',
            ),
            const Text('to', style: TextStyle(fontSize: 13)),
            field(
              'range_max',
              'The value at the full end (NDL 6000 s = 100 min)',
            ),
          ],
        ),
      ),
      if (arc) ...[
        _num('Thickness', 'thickness', sel),
        _num(
          'Start',
          'start_angle',
          sel,
          tooltip: "Degrees, 0 at 3 o'clock, clockwise (135: bottom left)",
        ),
        _num(
          'Sweep',
          'sweep',
          sel,
          tooltip: 'Degrees the track runs clockwise from Start',
        ),
      ],
      _num('Segments', 'segments', sel),
      _num(
        'Gap',
        'segment_gap',
        sel,
        tooltip: arc ? 'Degrees between segments' : 'Skin px between segments',
      ),
      _color('Color', 'color', sel),
      _color('Track', 'track_color', sel),
      if (!arc)
        _choice(
          'Colour by',
          'color_mode',
          sel['color_mode'],
          const ['value', 'position'],
          const ['Value', 'Place'],
        ),
    ]);
  }

  List<Widget> _graph(Map<String, Object?> sel) => [
    _Section('Graph colours and shading', [
      _color('Color', 'color', sel),
      _color('Ceiling', 'ceiling_color', sel),
      _color('Box', 'background_color', sel),
      _num(
        'Box opacity',
        'background_opacity',
        sel,
        tooltip:
            "The graph's background box and its border, 0 (none) to 1 (solid)",
      ),
      _color('Fill', 'fill_color', sel),
      _num(
        'Fill opacity',
        'fill_opacity',
        sel,
        tooltip: 'Area under the profile line, 0 (none) to 1 (solid)',
      ),
      _num(
        'Ceiling opacity',
        'ceiling_opacity',
        sel,
        tooltip:
            'The ceiling area (or, without Deco stops, the stop band), 0 to 1',
      ),
    ]),
    _Section('Graph options', [
      _check(
        'Deco stops',
        'deco_stops',
        sel['deco_stops'],
        tooltip:
            'Shade each logged deco stop and the ceiling separately, kept on '
            'the graph after they clear',
      ),
      if (sel['deco_stops'] == true) ...[
        _color('Stops', 'stops_color', sel),
        _num(
          'Stops opacity',
          'stops_opacity',
          sel,
          tooltip: 'The deco-stop steps, 0 to 1',
        ),
      ],
      _check(
        'Reveal profile over time',
        'reveal_profile',
        sel['reveal_profile'],
        tooltip:
            'Draw the depth line only up to the current time, instead of the '
            'whole dive',
      ),
      _check(
        'Stop label',
        'stop_label',
        sel['stop_label'],
        tooltip: 'Current deco stop (or NDL) next to the cursor',
      ),
      if (sel['stop_label'] == true) _num('Size', 'font_size', sel),
      _dropdown('Marker', sel['marker_style'], {
        for (final m in markerStyles) m: m,
      }, (v) => c.setSelectedAttr('marker_style', v)),
      _num('Size', 'marker_size', sel),
    ]),
  ];

  Widget _skin() {
    final skin = c.skinAttrs;
    final shape = skin['type'] == 'shape';
    num n(Object? v) => v is num ? v : 0;
    final anchors = c.anchorChoices;
    return SectionCard(
      children: [
        const Text(
          'Skin and placement',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        MutedText(
          shape
              ? 'Rounded rectangle ${skin['width']}×${skin['height']} px'
              : 'Image ${n(skin['native_width']).round()}×'
                    '${n(skin['native_height']).round()} px',
          size: 12,
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!shape) ...[
              _num('Scale', 'scale', skin, skin: true),
              _num('Opacity', 'opacity', skin, skin: true),
              OutlinedButton(
                onPressed: onReplaceImage,
                child: const Text('Replace image…'),
              ),
            ] else ...[
              _num('Width', 'width', skin, skin: true),
              _num('Height', 'height', skin, skin: true),
              _num('Radius', 'corner_radius', skin, skin: true),
              _num('Opacity', 'opacity', skin, skin: true),
              _color('Color', 'color', skin, skin: true),
            ],
            _dropdown('Anchor', skin['anchor'], {
              for (final MapEntry(:key, :value) in anchors.entries) value: key,
            }, (v) => c.setSkinAttr('anchor', v)),
            _num('Offset X', 'ref_offset_x', skin, skin: true),
            _num('Offset Y', 'ref_offset_y', skin, skin: true),
          ],
        ),
        const MutedText(
          'Offsets are in design pixels (1920-wide frame) from the anchor '
          'corner. In Frame preview you can also drag the skin.',
          size: 11,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      if (c.selectedIndex < 0 && !c.skinSelected)
        const MutedText(
          'Click an element on the canvas (or pick one in the list) to edit '
          'it. Click the skin background to edit placement.',
          size: 12,
        ),
      if (c.selectionCount >= 2) _multi(),
      if (c.selectedIndex >= 0) _element(context),
      if (c.skinSelected) _skin(),
    ],
  );
}

/// Keys the canvas acts on (Python `OverlayDesignerCanvas.qml`): arrows
/// nudge (Shift: 10 px), Delete removes, Escape clears the selection, + and
/// − resize; with Cmd/Ctrl: Z undo (Shift: redo), D duplicate, A all, C
/// copy, X cut, V paste, ] and [ reorder (Shift: to the front or back).
KeyEventResult designerKey(DesignerController c, KeyEvent event) {
  if (event is KeyUpEvent) {
    return KeyEventResult.ignored;
  }
  final keys = HardwareKeyboard.instance;
  final ctrl = keys.isControlPressed || keys.isMetaPressed;
  final shift = keys.isShiftPressed;
  final key = event.logicalKey;
  final step = shift ? nudgePxFast : nudgePx;
  void Function()? action;
  if (ctrl) {
    action = switch (key) {
      LogicalKeyboardKey.keyZ => shift ? c.redo : c.undo,
      LogicalKeyboardKey.keyD => c.duplicateSelected,
      LogicalKeyboardKey.keyA => c.selectAll,
      LogicalKeyboardKey.keyC => c.copySelected,
      LogicalKeyboardKey.keyX => c.cutSelected,
      LogicalKeyboardKey.keyV => c.paste,
      LogicalKeyboardKey.bracketRight =>
        shift ? c.bringToFront : () => c.moveSelectedLayer(1),
      LogicalKeyboardKey.bracketLeft =>
        shift ? c.sendToBack : () => c.moveSelectedLayer(-1),
      _ => null,
    };
  } else {
    action = switch (key) {
      LogicalKeyboardKey.arrowLeft => () => c.nudgeSelected(-step, 0),
      LogicalKeyboardKey.arrowRight => () => c.nudgeSelected(step, 0),
      LogicalKeyboardKey.arrowUp => () => c.nudgeSelected(0, -step),
      LogicalKeyboardKey.arrowDown => () => c.nudgeSelected(0, step),
      LogicalKeyboardKey.delete ||
      LogicalKeyboardKey.backspace => c.removeSelected,
      LogicalKeyboardKey.escape => c.clearSelection,
      LogicalKeyboardKey.add ||
      LogicalKeyboardKey.equal ||
      LogicalKeyboardKey.numpadAdd => () => c.resizeSelected(1),
      LogicalKeyboardKey.minus ||
      LogicalKeyboardKey.numpadSubtract => () => c.resizeSelected(-1),
      _ => null,
    };
  }
  if (action == null) {
    return KeyEventResult.ignored;
  }
  action();
  return KeyEventResult.handled;
}
