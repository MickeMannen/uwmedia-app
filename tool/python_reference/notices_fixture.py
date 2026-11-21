"""Parity fixture for the notices, the gas values and the units (spec §5.4,
§5.5): utils/hud_notices.py, utils/hud_gas.py and utils/units.py of the
Python app with its hud_rules.json, on invented dives (those of
rules_fixture.py and a few of its own).

Python caches a dive's notice timeline without regard to the unit system;
the cache is emptied between systems here, so each is what a fresh run in
that system gives.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/notices_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/rules/notices_cases.json

When the Python working tree has uncommitted changes, run it the same way
from a clean extract of the commit instead (`git -C
$PYTHON_REPO archive <commit> | tar -x -C <scratch>`,
then `cd <scratch>` and `$PYTHON_REPO/.venv/bin/python`).
"""
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import rules_fixture  # noqa: E402
from rules_fixture import profile, run_lengths, wp  # noqa: E402

from models.dive import Dive, TankData  # noqa: E402
import utils.hud_rules_engine as engine  # noqa: E402
from utils import units as U  # noqa: E402
from utils.hud_gas import gas_o2_fraction, gas_time_remaining, mod_metres  # noqa: E402
from utils.hud_notices import (  # noqa: E402
    active_notice, active_persistent_notice, notice_rules, notice_style, persistent_notice_rules,
)

BRANDS = [("Shearwater", "Perdix 2"), ("Shearwater", "Teric"), ("Shearwater", "Petrel"), ("Garmin", "x50i"), ("Garmin", "mk3i"),
          ("Generic", ""), ("UnknownMfg", None), ("Suunto", "EON Core"), ("Suunto", "Nautic")]


def own_dives():
    def tank(bar, name=None):
        return TankData(pressure_bar=bar, o2_percent=32.0, name=name)

    alerts_and_limits = profile(
        [(0, 0), (60, 30), (400, 30), (500, 42), (560, 42), (600, 36), (700, 30), (900, 30), (960, 5), (1200, 5), (1230, 0)],
        step=5,
        po2=lambda t, d: 1.8 if 100 <= t < 150 else 1.7 if 200 <= t < 220 else 0.15 if 300 <= t < 310 else round((1 + d / 10) * 0.32, 2),
        ndl=lambda t, d: 290 if 250 <= t < 270 else 500 if 330 <= t < 340 else 250 if 350 <= t < 360 else 900,
        cns=lambda t, d: 85 if t < 700 else 95 if t < 800 else 160 if t < 850 else 101,
        ascent_rate=lambda t, d: 14.0 if 905 <= t < 940 else 11.0 if 945 <= t < 950 else 2.0,
        tanks=lambda t, d: {"T1": tank(200.0 - t * 0.16)},
        gas_o2_percent=lambda t, d: 32.0,
    )
    by_time = {w.time_since_start: w for w in alerts_and_limits}
    for t, names in {120: ["ndl_reached"], 125: ["approaching_ndl", "alert_dismissed_by_key"], 400: ["cns_warning", "ascent_critical"],
                     410: ["po2_warn"], 800: ["safety_stop_started"], 1000: ["safety_stop_complete"], 1100: ["no_such_alert"]}.items():
        by_time[t].dive_alerts = names

    def pair(t, d):
        left = 200.0 - t * 0.02 - (40.0 if 200 <= t < 400 or 700 <= t < 800 else 0.0)
        right = 195.0 - t * 0.03 + (45.0 if 500 <= t < 600 else 0.0)
        return {"Left": tank(left, "Micke01"), "Right": tank(right)}

    sidemount = profile([(0, 0), (60, 18), (900, 18), (960, 0)], step=10, tanks=pair)
    steady = profile([(0, 0), (60, 20), (900, 20), (1000, 5), (1300, 5), (1330, 0)], step=10,
                     tanks=lambda t, d: {"T1": tank(210.0 - 4.2 * t / 60.0 if t < 700 else 161.0 - (t - 700) * 0.01)},
                     deco_stop_depth=lambda t, d: 3.0 if 600 <= t < 660 else None)
    setpoints = profile(
        [(0, 0), (120, 30), (600, 30), (700, 6), (900, 6), (930, 0)], step=10,
        divemode=lambda t, d: "closedcircuit" if t < 500 or t >= 560 else "opencircuit",
        setpoint=lambda t, d: (0.7 if t < 100 else 1.3 if t < 400 else 1.0 if t < 450 else 1.3 if t < 800 else 0.7) if (t < 500 or t >= 560) else None,
        po2=lambda t, d: 1.7 if 200 <= t < 260 else 0.3 if 300 <= t < 320 else 1.2,
        gas_o2_percent=lambda t, d: 18.0, diluent_o2_percent=lambda t, d: 18.0,
    )
    # Suunto's own alerts (tests/test_suunto_rules.py): the logged gas
    # notifications, OTU and safety-stop events, an ascent over 10 m/min that
    # lasts five seconds and one that does not, sampled every second
    suunto = profile(
        [(0, 0), (60, 30), (300, 30), (303, 29.4), (360, 29.4), (420, 17.4), (600, 17.4), (700, 6), (900, 6), (930, 0)],
        step=1,
        po2=lambda t, d: 1.7 if 100 <= t < 110 else 0.15 if 150 <= t < 155 else round((1 + d / 10) * 0.32, 2),
        cns=lambda t, d: 85 if 200 <= t < 250 else 100 if 250 <= t < 260 else 20,
        tanks=lambda t, d: {"T1": tank(200.0 - t * 0.17)},
        gas_o2_percent=lambda t, d: 32.0,
    )
    by_time = {w.time_since_start: w for w in suunto}
    for t, names in {500: ["suunto:Gas Available"], 520: ["suunto:Gas Switch"], 540: ["otu_warning"], 560: ["otu_critical"],
                     580: ["safety_stop_broken"], 800: ["suunto:Gas Switch", "suunto:Gas Available"]}.items():
        by_time[t].dive_alerts = names
    no_tanks = [wp(0, 20.0, 20.0), wp(10, 32.5, 32.5), wp(20, 35.0, 35.0, cns=101), wp(30, 41.0, 41.0, po2=0.1, cns=95.0 // 1)]
    return {
        "limits and alerts: PO2, NDL, CNS, depth, ascent, a critical tank": alerts_and_limits,
        "sidemount tanks that drift apart and back": sidemount,
        "a steady consumption, then deco, then a stop": steady,
        "setpoint changes on the loop and a bailout": setpoints,
        "single waypoints without tanks": no_tanks,
        "Suunto: logged notifications, a fast ascent, every second": suunto,
    }


def dump_notice(notice):
    return None if notice is None else {k: v for k, v in notice.items()}


def dive_cases():
    dives = {**rules_fixture.dives(), **own_dives()}
    keep = ["deco with logged stops", "the computer's own alerts", "rebreather with a bailout", "recreational, safety stop"]
    cases = []
    for name, wps in dives.items():
        if name in rules_fixture.dives() and not name.startswith(tuple(keep)):
            continue
        dive = Dive(start_time=wps[0].timestamp, end_time=wps[-1].timestamp, waypoints=wps)
        wps = dive.waypoints
        results = []
        for m, mo in BRANDS:
            for units in ("metric", "imperial"):
                if units == "imperial" and (m, mo) not in (("Shearwater", "Perdix 2"), ("Garmin", "x50i"), ("Suunto", "EON Core")):
                    continue
                engine._timeline_cache.clear()
                with U.units_override(units):
                    results.append({
                        "manufacturer": m, "model": mo, "units": units,
                        "notice": run_lengths([dump_notice(active_notice(m, mo, w, wps)) for w in wps]),
                        "notice_alone": run_lengths([dump_notice(active_notice(m, mo, w)) for w in wps]),
                        "persistent": run_lengths([dump_notice(active_persistent_notice(m, mo, w, wps)) for w in wps]),
                        "gas_time": run_lengths([gas_time_remaining(m, mo, w, wps) for w in wps]),
                        "mod": run_lengths([mod_metres(m, mo, w) for w in wps]),
                    })
        cases.append({
            "name": name,
            "dive": dive.model_dump(mode="json", exclude_defaults=True),
            "gas_o2_fraction": run_lengths([gas_o2_fraction(w) for w in wps]),
            "results": results,
        })
    engine._timeline_cache.clear()
    return cases


def units_cases():
    out = {"normalize": [[v, U.normalize(v)] for v in ["FT", None, "psi", "Imperial", " us ", "feet", "metric", "", "m", 0, "bar", "IMPERIAL "]],
           "resolve": [], "systems": {}}
    for layout in [None, {}, {"units": "imperial"}, {"units": "metric"}, {"units": ""}, {"units": "ft"}, {"units": None}]:
        for current in ("metric", "imperial"):
            with U.units_override(current):
                out["resolve"].append({"layout": layout, "current": current, "expected": U.resolve_units(layout)})
    values = [0.0, 0.05, 1.0, 2.9, 3.0, 4.39, 4.4, 4.5, 5.0, 5.6, 5.61, 6.0, 7.6, 9.0, 10.67, 11.0, 12.3, 13.72, 20.7, 21.0, 27.0, 31.58,
              45.3, 50.0, 207.0, -2.5, 0.125, 2.5, 3.5, 1.524, 4.572]
    rules = [None, {}, {"depth_decimals": {"metric": 1, "imperial": 0}}, {"depth_decimals": {"imperial": 1}}, {"depth_decimals": {"metric": 2}},
             {"depth_decimals": 3}]
    for units in ("metric", "imperial"):
        out["systems"][units] = {
            "values": values,
            "depth": [U.depth(v, units) for v in values],
            "pressure": [U.pressure(v, units) for v in values],
            "temperature": [U.temperature(v, units) for v in values],
            "volume_rate": [U.volume_rate(v, units) for v in values],
            "depth_to_metres": [U.depth_to_metres(v, units) for v in values],
            "pressure_to_bar": [U.pressure_to_bar(v, units) for v in values],
            "temperature_to_celsius": [U.temperature_to_celsius(v, units) for v in values],
            "stop_depth": [float(U.stop_depth(v, units)) for v in values],
            "format_pressure": [U.format_pressure(v, units) for v in values] + [U.format_pressure(None, units)],
            "format_temperature": [[U.format_temperature(v, units, d) for v in values] + [U.format_temperature(None, units, d)] for d in (0, 1)],
            "format_depth": [[U.format_depth(v, units, display_rule=r) for v in values] + [U.format_depth(None, units, display_rule=r)] for r in rules],
            "format_depth_decimals": [[U.format_depth(v, units, decimals=d) for v in values] for d in (0, 1, 2)],
            "depth_decimals": [U.depth_decimals(r, units) for r in rules],
            "labels": {kind: U.unit_label(kind, units) for kind in ["depth", "pressure", "pressure_lower", "temp", "sac", "volume_rate", "depth_rate", "other"]},
        }
    out["display_rules"] = rules
    return out


if __name__ == "__main__":
    out = {
        "hud_rules_sha256": hashlib.sha256(Path("hud_rules.json").read_bytes()).hexdigest(),
        "units": units_cases(),
        "notice_rules": [
            {"manufacturer": m, "model": mo, "ids": [r["id"] for r in notice_rules(m, mo)],
             "persistent_ids": [r["id"] for r in persistent_notice_rules(m, mo)], "style": notice_style(m, mo)}
            for m, mo in BRANDS + [("Shearwater", "Tern"), ("Shearwater", "Perdix 3"), ("Suunto", "EON Steel Black"), ("Suunto", None),
                                   (None, None)]
        ],
        "dives": dive_cases(),
    }
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
