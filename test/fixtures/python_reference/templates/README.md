# Template tree reference

Output of the Python app's `utils/layouts.py`: `list_templates`,
`resolve_template_state` and `list_layouts`. Needs the Python repo and its
venv at `$PYTHON_REPO`. The generator points the
user's template and layout folders at a temporary folder.

| File | Python commit | Made | Command |
|---|---|---|---|
| `templates_cases.json` | `7e62799` (0.8.2) | 2026-11-15 | see the docstring of `tool/python_reference/templates_fixture.py`, run in a clean `git archive 7e62799` of the Python repo in place of its root |

Paths start with `bundled/` or `user/` in place of the two roots. The
bundled tree is the Python app's `overlays/templates`, of which
`assets/overlays/templates` in this repo is a copy; the test reads the
copy, so the fixture also shows the two are the same tree.

- `trees`: five cases, each with the files of a user tree (`user_files`,
  path to text): none; a page beside a bundled computer's pages with one
  that collides; a brand of its own; a computer with variants, states and
  a page without a folder; odd content (a broken manifest, a folder
  without one, no pages, stray files, an id twice, a brand that differs
  from a bundled one in case only). Per case the `templates` map, the
  `warnings` printed, and `resolved`: the state file for every page,
  variant and state of the user's computers and some bundled ones, with
  ones that do not exist.
- `bundled_layouts`, `layouts`: the legacy packages in the Python app's
  `overlays` folder and `list_layouts` with three sets of user files.
