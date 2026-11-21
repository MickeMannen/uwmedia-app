# Dive plan reference

Output of the Python app's `models/dive_plan.py`,
`utils/dive_plan_engine.py` and `utils/dive_computers.py`. Needs the
Python repo and its venv at `$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `plan_cases.json.gz` | `249e1e9` (0.8.1) | 2026-11-14 | see the docstring of `tool/python_reference/plan_fixture.py` |
| `import_cases.json.gz` | `0fdefd8` (0.7.20) | 2026-11-13 | see the docstring of `tool/python_reference/import_fixture.py` |
| `writers_cases.json.gz` | `0fdefd8` (0.7.20), lxml as in its venv | 2026-11-13 | see the docstring of `tool/python_reference/writers_fixture.py` |
| `fit_cases.json.gz` | `0fdefd8` (0.7.20), garmin-fit-sdk 21.221.0 | 2026-11-13 | see the docstring of `tool/python_reference/fit_writer_fixture.py` |

Gzip-compressed JSON:

- `constants`, `defaults` (an empty plan's dump), `computers` and their
  lookups, `cells` (`simulated_cells`), `split_pairs`
  (`split_sidemount_pair`).
- `plans`: 30 plans as the JSON they are built from (`plan`): the plans of
  the Python tests (one gas, three gases picked by depth or by hand,
  bottoms with and without deco, trimix, rebreather with and without a
  bailout, sidemount), odd ones (a transit that runs late, waypoints out
  of order, no gas that covers a depth, a gas past its MOD, an unknown
  gas, no gases, no waypoints) and plans in the forms older versions
  saved. Per plan `model` (the dump and every question the model answers,
  per gas) and `engine`: the phases, the automatic gases and their
  warnings, the expansion (every seventh second), the simulation at a
  15 s resolution with every field, the planned ascent, the ascent from
  seven moments and the deco timeline every four minutes. A call that
  raises is `["raise", message]`.
- `invalid`: 24 plans with a value outside its range, which the model
  refuses.

`writers_cases.json.gz` (the log writers and the embedded plan):

- `cases`: ten invented dives (plans of `plan_cases`, some with their
  planned ascent added, with other computers, start times, a name with
  characters XML escapes) as `write_uddf` and `write_subsurface` wrote
  them (`uddf`, `subsurface`: the whole text), the plan and its embedded
  JSON, the local start, the machine's UTC offset the UDDF carries, and
  what `read_log_origin` says of each file. The files are synthetic
  profiles, kept as text inside the fixture; no person's dive log.
- `origins`: `read_log_origin` on ten small texts that are not the
  builder's, or only carry its mark or its plan.
- `plan_from_json`: eight texts.

"Now" is fixed at 2026-11-13 12:00:00 in the generator.

`import_cases.json.gz` (a plan rebuilt from a log, `utils/dive_plan_import.py`):

- `mix_names`, `mmss`, `pair_up`, `simplify`: the helpers.
- `logs`: 167 logs, named by the fixture that holds them (the synthetic
  logs of `dives/{uddf,subsurface,shearwater,subsurface_csv}.json` and
  the 20 files of `writers_cases.json.gz`), each parsed with the Python
  parsers and its first dive handed to `plan_from_log` with two base
  plans (`bases`): the plan's dump, or `raise` and the exception's type;
  `parse` when the file holds no dive. No log is copied into this file.
  Four of the logs have samples without a depth, which Python reads as
  0 m and the port leaves out of the profile (spec §10.8); the test
  passes over them.

`fit_cases.json.gz` (the Garmin FIT log, `parsers/fit_writer.py`, and the
plan in it):

- `cases`: 16 invented dives (plans of `plan_cases` with a Garmin
  computer, some with their planned ascent, serials that are a number,
  none or not a number, a name long enough for many chunks) as
  `write_fit` wrote them (`fit_base64`: the whole file), the plan, its
  packed form (`packed`: zlib and base64, before the cut into chunks),
  the local start and the machine's UTC offset the file's times depend
  on, what `read_log_origin` says of the file (`origin`) and what
  `plan_from_log` rebuilds from it on two base plans (`plans`). The files
  are synthetic profiles with invented serial numbers; no person's dive
  log and no real device.
- `refused`: plans `write_fit` refuses (not a Garmin computer, no
  samples) and its message.
- `others`: `read_log_origin` and `plan_from_log` on the two synthetic
  files of `dives/garmin.json` (named by their index there) and on a
  file that is not FIT.
- `profile`: the part of the SDK's profile the writer uses (message and
  field numbers, base types, scales, the numbers of the named values),
  which `lib/core/plan/fit_profile_subset.dart` is generated from
  (`--dart`) and checked against.
