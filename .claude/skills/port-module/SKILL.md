---
name: port-module
model: fable
description: Port one module of the Python UWMedia app to Dart with parity against the Python code and spec - dive model, parsers, deco engine, rules engine, renderer geometry, colour maths, date/timezone logic, filename formats. Use when asked to port, translate or implement one of these from the Python app.
---

# Porting a Python module to Dart

The Python app at `~/development/uwmedia` is the reference;
`docs/spec.md` (§4 model, §5 renderer, §6 colour, §7 module list, §10
issues) is the spec. Never write into the Python repo.

1. **Scope the module.** Name the Python file(s) and the spec section.
   Ask the `python-reference` agent for the algorithm, every constant and
   default with `path:line`, the `None`-able values, the fallback orders,
   and the list of pytest cases that cover it. Do not port from memory.
2. **Check the §10 list.** If an issue applies (missing values defaulting
   to 0, blink, waypoint distance, Sony XMP, NVENC, pkill), confirm it is
   decided in `docs/roadmap_v0.1.0.md` section A; port the fix, and leave a comment naming
   the §10 item at the spot. Any other difference from Python is a bug.
3. **Get the oracle first.** If `test/fixtures/python_reference/` has no
   fixture for this module, generate one with the `/fixtures` skill
   before writing Dart. Expectations come from Python, never from the
   Dart output.
4. **Write the Dart.** Pure logic goes under `lib/core/<area>/` with no
   `dart:io` side effects, no UI, no plugins. Keep spec §4 field names
   (camelCase in Dart, snake_case in JSON with explicit mapping), units
   and nullability. Document each non-obvious constant with the Python
   `path:line` it came from. Follow `analysis_options.yaml`; the hook
   formats on save.
5. **Write the tests** under `test/<area>/<module>_test.dart`: one test
   per pytest case with the same inputs and expectations, plus a parity
   test that loads the Python fixture and compares (exact for ints and
   strings, a stated tolerance for floats, with a reason). Tag as
   `CONTRIBUTING.md` says. Tests write only to temp dirs.
6. **Run** `tool/run_tests.sh 1` (the `/test` skill) and fix what fails
   without weakening a test.
7. **Review** with the `port-reviewer` agent; fix its findings or argue
   each one with the Python line that proves the Dart right.
8. **Record**: tick the item in `docs/roadmap_v0.1.0.md` section B, correct the spec if the
   code proved a sentence wrong, and add a `CHANGELOG.md` bullet only if a
   user would notice (a ported library module usually is not one).
