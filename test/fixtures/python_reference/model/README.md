# Dive model reference

Output of the Python app's `models/dive.py` and `models/manager.py` on
invented values; no log file is involved. Needs the Python repo and its
venv at `$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `model_cases.json` | `249e1e9` (0.8.1) | 2026-11-14 | see the docstring of `tool/python_reference/model_fixture.py` |

What is in it:

- `dives`: five dives as `model_dump(mode="json")`, with each waypoint's
  computed values (`gasmix`, `gas_percent`, `circuit`, `diluent_po2`, the primary and
  secondary tank), the dive's `is_ccr`, `max_depth`, `duration`, and the
  index `get_waypoint_at` returns for a list of times.
- `gasmix`, `diluent_po2`: sweeps over values that sit on a rounding half.
- `round`: Python `round(x)` and `round(x, 2)` for the helper in
  `lib/core/util/py_round.dart`.
- `manager`: batches passed to `DiveManager.add_dives`, the dives held
  afterwards in order, and `find_dive_for_timestamp` for a list of times.
