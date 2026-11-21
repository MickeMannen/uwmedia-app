/// The colour profiles of `color.yaml` and the tuning parameters (Python
/// `utils/color_profiles.py` and `utils/color_params.py`). Text in, text
/// out: where the two files lie belongs to the settings storage.
library;

import 'package:uwmedia_app/core/config/yaml_text.dart';

/// The file name of the colour profiles, bundled and the user's own.
const colorYamlName = 'color.yaml';

/// One tuning parameter: its key in a profile, the slider's label, range
/// and default, and whether it is a whole number.
typedef ColorParam = ({
  String key,
  String label,
  num min,
  num max,
  num fallback,
  bool isInt,
});

/// The tuning parameters by group, in the order the Color Tuning page
/// shows them.
const List<(String, List<ColorParam>)> colorParamGroups = [
  (
    'Color Restoration & Blend',
    [
      (
        key: 'cifval',
        label: 'Blend Weight',
        min: 0.0,
        max: 1.0,
        fallback: 1.0,
        isInt: false,
      ),
      (
        key: 'red_threshold',
        label: 'Red Threshold',
        min: 0.0,
        max: 1.0,
        fallback: 0.3,
        isInt: false,
      ),
      (
        key: 'red_scale',
        label: 'Red Scale',
        min: 0.01,
        max: 1.0,
        fallback: 0.2,
        isInt: false,
      ),
      (
        key: 'blue_threshold',
        label: 'Blue Threshold',
        min: 0.0,
        max: 1.0,
        fallback: 0.3,
        isInt: false,
      ),
      (
        key: 'blue_scale',
        label: 'Blue Scale',
        min: 0.01,
        max: 2.0,
        fallback: 0.6,
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
        fallback: 0.001,
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
        fallback: 1.5,
        isInt: false,
      ),
      (
        key: 'gw_mask_fallback',
        label: 'Mask Fallback Weight',
        min: 0.0,
        max: 1.0,
        fallback: 0.2,
        isInt: false,
      ),
      (
        key: 'gw_blur_radius',
        label: 'Gaussian Blur Radius',
        min: 1,
        max: 31,
        fallback: 9,
        isInt: true,
      ),
      (
        key: 'gw_blur_sigma',
        label: 'Gaussian Blur Sigma',
        min: 0.1,
        max: 5.0,
        fallback: 1.8,
        isInt: false,
      ),
      (
        key: 'gw_isolation_threshold',
        label: 'Isolation Variation',
        min: 0.001,
        max: 0.5,
        fallback: 0.07,
        isInt: false,
      ),
      (
        key: 'gw_isolation_min_sum',
        label: 'Isolation Min Sum',
        min: 10,
        max: 500,
        fallback: 100,
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
        fallback: 0.1,
        isInt: false,
      ),
      (
        key: 'dehaze_sat_scale',
        label: 'Saturation Divisor',
        min: 0.1,
        max: 2.0,
        fallback: 0.75,
        isInt: false,
      ),
      (
        key: 'dehaze_min',
        label: 'Dehaze Min Bound',
        min: 0.5,
        max: 1.0,
        fallback: 0.81,
        isInt: false,
      ),
      (
        key: 'dehaze_max',
        label: 'Dehaze Max Bound',
        min: 1.0,
        max: 2.0,
        fallback: 1.0,
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
        fallback: 0.01,
        isInt: false,
      ),
      (
        key: 'exposure_numerator',
        label: 'Target Reference Brightness',
        min: 0.1,
        max: 2.0,
        fallback: 0.5,
        isInt: false,
      ),
      (
        key: 'exposure_min',
        label: 'Exposure Min Mult',
        min: 0.5,
        max: 2.0,
        fallback: 1.0,
        isInt: false,
      ),
      (
        key: 'exposure_max',
        label: 'Exposure Max Mult',
        min: 1.0,
        max: 4.0,
        fallback: 2.0,
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
        fallback: 155,
        isInt: true,
      ),
      (
        key: 'bh_max_idx',
        label: 'Max Hue Scanning Bin',
        min: 0,
        max: 255,
        fallback: 218,
        isInt: true,
      ),
      (
        key: 'bh_decay',
        label: 'Scan Decay Weight',
        min: 0.0,
        max: 1.0,
        fallback: 0.85,
        isInt: false,
      ),
      (
        key: 'bh_fallback',
        label: 'Fallback Blue Hue',
        min: 0.0,
        max: 1.0,
        fallback: 0.67,
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
        fallback: 0.0,
        isInt: false,
      ),
      (
        key: 'darkness',
        label: 'Darkness',
        min: -1.0,
        max: 1.0,
        fallback: 0.0,
        isInt: false,
      ),
    ],
  ),
];

/// Every tuning parameter by its key.
final Map<String, ColorParam> colorParamsByKey = {
  for (final (_, params) in colorParamGroups)
    for (final param in params) param.key: param,
};

Map<String, Map<String, Object?>> _profiles(String? text) => {
  for (final MapEntry(:key, :value) in readYamlMap(text).entries)
    // A name with nothing under it is a profile of defaults.
    if (value is YamlPlain && value.value == null)
      key: <String, Object?>{}
    else if (value is Map<String, Object?>)
      key: {
        for (final MapEntry(key: name, value: setting) in value.entries)
          name: yamlValue(setting),
      },
};

/// The bundled profiles with the user's own layered on top: a user profile
/// replaces the bundled one of the same name as a whole. Each argument is
/// the text of a `color.yaml`, or `null` when there is no such file; a
/// file that cannot be read counts as empty. With no profile at all there
/// is still an empty `default`.
///
/// An entry that is not a set of parameters (`note: text`) is left out;
/// Python passes it on as a profile.
Map<String, Map<String, Object?>> mergedColorProfiles(
  String? bundled,
  String? user,
) {
  final merged = {..._profiles(bundled), ..._profiles(user)};
  return merged.isEmpty ? {'default': {}} : merged;
}

/// The text of the user's `color.yaml` ([userText], `null` when there is
/// none yet) with the profile [name] set to [values]; every other profile
/// in the file stays as it is. Saving a profile named like a bundled one
/// makes a user profile that takes its place.
String withUserProfile(
  String? userText,
  String name,
  Map<String, Object?> values,
) => writeYaml({...readYamlMap(userText), name: values});
