# Parsed dives reference

What the Python app's parsers make of invented logs, as
`Dive.model_dump(mode="json")`. Needs the Python repo and its venv at
`$PYTHON_REPO`.

The log texts are part of each fixture (as base64 of the file's bytes), so
the Dart test parses exactly what Python parsed. Every value in them is
made up by the generator script: no device serial, no personal data, no
real dive. A fixture made from a real log never goes here (see
`CONTRIBUTING.md`).

| File | Python commit | Made | Command |
|---|---|---|---|
| `subsurface_csv.json` | `0fdefd8` (0.7.20) | 2026-11-12 | see the docstring of `tool/python_reference/subsurface_csv_fixture.py` |
| `shearwater.json` | `0fdefd8` (0.7.20) | 2026-11-12 | see the docstring of `tool/python_reference/shearwater_fixture.py` |
| `uddf.json` | `0fdefd8` (0.7.20) | 2026-11-12 | see the docstring of `tool/python_reference/uddf_fixture.py` |
| `subsurface.json` | `0fdefd8` (0.7.20) | 2026-11-12 | see the docstring of `tool/python_reference/subsurface_fixture.py` |
| `garmin.json` | `0fdefd8` (0.7.20), garmin_fit_sdk 21.221.0 | 2026-11-12 | see the docstring of `tool/python_reference/garmin_fixture.py` |
| `fit_edit_cases.json.gz` | `0fdefd8` (0.7.20), garmin_fit_sdk 21.221.0 | 2026-11-13 | see the docstring of `tool/python_reference/fit_edit_fixture.py` |
| `suunto.json` | `249e1e9` (0.8.1) | 2026-11-14 | see the docstring of `tool/python_reference/suunto_fixture.py` |

`subsurface_csv.json`: twelve Subsurface dive-profile CSVs through
`SubsurfaceCSVParser` and through `parse_log_file`; 26 file names and
contents through `detect_log_format`; `parse_time_str` and
`is_subsurface_profile_header` on odd text.

The port's dives differ from these in one field on purpose: `surf_gf`,
which Python's `parsers/deco_pass.py` leaves empty for this format and the
port's one shared deco pass sets (spec §10.16).

`shearwater.json`: 39 Shearwater Cloud XML and CSV exports (the ones of
the Python tests plus odd ones) through `read_tables` and
`ShearwaterParser`, and `_divemode` on odd text. The dives are dumped
without their `None` fields. Three things differ from what the Python app
itself gives for this format, all from the port's one shared deco pass
(spec §10.16):

- SAC and gas time are filled only when the export has no SAC at all. The
  generator parses with that rule in place of `parsers/deco_pass.py`'s
  (see its docstring), so the fixture is the oracle for it.
- `surf_gf` is set by the port and absent here.
- `gf_low`/`gf_high` are kept on the dive by the port and absent here.

`uddf.json`: 55 UDDF files through `UDDFParser`: the texts of the Python
tests (named after the test), odd ones (no namespace, CDATA, a mix without
an id, date forms, encodings, names in document order) and two dives
written by the app's own UDDF writer from invented plans. Each dive also
has its `is_ccr`, and the `circuit` and `gasmix` of every waypoint. The
port differs from these on purpose in two fields (spec §10.8): a missing
or unreadable temperature, and a sample without a `<depth>`, are `null`
where Python stores 0.0.

`subsurface.json`: 38 Subsurface XML files through `SubsurfaceParser` (the
texts of the Python tests, odd ones, and two dives written by the app's
own Subsurface writer), one of them with a tank-name mapping; the unit
helpers on odd text; `map_tank_name` and `order_tanks` of
`utils/config.py` on a mapping set in the script (no `config.yaml` is
read or written). The port differs from these on purpose (spec §10.8)
where a value is missing or unreadable: depth, temperature, an unreadable
TTS or NDL, and the pressure of a cylinder without a reading are `null`
where Python stores 0, and so there is no SAC where Python computes one of
0 from such a pressure.

`garmin.json`: 22 sets of decoded FIT messages through `GarminParser` (the
dicts of the Python tests, named after the test, and odd ones), and two FIT
files written by the app's own FIT writer from invented plans, with the
messages the Python FIT SDK decodes from them and the dives; also
`timezone_from_pair` and `setpoint_timeline`. The port differs from these
on purpose (spec §10.8): what a record does not carry is `null` where
Python stores 0 (depth, temperature, stop depth and time, TTS, gas time,
ascent rate, tissue load, the SAC values, heart rate, CNS, a tank's
pressure).

`suunto.json`: 26 Suunto app JSON exports (the EON Core and Nautic of
`tests/test_suunto.py`, a 40 m trimix dive with a logged ceiling, other JSON
files, bad JSON, not-a-dive, zone and time forms, odd gas numbers, events
and values), as base64, with the registry's format, the dives of
`parse_log_file` (without `None` fields; `gasmix` and `gas_percent` per
waypoint), `logged_plan_parts` and `plan_from_log` on the default base;
plus `is_suunto_json` on odd heads. The port sets `surf_gf` where Python
leaves it empty (spec §10.16); everything else is compared. A time with a
zone against one without is a `TypeError` in Python and a `FormatException`
here. Also made 2026-11-14: `model/model_cases.json` has `gas_percent`.

`fit_edit_cases.json.gz` (gzip-compressed JSON, made by
`tool/python_reference/fit_edit_fixture.py`, Python `0fdefd8`, 0.7.20,
2026-11-13): the Log Viewer's "Adjust time" (`parsers/fit_time.py`) and
"Merge dives" (`parsers/fit_merge.py`).

- `sources`: 19 invented FIT files as base64: six dives written by the
  app's own FIT writer (air, nitrox, three gases, a rebreather; minutes to
  hours apart) and files built by hand in the generator (compressed
  timestamps, big-endian messages, developer fields, a 14-byte header,
  messages no profile knows, two files in one, a file cut short, text
  that is not FIT). No person's dive log and no real device's serial.
- `adjust`: 18 runs of `adjust_fit_time` (source, new local start, UTC
  offset): `fit_activity_time` before and after, the shift, and the
  result's length and SHA-256, or the exception and its message.
- `merge`: 22 pairs through `merge_fit_dives`, each with the gap kept and
  closed: the `MergeResult` and the result's length and SHA-256, or the
  message.
- `viewer`: `parse_local_start`, `parse_utc_offset`, `format_utc_offset`,
  `adjusted_name`, `merged_name`, and `merge_candidates` with
  `candidate_label` on the six written dives.
- `constants`: the message and field numbers the merge takes from the
  SDK's profile.

`--full <folder>` on the generator writes the result files themselves
(into a scratch folder), for looking at a difference.

