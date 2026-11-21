# config.yaml and color.yaml reference

Output of the Python app's `utils/config.py` (`ConfigManager`),
`utils/color_profiles.py` and `utils/color_params.py`, and of PyYAML's
`yaml.dump(default_flow_style=False, sort_keys=False)`, which the port's
YAML writer follows. Needs the Python repo and its venv at
`$PYTHON_REPO`. The generator points both modules at
a temporary folder; the user's real config folder is not touched.

| File | Python commit | Made | Command |
|---|---|---|---|
| `config_cases.json` | `0fdefd8` (0.7.20), PyYAML 6.0.3 | 2026-11-13 | see the docstring of `tool/python_reference/config_fixture.py` |

- `dump`: what PyYAML writes for 84 texts (as a value, as a key, in a
  list: words YAML takes for numbers, bools, null or dates, characters
  that mean something to YAML, spaces at the ends, non-ASCII, control
  characters), for 24 numbers, bools and null, and for eight nested
  objects (the one with keys that are not text has `null` for its JSON).
- `tanks`: 14 `config.yaml` texts (none, empty, broken, unquoted serials,
  comments, other content, a list or text instead of a map: `raise`) with
  the mapping, some names and an order, and the file's text and the
  mapping after each of eight changes (`save_config`, `set_tank_name`,
  `remove_tank`, `set_tank_mapping`).
- `color`: the Python app's bundled `color.yaml`; `load_merged_color_profiles`
  for four bundled texts by seven user texts; `save_user_profile` of four
  names into seven user texts.
- `param_groups`: `PARAM_GROUPS`.
