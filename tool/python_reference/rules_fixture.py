"""Parity fixture for the overlay rules engine (spec §5.5):
utils/hud_rules_engine.py of the Python app with its hud_rules.json (a copy
of which is assets/hud_rules.json in this repo), on invented dives.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/rules_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/rules/rules_cases.json

When the Python working tree has uncommitted changes, run it the same way
from a clean extract of the commit instead (`git -C
$PYTHON_REPO archive <commit> | tar -x -C <scratch>`,
then `cd <scratch>` and `$PYTHON_REPO/.venv/bin/python`).
"""
import hashlib
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, ".")

from models.dive import Dive, TankData, Waypoint  # noqa: E402
import utils.hud_rules_engine as engine  # noqa: E402
from utils.hud_rules_engine import (  # noqa: E402
    average_depth_at, ccr_style, ceiling_broken, ceiling_broken_color, deco_clear_seconds, deco_stop_phase, failed_cells,
    get_badge_config, get_dynamic_color, get_ndl_before_clear, get_rule_config, get_safety_stop_text, get_tank_fill_color,
    load_rules_json, resolve_blink_color, resolve_state, resolve_tank_variant, rule_overrides, safety_stop_phase,
    safety_stop_status, sidemount_switch_target, stop_phase, tank_pressure_state, tank_reserve_thresholds,
)

START = datetime(2026, 1, 1, 10)
BRANDS = [
    ("Shearwater", "Perdix 2"), ("Shearwater", "Teric"), ("Shearwater", "Tern"), ("Shearwater", "Perdix 3"),
    ("Shearwater", "Petrel"), ("Shearwater", "Peregrine TX"), ("Shearwater", None), ("Garmin", "x50i"), ("Garmin", "mk3i"),
    ("Garmin", ""), ("Generic", ""), ("UnknownMfg", "Model"), (None, None), ("_source", None), ("Shearwater", "_source"),
    ("default", None), ("Shearwater", "default"),
    ("Suunto", "EON Core"), ("Suunto", "EON Steel Black"), ("Suunto", "Nautic"), ("Suunto", None),
]


def all_rule_keys(rules):
    keys = set()

    def walk(block, depth):
        for key, value in block.items():
            keys.add(key)
            if depth < 2 and isinstance(value, dict):
                walk(value, depth + 1)

    walk(rules, 0)
    return sorted(keys)


def rule_config_cases(rules):
    """Where each lookup's value comes from in hud_rules.json (the path of
    the block that holds it), not the value itself, to keep the file small:
    the Dart test checks it gets that very object."""
    keys = all_rule_keys(rules) + ["no_such_rule"]

    def source(m, mo, key):
        value = get_rule_config(m, mo, key)
        if value is None:
            return None
        for path in ([m, mo], [m], [m, "default"], ["default"]):
            block = rules
            for part in path:
                block = block.get(part) if isinstance(block, dict) and part is not None else None
            if isinstance(block, dict) and key in block and block[key] is value:
                return path
        raise AssertionError((m, mo, key))

    return [{"manufacturer": m, "model": mo, "sources": {key: source(m, mo, key) for key in keys}} for m, mo in BRANDS]


def color_cases():
    values = {
        "ndl": [None, 0, -60, 1, 59, 240, 299, 300, 301, 599, 600, 1200, 1799, 1800, 2100, 5939, 5940, 6000, "abc", "600", True],
        "ndl_before_clear": [0, 240, 6000],
        "primary_tank_pressure": [None, 0, 20, 20.9, 21, 24, 24.9, 25, 26, 49, 49.9, 50, 55, 59.9, 60, 65, 69.9, 70, 150, "40", "x"],
        "secondary_tank_pressure": [20, 49, 150],
        "tank_pressure:T1": [24, 49, 120],
        "tank_pressure": [24],
        "po2": [None, 0.1, 0.16, 0.18, 0.19, 1.3, 1.39, 1.4, 1.5, 1.59, 1.6, 1.61, 1.8],
        "po2_1": [1.7, 0.3], "po2_2": [1.7], "po2_3": [1.7],
        "safety_stop": [None, 0, 1, "x"],
        "depth": [10], "gasmix": ["AIR"],
        "ascent_rate": [None, 0, 1.9, 2.0, 7.9, 8.0, 9.9, 10.0, 12.0, -3.0],
    }
    out = []
    for m, mo in BRANDS:
        for field, vals in values.items():
            for v in vals:
                out.append({"manufacturer": m, "model": mo, "field": field, "value": v,
                            "expected": get_dynamic_color(m, mo, field, v, "#123456")})
    return out


def tank_cases():
    out = []
    for m, mo in BRANDS:
        for reserve in (None, 48, 27, 100, 0):
            thresholds = tank_reserve_thresholds(m, mo, reserve)
            out.append({
                "manufacturer": m, "model": mo, "reserve_bar": reserve,
                "thresholds": None if thresholds is None else list(thresholds),
                "states": [[v, tank_pressure_state(m, mo, v, reserve)] for v in [None, 0, 13.4, 13.5, 20.9, 21, 23, 24, 25, 47, 48, 49.9, 50, 99, 100, 150]],
            })
        out.append({
            "manufacturer": m, "model": mo,
            "fill": [[v, get_tank_fill_color(m, mo, v)] for v in [None, 0, 20, 21, 40, 49.9, 50, 60, 69.9, 70, 150, "60", "x"]],
            "ceiling_broken_color": ceiling_broken_color(m, mo),
        })
    return out


BADGE_OVERRIDES = [
    {"badge_states": {"safety_stop": {"label": "", "timer_format": "m'ss"}}},  # an EON page (Python 0.8.0)
    {"badge_states": {"safety_stop": {"color": None, "extra": 1}, "deco": {"label": "STOP"}, "_source": "page"}},
    {"badge_states": {"normal": {"label": "N"}, "clear": {"label": "CLR"}}},
    {"badge_states": None, "ndl": []},
]


def badge_cases():
    """Each state's badge with the rules alone, then under a page's own
    `rules` (rule_overrides), which layer last."""
    out = [
        {"manufacturer": m, "model": mo, "state": state, "overrides": None, "expected": get_badge_config(m, mo, state)}
        for m, mo in BRANDS for state in ("safety_stop", "deco", "clear", "normal", "other")
    ]
    for overrides in BADGE_OVERRIDES:
        with rule_overrides(overrides):
            out += [
                {"manufacturer": m, "model": mo, "state": state, "overrides": overrides, "expected": get_badge_config(m, mo, state)}
                for m, mo in [("Suunto", "EON Core"), ("Suunto", "Nautic"), ("Shearwater", "Teric"), ("UnknownMfg", "Model"), (None, None)]
                for state in ("safety_stop", "deco", "clear", "normal")
            ]
    return out


def wp(t, depth, max_depth, **kw):
    return Waypoint(timestamp=START + timedelta(seconds=t), depth=depth, max_depth=max_depth, time_since_start=t, dive_time=t, **kw)


def profile(points, step=20, **fields):
    """Waypoints every `step` seconds on straight lines through (time, depth)
    points; `fields` maps a field name to a function of (t, depth) giving its
    value (None leaves the model's default)."""
    wps, max_depth = [], 0.0
    for (t0, d0), (t1, d1) in zip(points, points[1:]):
        for t in range(t0, t1, step):
            depth = round(d0 + (d1 - d0) * (t - t0) / (t1 - t0), 3)
            max_depth = max(max_depth, depth)
            extra = {}
            for name, fn in fields.items():
                value = fn(t, depth)
                if value is not None:
                    extra[name] = value
            wps.append(wp(t, depth, max_depth, **extra))
    return wps


def dives():
    rec = profile([(0, 0), (60, 20), (600, 20), (700, 5), (760, 5), (800, 1.0), (860, 1.0), (900, 5), (1100, 5), (1130, 1.4), (1160, 0.9), (1200, 0)],
                  ndl=lambda t, d: None if d < 7.5 else max(60, 3000 - 4 * t))
    reset = profile([(0, 0), (60, 20), (300, 20), (400, 5), (460, 5), (520, 15), (600, 15), (700, 5), (1000, 5), (1060, 0)])
    shallow = profile([(0, 0), (60, 9), (600, 9), (700, 5), (900, 5), (960, 0)], ndl=lambda t, d: 5940)
    deep = profile([(0, 0), (60, 32), (300, 32), (600, 5), (1000, 5), (1040, 0)],
                   ndl=lambda t, d: 240 if 200 <= t < 260 else 900)

    def deco_fields():
        def stop(t, d):
            if 1100 <= t < 1700:
                return 9.0
            if 1700 <= t < 2100:
                return 6.0
            if 2100 <= t < 2600:
                return 3.0
            return 0.0 if t >= 2600 else None

        return dict(
            deco_stop_depth=stop, next_stop_depth=stop,
            next_stop_time=lambda t, d: (120 if stop(t, d) else 0) if stop(t, d) is not None else None,
            ceiling=lambda t, d: None if stop(t, d) is None else max(0.0, stop(t, d) - 1.7),
            ndl=lambda t, d: None if (stop(t, d) or 0) > 0 else max(0, 1500 - 2 * t),
            tts=lambda t, d: 600,
        )

    deco = profile([(0, 0), (120, 45), (1200, 45), (1500, 14), (1600, 9.4), (1700, 8.6), (1750, 7.2), (1800, 6.0), (1900, 5.5),
                    (1950, 3.9), (2000, 6.5), (2100, 6.0), (2200, 3.0), (2500, 3.2), (2550, 2.3), (2600, 3.0), (2700, 4.5),
                    (2900, 4.5), (2960, 0)], **deco_fields())

    alerts = profile([(0, 0), (60, 30), (900, 30), (1100, 9), (1400, 9), (1500, 6), (1800, 6), (1900, 5), (2200, 5), (2260, 0)],
                     deco_stop_depth=lambda t, d: 9.0 if 800 <= t < 1400 else (6.0 if 1400 <= t < 1800 else 0.0),
                     next_stop_depth=lambda t, d: 9.0 if 800 <= t < 1400 else (6.0 if 1400 <= t < 1800 else 0.0),
                     next_stop_time=lambda t, d: 200 if 800 <= t < 1800 else 0)
    by_time = {w.time_since_start: w for w in alerts}
    for t, names in {780: ["approaching_first_deco_stop"], 1000: ["deco_ceiling_broken", "alert_dismissed_by_key"],
                     1400: ["deco_stop_cleared"], 1420: ["deco_ceiling_broken", "deco_stop_cleared"],
                     1800: ["deco_stop_cleared", "deco_complete"], 1900: ["safety_stop_started"], 1960: ["ndl_reached"],
                     2000: ["safety_stop_complete"], 2100: ["safety_stop_started"]}.items():
        by_time[t].dive_alerts = names

    def pair(t, d):
        left = None if t in (300, 320) else 200.0 - t * 0.02 - (30.0 if 400 <= t < 700 else 0.0)
        right = 195.0 - t * 0.05 if t < 1500 else 20.0
        tanks = {"Left": TankData(pressure_bar=left if left is not None else 0.0), "Right": TankData(pressure_bar=right)}
        if t < 100:
            tanks.pop("Right")
        return tanks

    sidemount = profile([(0, 0), (60, 18), (1500, 18), (1700, 5), (1900, 5), (1930, 0)], tanks=pair)

    def setpoint(t, d):
        return 0.7 if t < 120 or t >= 2300 else 1.3

    loop = lambda t: t < 1500 or t >= 1900  # noqa: E731
    ccr = profile(
        [(0, 0), (180, 40), (1200, 40), (1500, 15), (1800, 6), (2400, 6), (2500, 1), (2560, 0)],
        divemode=lambda t, d: "closedcircuit" if loop(t) else "opencircuit",
        setpoint=lambda t, d: setpoint(t, d) if loop(t) else None,
        po2=lambda t, d: (1.72 if 600 <= t < 660 else 0.35 if 700 <= t < 720 else setpoint(t, d)) if loop(t) else round((1 + d / 10) * 0.5, 2),
        po2_1=lambda t, d: setpoint(t, d) + 0.01 if loop(t) else None,
        po2_2=lambda t, d: (0.9 if 900 <= t < 1000 else 0.3 if 1000 <= t < 1100 else 1.7 if 1100 <= t < 1150 else setpoint(t, d)) if loop(t) else None,
        po2_3=lambda t, d: (None if 1000 <= t < 1050 else setpoint(t, d) - 0.02) if loop(t) else None,
        diluent_o2_percent=lambda t, d: 18.0, diluent_he_percent=lambda t, d: 45.0,
        gas_o2_percent=lambda t, d: 18.0 if loop(t) else 50.0, gas_he_percent=lambda t, d: 45.0 if loop(t) else 0.0,
    )
    # Suunto (tests/test_suunto_rules.py): a stop counted between 2.4 and 6 m
    # with a pause deeper than 6 m, sampled every 10 s; deco whose stop is the
    # logged ceiling (parsers/suunto.py), with the 3 m window and the 0.6 m
    # margin above it
    suunto_stop = profile([(0, 0), (60, 20), (600, 20), (660, 12), (700, 7), (720, 5), (780, 5), (790, 7.5), (800, 4), (1000, 4),
                           (1010, 2.0), (1030, 2.0), (1040, 3.0), (1100, 3.0), (1130, 0)], step=10)

    def suunto_ceiling(t, d):
        return 6.3 if 900 <= t < 1500 else (3.0 if 1500 <= t < 1800 else (0.0 if t >= 1800 else None))

    suunto_deco = profile([(0, 0), (120, 40), (900, 40), (1100, 9.5), (1150, 8.0), (1200, 5.9), (1250, 5.5), (1300, 6.6), (1400, 6.4),
                           (1500, 6.0), (1550, 3.5), (1600, 2.6), (1650, 2.2), (1800, 3.0), (1900, 3.0), (1960, 0)], step=10,
                          ceiling=suunto_ceiling, next_stop_depth=suunto_ceiling, deco_stop_depth=suunto_ceiling,
                          ndl=lambda t, d: None if suunto_ceiling(t, d) else max(0, 3000 - 3 * t), tts=lambda t, d: 480)
    gaps = profile([(0, 0), (60, 15), (300, 15), (400, 0)])
    for i in (3, 4, 15):
        gaps[i].depth = None
    gaps.append(wp(395, 1.0, 15.0))  # a time that goes back
    return {
        "recreational, safety stop, bobbing at the surface": rec,
        "back below the trigger depth during the stop": reset,
        "shallow": shallow,
        "past 30 m, a low NDL": deep,
        "deco with logged stops, above the stop and the ceiling": deco,
        "the computer's own alerts": alerts,
        "sidemount tanks": sidemount,
        "rebreather with a bailout, cells and setpoints": ccr,
        "Suunto: a safety stop between 2.4 and 6 m, paused deeper": suunto_stop,
        "Suunto: deco with the logged ceiling as the stop": suunto_deco,
        "samples without a depth, a time that goes back": gaps,
        "one waypoint": [wp(0, 12.0, 12.0, deco_stop_depth=3.0)],
    }


CONFIGS = [
    ("Shearwater", "Perdix 2", None), ("Shearwater", "Teric", None), ("Shearwater", "Perdix 3", None), ("Garmin", "x50i", None),
    ("Garmin", "mk3i", None), ("Generic", "", None), ("UnknownMfg", None, None),
    ("Shearwater", "Perdix 2", {"deco_clear": {"count_up": True}}),
    ("Shearwater", "Perdix 2", "adapt"),
    ("Garmin", "x50i", {"ceiling_broken": None, "safety_stop": None, "_note": "gauge"}),
    ("Shearwater", "Teric", {"deco_clear": {"count_up": False}, "sidemount_switch": {"threshold_bar": 5}}),
    ("Suunto", "EON Core", None), ("Suunto", "EON Steel Black", None), ("Suunto", "Nautic", None),
]
SUUNTO_CONFIGS = CONFIGS[11:]
CCR_FIELDS = ["po2", "diluent_po2", "po2_1", "po2_2", "po2_3", "setpoint", "circuit", "gasmix", "depth"]


def waypoint_results(m, mo, wps, dive):
    out = {name: [] for name in ("state", "state_alone", "stop_phase", "deco_stop_phase", "ceiling_broken", "sidemount", "safety_phase",
                                 "safety_status", "deco_clear", "ndl_before_clear", "safety_text", "average_depth", "ccr")}
    for w in wps:
        out["state"].append(resolve_state(m, mo, w, wps))
        out["state_alone"].append(resolve_state(m, mo, w))
        out["stop_phase"].append(list(stop_phase(m, mo, w, wps)))
        out["deco_stop_phase"].append(deco_stop_phase(m, mo, w))
        out["ceiling_broken"].append(ceiling_broken(m, mo, w))
        out["sidemount"].append(sidemount_switch_target(m, mo, w))
        phase = safety_stop_phase(m, mo, w, wps)
        out["safety_phase"].append(None if phase is None else list(phase))
        status = safety_stop_status(m, mo, w, wps)
        out["safety_status"].append(None if status is None else list(status))
        out["deco_clear"].append(deco_clear_seconds(m, mo, w, wps))
        out["ndl_before_clear"].append(get_ndl_before_clear(m, mo, w, wps))
        out["safety_text"].append(get_safety_stop_text(m, mo, w))
        out["average_depth"].append(average_depth_at(w, wps))
        if dive.is_ccr:
            values = {"po2": w.po2, "diluent_po2": w.diluent_po2, "po2_1": w.po2_1, "po2_2": w.po2_2, "po2_3": w.po2_3,
                      "setpoint": w.setpoint, "circuit": w.circuit, "gasmix": w.gasmix, "depth": w.depth}
            out["ccr"].append([ccr_style(m, mo, f, w, values[f], "#FFFFFF", elapsed=float(w.time_since_start) + 0.25 * (w.time_since_start // 10 % 4))
                               for f in CCR_FIELDS])
    if not dive.is_ccr:
        del out["ccr"]
    return {name: run_lengths(column) for name, column in out.items()}


def run_lengths(column):
    """[[value, count], ...] for a column: most of them are long runs."""
    runs = []
    for value in column:
        if runs and runs[-1][0] == value and type(runs[-1][0]) is type(value):
            runs[-1][1] += 1
        else:
            runs.append([value, 1])
    return runs


def dive_cases():
    adapt_rule = dict(get_rule_config("Shearwater", "Perdix 2", "safety_stop"))
    adapt_rule["adapt"] = {**adapt_rule["adapt"], "enabled": True}
    cases = []
    for name, wps in dives().items():
        dive = Dive(start_time=wps[0].timestamp, end_time=wps[-1].timestamp, waypoints=wps)
        wps = dive.waypoints
        results = []
        full = name.startswith(("recreational", "deco with", "the computer", "past 30", "Suunto"))
        for m, mo, overrides in (CONFIGS if full else CONFIGS[:1] + CONFIGS[3:4] + CONFIGS[5:6] + CONFIGS[10:11] + SUUNTO_CONFIGS):
            if overrides == "adapt":
                overrides = {"safety_stop": adapt_rule}
            with rule_overrides(overrides):
                results.append({"manufacturer": m, "model": mo, "overrides": overrides, **waypoint_results(m, mo, wps, dive)})
        cases.append({
            "name": name,
            "dive": dive.model_dump(mode="json", exclude_defaults=True),
            "tank_variant": resolve_tank_variant(dive),
            "average_depth_alone": [average_depth_at(w, None) for w in wps[:5]],
            "results": results,
        })
    return cases


if __name__ == "__main__":
    rules = load_rules_json()
    source = Path("hud_rules.json").read_bytes()
    out = {
        "hud_rules_sha256": hashlib.sha256(source).hexdigest(),
        "rule_config": rule_config_cases(rules),
        "dynamic_color": color_cases(),
        "tank": tank_cases(),
        "badge": badge_cases(),
        "blink": [
            {"elapsed": e, "period": p, "expected": resolve_blink_color("base", "blink", e, p)}
            for e, p in [(0.0, 1.0), (0.25, 1.0), (0.49, 1.0), (0.5, 1.0), (0.75, 1.0), (2.25, 1.0), (None, 1.0), (7.0, 1.0),
                         (0.9, 2.0), (1.0, 2.0), (3.1, 0.5), (-0.25, 1.0), (-0.75, 1.0)]
        ],
        "failed_cells": [
            {"values": {str(k): v for k, v in values.items()}, "fraction": fraction, "expected": sorted(failed_cells(values, fraction))}
            for values, fraction in [
                ({0: 1.20, 1: 1.25, 2: 0.80}, 0.20), ({0: 1.20, 1: 1.22, 2: 1.18}, 0.20), ({0: 1.2, 1: 0.6}, 0.20), ({0: 0.3}, 0.20),
                ({}, 0.20), ({0: 1.0, 1: 0.8, 2: 0.64}, 0.20), ({0: 1.0, 1: 0.8, 2: 0.64}, 0.10), ({0: 1.0, 2: 1.0}, 0.0),
                ({0: 0.0, 1: 0.0, 2: 1.0}, 0.20),
            ]
        ],
        "tank_variant_none": resolve_tank_variant(None),
        "dives": dive_cases(),
    }
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
