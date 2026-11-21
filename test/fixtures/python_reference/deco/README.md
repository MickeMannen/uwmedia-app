# Deco engine reference

Output of the Python app's `utils/deco_engine.py`,
`utils/gas_consumption.py` and `parsers/deco_pass.py` on invented
profiles; no log file is involved. Needs the Python repo and its venv at
`$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `deco_cases.json` | `0fdefd8` (0.7.20), Python 3.14.10, macOS arm64 | 2026-11-12 | see the docstring of `tool/python_reference/deco_fixture.py` |

What is in it:

- `engine`: tissue pressures, CNS, ceilings at five gradient factors and
  the gradient factor at five pressures, fresh and after each `update`.
- `cns_increment`, `ccr_effective_fractions`, `mod_meters`, `ndl`: the
  small functions on values around their limits.
- `process_waypoints`: ten profiles through `DiveDecompressor` (square,
  multi-gas deco, out of order, rebreather with a bailout, safety stop,
  two dives through one decompressor). The TTS is kept for every second;
  the other values for every 13th second.
- `sac_gtr`: `fill_sac_and_gtr` on eight dives, the resulting
  `pressure_sac` and `air_remaining` per waypoint.
- `deco_pass`: `apply_deco_and_gas` on seven dives, the fields it can
  change per waypoint, and `surf_gf` from the engine (which that function
  leaves out; the port's one shared pass sets it, spec §10.16).
- `parse_gf`, `deco_gas`.

The floats are compared with a relative tolerance of 1e-12: the Dart code
does the same operations in the same order, so on one machine they agree
to the last bits, and the tolerance leaves room for another platform's
`exp()`. Values Python rounds (GF99, SurfGF, PO2, SAC) and the integers
are compared exactly.
