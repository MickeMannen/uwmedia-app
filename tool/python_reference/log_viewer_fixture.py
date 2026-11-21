"""Parity fixture for the Log Viewer's display logic (spec §0, §7): the
pure functions of uwmedia/backends/log_viewer_backend.py that turn a
parsed dive into what the page shows: the dive list's row, the details
pane (fields, tanks, chart samples, PO2 strip, channels, events) and the
samples table with its filter.

The dives are the ones the parser fixtures of this repo already hold as
Python's own dumps (test/fixtures/python_reference/dives/*.json, synthetic
logs), read back with Dive.model_validate, so the Dart test starts from
exactly the same dive; no log is copied into this file.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/log_viewer_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/pages/log_viewer_cases.json.gz
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")

import uwmedia.backends.log_viewer_backend as V  # noqa: E402
from models.dive import Dive  # noqa: E402
from utils import units as U  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "test" / "fixtures" / "python_reference"
# (fixture, the key of its list of cases)
SOURCES = [("uddf", "parse"), ("subsurface", "parse"), ("shearwater", "parse"), ("subsurface_csv", "parse"), ("garmin", "messages"),
           ("garmin", "files")]
FILTERS = ["nx", "1:0", "BO", "none", " ", "21", "Air", "(", "0.7"]
SMALL_CHART, SMALL_EVENTS = 7, 2


def reverse_map_for(dive):
    """A tank-name mapping made up for the dive: every other tank has a
    serial, and one is its own serial."""
    keys = []
    for wp in dive.waypoints:
        for key in wp.tanks:
            if key not in keys:
                keys.append(key)
    out = {key: f"SN{1000 + i}" for i, key in enumerate(keys) if i % 2 == 0}
    if len(keys) > 2:
        out[keys[2]] = keys[2]
    return out


def table_filter(rows, text):
    """LogViewerBackend.tableRows, which is a property of the Qt object:
    the indices of the rows it keeps."""
    text = (text or "").lower()
    return [i for i, row in enumerate(rows) if not text or any(text in str(v).lower() for v in row.values())]


def shown(dive, reverse_map):
    rows = V.sample_rows(dive, reverse_map)
    return {"headers": V.table_headers(), "row": V.dive_row(dive), "details": V.dive_details(dive, reverse_map), "rows": rows,
            "filters": {text: table_filter(rows, text) for text in FILTERS}}


def case(source, key, index, dive_index, dump):
    dive = Dive.model_validate(dump)
    reverse_map = reverse_map_for(dive)
    out = {"source": f"dives/{source}.json", "key": key, "index": index, "dive": dive_index, "reverse_map": reverse_map}
    with U.units_override("metric"):
        out["metric"] = shown(dive, reverse_map)
        # The limits made small, so that the thinning of the chart and the
        # cut of the event list happen on these short dives too.
        chart, events = V.MAX_CHART_POINTS, V.MAX_EVENT_LINES
        V.MAX_CHART_POINTS, V.MAX_EVENT_LINES = SMALL_CHART, SMALL_EVENTS
        try:
            details = V.dive_details(dive, reverse_map)
            out["small"] = {k: details[k] for k in ("samples", "po2_samples", "events", "has_ceiling")}
        finally:
            V.MAX_CHART_POINTS, V.MAX_EVENT_LINES = chart, events
    if (index + dive_index) % 3 == 0:
        with U.units_override("imperial"):
            out["imperial"] = shown(dive, reverse_map)
    return out


if __name__ == "__main__":
    cases = []
    for source, key in SOURCES:
        data = json.loads((FIXTURES / "dives" / f"{source}.json").read_text())
        for index, c in enumerate(data[key]):
            for dive_index, dump in enumerate(c.get("dives") or []):
                cases.append(case(source, key, index, dive_index, dump))
    out = {
        "constants": {"table_columns": V.TABLE_COLUMNS, "max_chart_points": V.MAX_CHART_POINTS, "max_event_lines": V.MAX_EVENT_LINES,
                      "format_names": V.FORMAT_NAMES, "channel_labels": [list(c) for c in V.CHANNEL_LABELS],
                      "ignored_alerts": list(V.IGNORED_ALERTS), "last_folder_field": V.LAST_FOLDER_FIELD,
                      "small_chart": SMALL_CHART, "small_events": SMALL_EVENTS},
        "mix_names": [[o2, he, V.mix_name(o2, he)] for o2, he in ((21.0, 0.0), (20.5, 0.0), (21.5, 0.0), (22.5, 0.0), (32.0, 0.0), (100.0, 0.0),
                                                                  (18.0, 45.0), (10.5, 0.5), (12.0, 0.4), (5.0, 0.0), (0.0, 0.0))],
        "minutes": [[s, V._minutes(s), V._clock(s)] for s in (0, 59, 60, 61, 3599, 3600, 86400, -1, -61)],
        "cases": cases,
    }
    numbers = []
    for value, unit, digits in ((None, "m", 1), (18.25, "m", 1), (0.05, "m", 1), (207.5, "bar", 0), (0.5, "bar", 0), (4.0, "°C", 1),
                                (-1.5, "°C", 1), (12.3456789, "", 6), (3.0, "x", 0), (2.5, "", 0), (1e21, "", 1)):
        row = [value, unit, digits]
        for units in ("metric", "imperial"):
            with U.units_override(units):
                row.append(V._num(value, unit, digits))
        numbers.append(row)
    out["numbers"] = numbers
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
    print(len(cases), "dives", file=sys.stderr)
