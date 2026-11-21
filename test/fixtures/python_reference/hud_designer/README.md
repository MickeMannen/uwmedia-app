# Overlay Designer reference

Output of the Python app's designer logic: `utils/dummy_telemetry.py`,
`utils/hud_designer.py`, `utils/overlay_document.py` and
`utils/template_store.py`. Needs the Python repo and its venv at
`$PYTHON_REPO`. All five files are gzip-compressed
JSON; nothing in the Python repo or the user's folders is written (the
store scenarios run on copies in a temporary folder).

| File | Python commit | Made | Command (see the docstring of) |
|---|---|---|---|
| `dummy_cases.json.gz` | `7e62799` (0.8.2) | 2026-11-15 | `tool/python_reference/dummy_fixture.py` |
| `designer_cases.json.gz` | `7e62799` (0.8.2), Pillow as for `renderer/` | 2026-11-15 | `tool/python_reference/designer_fixture.py` |
| `document_cases.json.gz` | `7e62799` (0.8.2) | 2026-11-15 | `tool/python_reference/document_fixture.py` |
| `store_cases.json.gz` | `7e62799` (0.8.2) | 2026-11-15 | `tool/python_reference/store_fixture.py` |
| `template_sweep.json.gz` | `7e62799` (0.8.2), Pillow as for `renderer/` | 2026-11-15 | `tool/python_reference/template_sweep_fixture.py` |

All five were made from a clean `git archive 7e62799` of the Python repo
(release 0.8.2) in a scratch folder on 2026-11-15 (the same way as the
`d3ecc09` and 0.8.0 ones before them), with the Python repo's venv and
that folder as the working directory in place of the Python repo's root
in the commands. `dummy_cases` changed with 0.8.2's sidemount dive (one
cylinder until 7:00); the others with the 0.8.2 templates and renderer.

- `dummy_cases`: the sample dive in six forms (one tank, sidemount, no
  variant, no tank, rebreather, rebreather sidemount), each waypoint with
  what the rules engine and the notices say for four brand/model pairs;
  `apply_state` and `forced_dive` for every state from eleven moments
  (231 cases, with the forced history).
- `designer_cases`: anchors, skin positions and sizes; element kinds,
  defaults, parsing, names and field lists; hit tests; for every bundled
  page (and for a third of them the renderer fixture's "turned", "aligned"
  and "scaled" copies, 232 layouts) the parsed elements and, per situation
  (no telemetry, the dive at 20:30 in metres and for half of them in feet,
  two forced states), each element's text or badge lines, its bounds and
  its measured box, and the result of every alignment mode on four
  selections; 292 cases of elements the pages do not have (arc gauges and
  segment bars among them). `measures` holds
  Pillow's ink box and length for every text measured (9417 at `7e62799`), keyed by
  font file and size, for the port to replay, and `glyphs` (since
  `d3ecc09`) whether a font lacked a badge's arrow (empty here: no
  page case draws one). "Arial" is the bundled Liberation Sans.
- `document_cases`: every bundled layout file (131) loaded as a document,
  with what it reports and its layouts for the renderer and for saving;
  six documents through 72 edits, undos and redos, the whole state after
  each. Paths start with `ROOT` for the templates folder.
- `template_sweep`: what `tests/test_template_sweep.py` reports for
  every bundled page and variant (115) in each unit system, before the
  known-issue list is applied ({issue key: [details]}, 30 keys, all of
  them on the list), the reports for four invented shape layouts (text on
  an arc's band, a round and a square screen, elements hidden by state,
  circuit and notice), `tests/template_sweep_known.json` verbatim, the
  page list, skin sizes and rebreather pages, and Pillow's measurements
  (`measures`, `metrics`, `glyphs`) for the port to replay. Made from the
  clean `7e62799` extract; the sweep with
  this machine's own fonts gives the same reports.
- `store_cases`: nine scenarios, 46 calls of `save_template`,
  `save_template_as` and `create_computer` in the user's mode and in the
  Python app's checkout mode; per call the arguments, the user's files and
  the changes to the bundled copy before it, what it returned or raised,
  the JSON files it wrote (text) and the skin images it copied (named by
  a file of the same bytes) or converted. Paths start with `bundled/`,
  `user/` or `/TMP/`.
