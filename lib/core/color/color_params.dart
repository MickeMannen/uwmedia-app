/// The colour engine's tuning parameters as the Color Tuning page offers
/// them (Python `utils/color_params.py` `PARAM_GROUPS`): the groups, and
/// per parameter its `color.yaml` key, label, range, default and whether it
/// is a whole number.
library;

import 'package:uwmedia_app/core/util/py_round.dart';

/// One parameter's slider.
typedef ColorParam = ({
  String key,
  String label,
  double min,
  double max,
  double defaultValue,
  bool isInt,
});

/// The sliders' groups in the page's order.
const List<(String, List<ColorParam>)> colorParamGroups = [
  (
    'Color Restoration & Blend',
    [
      (
        key: 'cifval',
        label: 'Blend Weight',
        min: 0.0,
        max: 1.0,
        defaultValue: 1.0,
        isInt: false,
      ),
      (
        key: 'red_threshold',
        label: 'Red Threshold',
        min: 0.0,
        max: 1.0,
        defaultValue: 0.3,
        isInt: false,
      ),
      (
        key: 'red_scale',
        label: 'Red Scale',
        min: 0.01,
        max: 1.0,
        defaultValue: 0.2,
        isInt: false,
      ),
      (
        key: 'blue_threshold',
        label: 'Blue Threshold',
        min: 0.0,
        max: 1.0,
        defaultValue: 0.3,
        isInt: false,
      ),
      (
        key: 'blue_scale',
        label: 'Blue Scale',
        min: 0.01,
        max: 2.0,
        defaultValue: 0.6,
        isInt: false,
      ),
    ],
  ),
  (
    'Black Point Floors',
    [
      (
        key: 'black_point_cutoff',
        label: 'CDF Cutoff Floor',
        min: 0.0001,
        max: 0.01,
        defaultValue: 0.001,
        isInt: false,
      ),
    ],
  ),
  (
    'Gray World White Balance',
    [
      (
        key: 'gw_mask_mult',
        label: 'Mask Multiplier',
        min: 0.5,
        max: 3.0,
        defaultValue: 1.5,
        isInt: false,
      ),
      (
        key: 'gw_mask_fallback',
        label: 'Mask Fallback Weight',
        min: 0.0,
        max: 1.0,
        defaultValue: 0.2,
        isInt: false,
      ),
      (
        key: 'gw_blur_radius',
        label: 'Gaussian Blur Radius',
        min: 1,
        max: 31,
        defaultValue: 9,
        isInt: true,
      ),
      (
        key: 'gw_blur_sigma',
        label: 'Gaussian Blur Sigma',
        min: 0.1,
        max: 5.0,
        defaultValue: 1.8,
        isInt: false,
      ),
      (
        key: 'gw_isolation_threshold',
        label: 'Isolation Variation',
        min: 0.001,
        max: 0.5,
        defaultValue: 0.07,
        isInt: false,
      ),
      (
        key: 'gw_isolation_min_sum',
        label: 'Isolation Min Sum',
        min: 10,
        max: 500,
        defaultValue: 100,
        isInt: true,
      ),
    ],
  ),
  (
    'De-haze Adjustment',
    [
      (
        key: 'dehaze_sat_cutoff',
        label: 'Saturation Cutoff',
        min: 0.01,
        max: 0.5,
        defaultValue: 0.1,
        isInt: false,
      ),
      (
        key: 'dehaze_sat_scale',
        label: 'Saturation Divisor',
        min: 0.1,
        max: 2.0,
        defaultValue: 0.75,
        isInt: false,
      ),
      (
        key: 'dehaze_min',
        label: 'Dehaze Min Bound',
        min: 0.5,
        max: 1.0,
        defaultValue: 0.81,
        isInt: false,
      ),
      (
        key: 'dehaze_max',
        label: 'Dehaze Max Bound',
        min: 1.0,
        max: 2.0,
        defaultValue: 1.0,
        isInt: false,
      ),
    ],
  ),
  (
    'Exposure Normalization',
    [
      (
        key: 'exposure_cdf_cutoff',
        label: 'CDF Brightness Cutoff',
        min: 0.001,
        max: 0.1,
        defaultValue: 0.01,
        isInt: false,
      ),
      (
        key: 'exposure_numerator',
        label: 'Target Reference Brightness',
        min: 0.1,
        max: 2.0,
        defaultValue: 0.5,
        isInt: false,
      ),
      (
        key: 'exposure_min',
        label: 'Exposure Min Mult',
        min: 0.5,
        max: 2.0,
        defaultValue: 1.0,
        isInt: false,
      ),
      (
        key: 'exposure_max',
        label: 'Exposure Max Mult',
        min: 1.0,
        max: 4.0,
        defaultValue: 2.0,
        isInt: false,
      ),
    ],
  ),
  (
    'OKLCh Blue Hue Translation',
    [
      (
        key: 'bh_min_idx',
        label: 'Min Hue Scanning Bin',
        min: 0,
        max: 255,
        defaultValue: 155,
        isInt: true,
      ),
      (
        key: 'bh_max_idx',
        label: 'Max Hue Scanning Bin',
        min: 0,
        max: 255,
        defaultValue: 218,
        isInt: true,
      ),
      (
        key: 'bh_decay',
        label: 'Scan Decay Weight',
        min: 0.0,
        max: 1.0,
        defaultValue: 0.85,
        isInt: false,
      ),
      (
        key: 'bh_fallback',
        label: 'Fallback Blue Hue',
        min: 0.0,
        max: 1.0,
        defaultValue: 0.67,
        isInt: false,
      ),
    ],
  ),
  (
    'Final Adjustments',
    [
      (
        key: 'sharpness',
        label: 'Sharpness',
        min: 0.0,
        max: 3.0,
        defaultValue: 0.0,
        isInt: false,
      ),
      (
        key: 'darkness',
        label: 'Darkness',
        min: -1.0,
        max: 1.0,
        defaultValue: 0.0,
        isInt: false,
      ),
    ],
  ),
];

/// Every parameter by its key.
final Map<String, ColorParam> colorParamsByKey = {
  for (final (_, params) in colorParamGroups)
    for (final param in params) param.key: param,
};

/// A fractional slider moves in steps of one over this.
const colorSliderScale = 10000;

/// A new profile's name is at most this long.
const newProfileNameMax = 10;

/// [value] on its slider's grid, as Python keeps the slider position:
/// whole numbers cut to whole (`int(value)`), fractions kept to four
/// decimals (`round(value * 10000)`).
double onSliderGrid(double value, bool isInt) => isInt
    ? value.truncateToDouble()
    : pyRound(value * colorSliderScale) / colorSliderScale;

/// A parameter's value as the page shows it beside its slider.
String colorValueText(double value, bool isInt) =>
    isInt ? '${pyRound(value)}' : pyFormatFixed(value, 3);

/// One slider of the phones' Color Tuning lite (spec §9.3): what it shows
/// for a profile's values, and the values it sets.
typedef LiteSlider = ({
  String key,
  String label,
  double min,
  double max,
  bool photosOnly,
  double Function(Map<String, Object?> values) read,
  Map<String, double> Function(double value) write,
});

double _value(Map<String, Object?> values, String key) {
  final v = values[key];
  return v is num ? v.toDouble() : colorParamsByKey[key]!.defaultValue;
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

// A restore "strength" from 0 (little) to 1 (most) as a threshold and a
// scale (the factor is ((G - C) / G - threshold) / scale, so a lower pair
// restores more); 0.5 lands on the bundled defaults. Proposed 2026-11-13,
// for the owner to confirm (roadmap section D).
LiteSlider _strength(String key, String label, String channel, double span) => (
  key: key,
  label: label,
  min: 0.0,
  max: 1.0,
  photosOnly: false,
  read: (values) => _clamp01(1 - _value(values, '${channel}_threshold') / 0.6),
  write: (s) => {
    '${channel}_threshold': onSliderGrid(0.6 * (1 - s), false),
    '${channel}_scale': onSliderGrid(0.01 + (1 - s) * span, false),
  },
);

LiteSlider _direct(String key, String label, {bool photosOnly = false}) {
  final param = colorParamsByKey[key]!;
  return (
    key: key,
    label: label,
    min: param.min,
    max: param.max,
    photosOnly: photosOnly,
    read: (values) => _value(values, key),
    write: (v) => {key: onSliderGrid(v, param.isInt)},
  );
}

/// The lite page's sliders, one per stage of the correction (spec §9.3);
/// the grey-world and hue-scan parameters keep the profile's values.
final List<LiteSlider> liteSliders = [
  _direct('cifval', 'Blend'),
  _strength('red_restore', 'Red restore', 'red', 0.39),
  _strength('blue_reduce', 'Blue reduce', 'blue', 1.19),
  _direct('dehaze_min', 'De-haze'),
  _direct('exposure_max', 'Exposure'),
  _direct('darkness', 'Darkness'),
  _direct('sharpness', 'Sharpness', photosOnly: true),
];
