# Rules engine reference

Output of the Python app's `utils/hud_rules_engine.py` with its
`hud_rules.json` (a copy of which is `assets/hud_rules.json` in this repo;
the fixture carries its SHA-256 and the test checks the copy against it).
Needs the Python repo and its venv at `$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `rules_cases.json` | `249e1e9` (0.8.1) | 2026-11-14 | see the docstring of `tool/python_reference/rules_fixture.py`; run from a clean `git archive 249e1e9` extract with the Python repo's venv |
| `notices_cases.json` | `249e1e9` (0.8.1) | 2026-11-14 | see the docstring of `tool/python_reference/notices_fixture.py`; run from a clean `git archive 249e1e9` extract with the Python repo's venv |

What is in it:

- `rule_config`: for 21 brand/model pairs (real, unknown, empty, annotation
  keys; Suunto EON Core, EON Steel Black, Nautic and the bare brand since
  Python 0.8.0) and every rule key, the block of `hud_rules.json` the
  lookup lands in.
- `dynamic_color`, `tank`, `badge`, `blink`, `failed_cells`: the small
  functions on values around their limits (`ascent_rate` bands too). The
  `badge` cases also run under four page `rules` blocks (`overrides`),
  which layer last since Python 0.8.0.
- `dives`: twelve invented dives (safety stops, a reset, deco with logged
  stops, the computer's own alerts, sidemount tanks, a rebreather with a
  bailout, samples without a depth; a Suunto safety stop paused deeper
  than 6 m and Suunto deco whose stop is the logged ceiling, every 10 s),
  the others every 20 s, and per waypoint
  the state, stop phase, deco-stop phase, ceiling, sidemount target,
  safety-stop phase and status, deco-clear seconds, NDL before clear,
  safety-stop text, average depth and the rebreather colours, for up to
  fourteen brand/model/override combinations (the three Suunto computers
  on every dive). Each column is a list of
  `[value, count]` runs.

When `hud_rules.json` changes in the Python app, copy it to
`assets/hud_rules.json` and regenerate this fixture in the same change.

`notices_cases.json` (`utils/hud_notices.py`, `utils/hud_gas.py`,
`utils/units.py`):

- `units`: `normalize`, `resolve_units`, and per system the conversions,
  stop depths, labels and formatted depths, pressures and temperatures of
  31 values with six `display` rules.
- `notice_rules`: the ids of each brand's `notices` and
  `persistent_notices`, and its `notice_style`.
- `dives`: ten invented dives (four of `rules_fixture.py`, six of its
  own: limits and alerts, sidemount, a steady consumption, setpoint
  changes, single waypoints, and Suunto's logged notifications with a
  short and a long fast ascent, every second). Brands include Suunto EON
  Core (metric and imperial) and Nautic. Per brand and unit system, run-length
  columns of the active notice (with the dive and from the waypoint
  alone), the persistent notice, the gas time remaining and the MOD. The
  notice cache is emptied between unit systems.
