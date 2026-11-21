"""Parity fixture for the Dive Profile Builder's model and engine (spec
§7): models/dive_plan.py and utils/dive_plan_engine.py on invented plans
(the plans of the Python tests, the bottoms of the Subsurface reference
dives, and odd ones), and utils/dive_computers.py.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/plan_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/plan/plan_cases.json.gz
"""
import dataclasses
import json
import sys

sys.path.insert(0, ".")

from models.dive_plan import CCR_O2_TANK_REF, DiveProfilePlan, split_sidemount_pair  # noqa: E402
from utils import dive_computers  # noqa: E402
from utils import dive_plan_engine as E  # noqa: E402

AIR = {"id": "Air", "gas_type": "air", "o2_percent": 21.0}
EAN50 = {"id": "EAN50", "gas_type": "nitrox", "o2_percent": 50.0, "use_min_depth_m": 0, "use_max_depth_m": 21, "use_phase": "ascent",
         "tank_ref": "T2"}
O2 = {"id": "O2", "gas_type": "nitrox", "o2_percent": 100.0, "use_max_depth_m": 6, "use_phase": "ascent", "tank_ref": "T3"}


def wp(t, depth, gas="Air", **more):
    return {"runtime_sec": t, "depth_m": depth, "gas_id": gas, **more}


def bottom(depth, end, gases=None, **plan):
    gases = gases or [AIR]
    return {"gases": gases, "waypoints": [wp(180, depth, gases[0]["id"], gas_auto=True), wp(end, depth, gases[0]["id"], gas_auto=True)],
            **plan}


CCR_GASES = [{"id": "Dil", "gas_type": "trimix", "o2_percent": 18.0, "he_percent": 45.0, "diluent": True, "tank_size_l": 3, "tank_ref": "D"},
             {"id": "BO", "gas_type": "nitrox", "o2_percent": 32.0, "tank_ref": "T2"}]
SIDE_GASES = [{"id": "EAN32", "gas_type": "nitrox", "o2_percent": 32.0, "side": "left", "tank_size_l": 11.1, "start_pressure_bar": 207},
              {"id": "EAN32 R", "gas_type": "nitrox", "o2_percent": 32.0, "side": "right", "tank_ref": "T2", "tank_size_l": 11.1,
               "start_pressure_bar": 207}]
DECO_WPS = [wp(60, 15, gas_auto=True), wp(180, 40, gas_auto=True), wp(1500, 40, gas_auto=True), wp(1800, 21, gas_auto=True),
            wp(2000, 6, gas_auto=True), wp(2800, 0, gas_auto=True)]

PLANS = {
    "simple": {"gases": [AIR], "waypoints": [wp(300, 20.0), wp(1200, 20.0), wp(1500, 0.0)]},
    "deco_three_gases": {"gases": [AIR, EAN50, O2], "waypoints": DECO_WPS},
    "deco_by_hand": {"gases": [AIR, EAN50, O2], "waypoints": [{**w, "gas_auto": False} for w in DECO_WPS[:3]] + [wp(1800, 21, "EAN50"),
                                                                                                                  wp(2000, 6, "O2")]},
    "no_deco_bottom": bottom(18, 1200),
    "deco_bottom": bottom(40, 1500),
    "deco_bottom_with_gases": bottom(45, 1800, [AIR, EAN50, O2]),
    "small_obligation": bottom(30, 1500, [AIR, {**EAN50, "use_max_depth_m": 18}]),
    "trimix": bottom(50, 1800, [{"id": "Tx", "gas_type": "trimix", "o2_percent": 21.0, "he_percent": 35.0},
                                {"id": "EAN50", "gas_type": "nitrox", "o2_percent": 50.0, "use_max_depth_m": 21, "use_phase": "ascent",
                                 "tank_ref": "T2"}]),
    "deep_trimix_gf": bottom(70, 1500, [{"id": "Tx", "gas_type": "trimix", "o2_percent": 15.0, "he_percent": 50.0},
                                        {"id": "EAN32", "gas_type": "nitrox", "o2_percent": 32.0, "use_max_depth_m": 40, "tank_ref": "T2"},
                                        {**O2, "use_phase": "any"}],
                             gf_low=40.0, gf_high=85.0, default_ascent_rate=10.0, max_po2_deco=1.5, max_po2_bottom=1.3, sac_lpm=18.0),
    "subsurface_air_deco": {"gf_low": 40.0, "gf_high": 85.0, "default_descent_rate": 18.0, "gases": [AIR],
                            "waypoints": [wp(50, 15.0), wp(2400, 18.0)]},
    "ccr": {"dive_type": "ccr", "gases": CCR_GASES, "waypoints": [wp(180, 40.0, "Dil", gas_auto=True), wp(1200, 40.0, "Dil", gas_auto=True)]},
    "ccr_bailout": {"dive_type": "ccr", "ccr_high_setpoint": 1.2, "ccr_high_setpoint_depth_m": 12.0, "ccr_low_setpoint_depth_m": 5.0,
                    "gases": CCR_GASES, "waypoints": [wp(240, 45.0, "Dil"), wp(1500, 45.0, "Dil"), wp(1700, 20.0, "BO"),
                                                      wp(2400, 6.0, "BO"), wp(3000, 0.0, "BO")]},
    "ccr_long": {"dive_type": "ccr", "gases": CCR_GASES, "waypoints": [wp(300, 60.0, "Dil", gas_auto=True),
                                                                        wp(2400, 60.0, "Dil", gas_auto=True)]},
    "ccr_no_diluent": {"dive_type": "ccr", "gases": [AIR], "waypoints": [wp(180, 20.0), wp(600, 20.0)]},
    "sidemount": {"dive_type": "sidemount", "gases": SIDE_GASES, "waypoints": [wp(120, 20.0, "EAN32"), wp(2400, 20.0, "EAN32")]},
    "sidemount_small_switch": {"dive_type": "sidemount", "sidemount_switch_bar": 10.0, "sac_lpm": 25.0,
                               "gases": SIDE_GASES + [{**EAN50, "tank_ref": "T3"}],
                               "waypoints": [wp(120, 30.0, "EAN32 R", gas_auto=True), wp(2000, 30.0, "EAN32", gas_auto=True)]},
    "sidemount_one_tank": {"dive_type": "sidemount", "gases": SIDE_GASES[:1], "waypoints": [wp(120, 20.0, "EAN32"), wp(600, 20.0, "EAN32")]},
    "pair_on_oc_dive": {"gases": SIDE_GASES, "waypoints": [wp(120, 20.0, "EAN32"), wp(900, 20.0, "EAN32 R")]},
    "late_transit": {"gases": [AIR], "waypoints": [wp(30, 40.0), wp(600, 40.0), wp(620, 5.0, rate_m_per_min=30.0), wp(900, 5.0),
                                                   wp(900, 3.0), wp(880, 4.0)]},
    "own_rates_and_sac": {"default_descent_rate": 10.0, "default_ascent_rate": 6.0, "sac_lpm": 0.0,
                          "gases": [{**AIR, "sac_lpm": 14.5, "tank_size_l": 15.0, "start_pressure_bar": 232.0}, {**EAN50, "sac_lpm": 0.0}],
                          "waypoints": [wp(0, 0.0), wp(400, 33.3, rate_m_per_min=25.0), wp(1300, 33.3), wp(1600, 12.0, "EAN50"),
                                        wp(2000, 0.0, "EAN50")]},
    "nothing_covers": {"gases": [{**AIR, "use_max_depth_m": 30}, {**EAN50, "use_phase": "any"}],
                       "waypoints": [wp(180, 45, gas_auto=True), wp(900, 45, gas_auto=True), wp(1200, 10, gas_auto=True)]},
    "hand_gas_past_mod": {"max_po2_bottom": 1.2, "gases": [AIR, {**EAN50, "use_phase": "any"}],
                          "waypoints": [wp(180, 30, "EAN50"), wp(900, 30, "EAN50"), wp(950, 30, "Air", phase="ascent")]},
    "unknown_gas": {"gases": [AIR], "waypoints": [wp(180, 20.0), wp(600, 20.0, "Nope")]},
    "no_gases": {"waypoints": [wp(180, 20.0), wp(600, 20.0)]},
    "no_waypoints": {"gases": [AIR, EAN50]},
    "ends_at_surface": {"gases": [AIR], "waypoints": [wp(120, 10.0), wp(600, 10.0), wp(700, 0.0)]},
    "shallow": {"gases": [AIR], "waypoints": [wp(60, 2.5, gas_auto=True), wp(900, 2.5, gas_auto=True)]},
    "legacy_keys": {"computer": "Shearwater Petrel", "ccr_setpoint_switch_depth_m": 4.0, "dive_type": "sidemount",
                    "start_time": "2026-05-02T10:06:59", "computer_serial": "000123", "name": "Old plan",
                    "gases": [{"id": "EAN32", "o2_percent": 32.0, "tank_ref": "T1", "sidemount_pair": True, "color": "#0EA5A4"},
                              {"id": "EAN50", "o2_percent": 50.0, "tank_ref": "T2", "sidemount_pair": True},
                              {"id": "Air", "tank_ref": "T3"}],
                    "waypoints": [wp(120, 20.0, "EAN32"), wp(1500, 20.0, "EAN32")]},
    "legacy_switch_depth_kept": {"ccr_setpoint_switch_depth_m": 9.0, "ccr_high_setpoint_depth_m": 7.0, "gases": [AIR]},
    "legacy_switch_depth_none": {"ccr_setpoint_switch_depth_m": None, "gases": [AIR]},
}

INVALID = [
    {"gf_low": 101}, {"gf_high": -1}, {"default_ascent_rate": 0}, {"max_po2_bottom": 0.4}, {"max_po2_deco": 2.1}, {"max_depth_m": 0},
    {"planned_runtime_sec": 0}, {"dive_type": "freedive"}, {"ccr_low_setpoint": 0.3}, {"sidemount_switch_bar": 0},
    {"gases": [{"o2_percent": 21.0}]}, {"gases": [{"id": "x", "o2_percent": 0.5}]}, {"gases": [{"id": "x", "he_percent": 100}]},
    {"gases": [{"id": "x", "gas_type": "heliox"}]}, {"gases": [{"id": "x", "side": "back"}]}, {"gases": [{"id": "x", "tank_size_l": 0}]},
    {"gases": [{"id": "x", "use_phase": "bottom"}]}, {"gases": [{"id": "x", "sac_lpm": -1}]},
    {"waypoints": [{"depth_m": 1, "gas_id": "a"}]}, {"waypoints": [{"runtime_sec": -1, "depth_m": 1, "gas_id": "a"}]},
    {"waypoints": [{"runtime_sec": 1, "depth_m": -1, "gas_id": "a"}]}, {"waypoints": [{"runtime_sec": 1, "depth_m": 1}]},
    {"waypoints": [{"runtime_sec": 1, "depth_m": 1, "gas_id": "a", "rate_m_per_min": 0}]},
    {"waypoints": [{"runtime_sec": 1, "depth_m": 1, "gas_id": "a", "phase": "bottom"}]},
]


def fresh(data):
    return DiveProfilePlan.model_validate(json.loads(json.dumps(data)))


def call(fn):
    try:
        return ["ok", fn()]
    except ValueError as e:
        return ["raise", str(e)]


def model_facts(plan):
    gases = plan.gases
    return {
        "dump": plan.model_dump(mode="json"),
        "sorted": [w.runtime_sec for w in plan.sorted_waypoints()],
        "is_ccr": plan.is_ccr, "diluent": getattr(plan.diluent_gas(), "id", None),
        "sidemount_tanks": [g.id for g in plan.sidemount_tanks()] if plan.sidemount_tanks() else None,
        "sidemount_error": plan.sidemount_error(),
        "breathed_gases": [g.id for g in plan.breathed_gases()],
        "tank_specs": [t.model_dump() for t in plan.tank_specs()],
        "setpoints": [[c, d, plan.next_setpoint(c, d)] for c in (None, 0.7, 1.3) for d in (0.0, 1.9, 2.0, 5.0, 8.0, 8.1, 40.0)],
        "gases": [{
            "id": g.id, "f_o2": g.f_o2, "f_he": g.f_he, "mod_m": g.mod_m, "has_depth_range": g.has_depth_range,
            "covers": [g.covers_depth(d) for d in (0.0, 6.0, 6.1, 21.0, 30.0, 60.0)],
            "on_loop": plan.on_loop(g), "breathed": plan.breathed_gas(g).id, "breathed_id": plan.breathed_gas_id(g.id),
            "tank_refs": plan.tank_refs_for(g), "for_tank": getattr(plan.gas_for_tank(g.tank_ref), "id", None), "sac": plan.sac_for(g),
            "mod": [plan.gas_mod_m(g, p) for p in ("descent", "ascent")], "display_mod": plan.gas_display_mod_m(g),
            "usable": [[d, p, plan.gas_usable_at(g, d, p)] for d in (3.0, 6.0, 21.0, 22.0, 40.0, 57.0) for p in ("descent", "ascent")],
            "deepest": [None if v == float("inf") else v for v in (plan.gas_deepest_use_m(g, p) for p in ("descent", "ascent"))],
            "auto": [[d, p, getattr(E.auto_gas_for_waypoint(plan, d, p), "id", None)] for d in (3.0, 6.0, 21.0, 40.0) for p in ("descent", "ascent")],
        } for g in gases],
        "unknown_gas_id": plan.breathed_gas_id("nope"), "max_po2": [plan.max_po2_for(p) for p in ("descent", "ascent", "other")],
    }


def stops_of(stops):
    return [[d, s, g] for d, s, g in stops]


def engine_facts(data):
    out = {}
    plan = fresh(data)
    out["phases"] = E.waypoint_phases(plan.sorted_waypoints())
    plan = fresh(data)
    out["auto_warnings"] = E.apply_auto_gases(plan)
    out["auto_gases"] = [w.gas_id for w in plan.sorted_waypoints()]

    def expand():
        timeline, warnings = E.expand_plan(fresh(data))
        return {"length": len(timeline), "warnings": warnings, "every_7th": [list(e) for e in timeline[::7]],
                "last": list(timeline[-1]) if timeline else None}
    out["expand"] = call(expand)

    def simulate(resolution):
        samples, warnings = E.simulate(fresh(data), resolution_sec=resolution)
        return {"warnings": warnings, "samples": [dataclasses.asdict(s) for s in samples]}
    out["simulate_15"] = call(lambda: simulate(15))
    out["simulate_1_count"] = call(lambda: len(E.simulate(fresh(data))[0]))

    def ascent():
        plan = fresh(data)
        waypoints, deco, stops = E.plan_ascent(plan)
        return {"waypoints": [w.model_dump() for w in waypoints], "deco": deco, "stops": stops_of(stops),
                "gases_after": [w.gas_id for w in plan.sorted_waypoints()]}
    out["plan_ascent"] = call(ascent)

    def from_time(t):
        deco, stops, tts = E.ascent_from_time(fresh(data), t)
        return {"deco": deco, "stops": stops_of(stops), "tts": tts}
    last = max((w["runtime_sec"] for w in data.get("waypoints", [])), default=0)
    out["ascent_from_time"] = [[t, call(lambda t=t: from_time(t))] for t in (0, 90, 600.5, last // 2, last - 1, last, last + 500)]
    out["deco_timeline"] = call(lambda: [[t, stops_of(s)] for t, s in E.deco_schedule_timeline(fresh(data), interval_sec=240)])
    return out


def cases():
    out = []
    for name, data in PLANS.items():
        plan = fresh(data)
        out.append({"name": name, "plan": data, "model": model_facts(plan), "engine": engine_facts(data)})
    return out


def invalid_cases():
    out = []
    for data in INVALID:
        try:
            DiveProfilePlan.model_validate(data)
            out.append([data, True])
        except Exception:  # noqa: BLE001
            out.append([data, False])
    return out


if __name__ == "__main__":
    gas = {"id": "EAN32", "tank_ref": "T1", "sidemount_pair": True, "color": "#123456"}
    out = {
        "constants": {k: getattr(E, k) for k in ("SURFACE_PRESSURE_BAR", "RECOMPUTE_INTERVAL_SEC", "CCR_LOOP_LPM", "CCR_METABOLIC_O2_LPM",
                                                 "STOP_INTERVAL_M", "SAFETY_STOP_DEPTH_M", "SAFETY_STOP_SEC", "SAFETY_STOP_TRIGGER_M",
                                                 "GAS_SWITCH_HOLD_SEC", "MAX_ASCENT_PLAN_SEC", "DECO_SCHEDULE_INTERVAL_SEC")},
        "ccr_o2_tank_ref": CCR_O2_TANK_REF,
        "defaults": DiveProfilePlan().model_dump(mode="json"),
        "computers": [dataclasses.asdict(c) | {"is_garmin": c.is_garmin} for c in dive_computers.DIVE_COMPUTERS.values()],
        "default_computer": dive_computers.DEFAULT_DIVE_COMPUTER, "legacy_labels": dive_computers.LEGACY_LABELS,
        "computer_lookups": [[label, dive_computers.computer_label(label), dive_computers.dive_computer(label).label]
                             for label in ("Shearwater Petrel", "Shearwater Peregrine", "Garmin Descent Mk3i", "Nobody", "")],
        "cells": [[po2, t, list(E.simulated_cells(po2, t))] for po2 in (0.7, 1.3, 1.26184) for t in (0, 1, 90, 1234, 5000)],
        "split_pairs": [
            [gas, ["T1", "T2"], True, None, split_sidemount_pair(gas, ["T1", "T2"])],
            [gas, ["T1", "T2"], False, None, split_sidemount_pair(gas, ["T1", "T2"], first=False)],
            [gas, [], True, "R9", split_sidemount_pair(gas, [], right_ref="R9")],
            [{"id": "x", "sidemount_pair": True}, ["T2"], True, None, split_sidemount_pair({"id": "x", "sidemount_pair": True}, ["T2"])],
        ],
        "plans": cases(),
        "invalid": invalid_cases(),
    }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
    print(len(out["plans"]), "plans", file=sys.stderr)
