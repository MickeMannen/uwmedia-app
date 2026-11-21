"""Parity fixture for the deco engine, SAC and gas time, and the parsers'
deco pass (spec §4.1, §7): utils/deco_engine.py, utils/gas_consumption.py
and parsers/deco_pass.py of the Python app, on invented profiles.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/deco_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/deco/deco_cases.json
"""
import contextlib
import json
import math
import sys
import textwrap
from datetime import datetime, timedelta

sys.path.insert(0, ".")

from models.dive import TankData, Waypoint  # noqa: E402
from parsers.deco_pass import apply_deco_and_gas, deco_gas, parse_gf  # noqa: E402
from utils.gas_consumption import fill_sac_and_gtr  # noqa: E402

from utils.deco_engine import (  # noqa: E402
    BuhlmannEngine,
    DiveDecompressor,
    GasDefinition,
    ccr_effective_fractions,
    mod_meters,
)

START = datetime(2026, 1, 1, 10)
# Every SAMPLE_EVERY-th second of a result is kept in full; 13 shares no
# factor with the simulation intervals used (10 and 7), so both the
# simulated seconds and the ones in between are covered. The TTS is kept
# for every second.
SAMPLE_EVERY = 13


def engine_state(engine):
    surface = engine.surface_pressure
    return {
        "p_n2": [t.p_n2 for t in engine.tissues],
        "p_he": [t.p_he for t in engine.tissues],
        "cns": engine.cns,
        "ceilings": {str(gf): engine.get_ceiling(gf) for gf in (0.3, 0.4, 0.7, 0.85, 1.0)},
        "gradient_factors": {str(extra): engine.gradient_factor(surface + extra) for extra in (0.0, 0.3, 0.6, 1.5, 3.0)},
    }


def engine_cases():
    cases = []
    for name, surface, steps in [
        ("fresh", None, []),
        ("air 30 m 20 min, then 5 m 3 min", None, [(30.0, 1200, 0.21, 0.0), (5.0, 180, 0.21, 0.0)]),
        ("trimix 18/45 60 m 25 min, EAN50 at 21 m, O2 at 6 m", None,
         [(60.0, 1500, 0.18, 0.45), (21.0, 300, 0.5, 0.0), (6.0, 600.5, 1.0, 0.0)]),
        ("one-second steps on nitrox", None, [(d / 4.0, 1.0, 0.32, 0.0) for d in range(0, 120)]),
        ("altitude lake, 0.85 bar", 0.85, [(25.0, 1800, 0.21, 0.0)]),
        ("oxygen at the surface", None, [(40.0, 900, 0.21, 0.0), (0.0, 600, 1.0, 0.0)]),
    ]:
        engine = BuhlmannEngine() if surface is None else BuhlmannEngine(surface)
        states = [engine_state(engine)]
        for depth, seconds, f_o2, f_he in steps:
            engine.update(depth, seconds, f_o2, f_he)
            states.append(engine_state(engine))
        cases.append({"name": name, "surface_pressure": surface, "steps": [list(s) for s in steps], "states": states})
    return cases


def cns_cases():
    engine = BuhlmannEngine()
    return [
        {"po2": po2, "seconds": seconds, "expected": engine._calculate_cns_increment(po2, seconds)}
        for po2, seconds in [
            (0.21, 60), (0.5, 60), (0.55, 60), (0.6, 60), (0.65, 1), (0.7, 10), (0.95, 600), (1.0, 60), (1.3, 60),
            (1.4, 60), (1.45, 0.5), (1.5999, 60), (1.6, 60), (2.0, 60), (0.0, 60), (-1.0, 60),
        ]
    ]


def fraction_cases():
    return [
        {"setpoint": sp, "ambient": amb, "dil_o2": o2, "dil_he": he, "expected": list(ccr_effective_fractions(sp, amb, o2, he))}
        for sp, amb, o2, he in [
            (1.3, 4.0, 0.18, 0.35), (0.7, 1.01325, 0.21, 0.0), (1.3, 1.2, 0.21, 0.0), (1.3, 7.0, 0.10, 0.70),
            (1.0, 0.0, 0.18, 0.45), (1.0, -1.0, 0.18, 0.45), (1.3, 5.0, 1.0, 0.0), (1.6, 1.6, 0.21, 0.0),
        ]
    ]


def mod_cases():
    return [
        {"f_o2": f_o2, "max_po2": max_po2, "expected": mod_meters(f_o2) if max_po2 is None else mod_meters(f_o2, max_po2)}
        for f_o2, max_po2 in [(0.21, None), (0.32, None), (0.5, None), (1.0, None), (0.0, None), (-0.1, None), (0.21, 1.6), (1.0, 1.6), (1.0, 0.9), (0.18, 1.2)]
    ]


def ndl_cases():
    cases = []
    for name, steps, args in [
        ("fresh, air 18 m, GF 0.85", [], dict(depth_meters=18.0, f_o2=0.21, f_he=0.0, gf=0.85)),
        ("fresh, surface", [], dict(depth_meters=0.0, f_o2=0.21, f_he=0.0, gf=0.85)),
        ("fresh, air 40 m, GF 0.7", [], dict(depth_meters=40.0, f_o2=0.21, f_he=0.0, gf=0.7)),
        ("fresh, EAN32 30 m, 30 s steps, 20 min cap", [], dict(depth_meters=30.0, f_o2=0.32, f_he=0.0, gf=0.85, step_seconds=30.0, cap_seconds=1200)),
        ("fresh, air 12 m, 7.5 s steps, 100 s cap", [], dict(depth_meters=12.0, f_o2=0.21, f_he=0.0, gf=0.85, step_seconds=7.5, cap_seconds=100)),
        ("already in deco", [(45.0, 1800, 0.21, 0.0)], dict(depth_meters=45.0, f_o2=0.21, f_he=0.0, gf=0.7)),
        ("loaded, air 30 m", [(30.0, 600, 0.21, 0.0)], dict(depth_meters=30.0, f_o2=0.21, f_he=0.0, gf=0.85)),
    ]:
        engine = BuhlmannEngine()
        for step in steps:
            engine.update(*step)
        cases.append({"name": name, "steps": [list(s) for s in steps], "args": args, "expected": engine.compute_ndl_seconds(**args)})
    return cases


def wp(t, depth, **loop):
    return {"divetime": t, "depth": depth, "datetime": START + timedelta(seconds=t), **loop}


def gas_json(gas):
    return {"name": gas.name, "f_o2": gas.f_o2, "f_he": gas.f_he, "mod_meters": gas.mod_meters}


def result_json(results):
    seconds = sorted(results)
    assert seconds == list(range(len(seconds))), "results cover every second from 0"
    sampled = seconds[::SAMPLE_EVERY]
    return {
        "count": len(seconds),
        "tts_seconds": [results[s].tts_seconds for s in seconds],
        "sample_every": SAMPLE_EVERY,
        "samples": {
            "timestamp": [results[s].timestamp.isoformat() for s in sampled],
            "depth": [results[s].depth for s in sampled],
            "ceiling_meters": [results[s].ceiling_meters for s in sampled],
            "active_gas": [results[s].active_gas for s in sampled],
            "gf_current": [results[s].gf_current for s in sampled],
            "surf_gf": [results[s].surf_gf for s in sampled],
            "cns": [results[s].cns for s in sampled],
            "po2": [results[s].po2 for s in sampled],
        },
    }


def process_case(name, runs, gases, decompressor_args=None):
    """`runs` are waypoint lists passed one after the other to the same
    DiveDecompressor, which keeps its tissues and safety-stop state."""
    decompressor = DiveDecompressor(**(decompressor_args or {}))
    results = [result_json(decompressor.process_waypoints(waypoints, gases)) for waypoints in runs]
    return {
        "name": name,
        "decompressor": decompressor_args or {},
        "gases": [gas_json(g) for g in gases],
        "runs": [
            [{**w, "datetime": w["datetime"].isoformat()} for w in waypoints]
            for waypoints in runs
        ],
        "results": results,
    }


def process_cases():
    air = [GasDefinition("AIR", 0.21, 0.0, 56.0)]
    square = [wp(t, 30.0 if 60 <= t <= 1500 else 0.0) for t in range(0, 1800, 10)]
    deco = [
        wp(0, 0.0), wp(150, 45.0), wp(1500, 45.0), wp(1700, 21.0), wp(1900, 6.0), wp(2600, 6.0), wp(2610, 4.5),
        wp(3000, 3.0), wp(3060, 0.0),
    ]
    # Out of order, with a repeated second: the engine sorts by divetime and
    # the later of two equal seconds is the one interpolated from.
    shuffled = [deco[3], deco[0], deco[2], wp(1500, 44.0), deco[1]] + deco[4:]
    loop = dict(setpoint=1.3, diluent_o2_percent=18.0, diluent_he_percent=45.0)
    low = dict(setpoint=0.7, diluent_o2_percent=18.0)
    ccr = [
        wp(0, 0.0, **low), wp(120, 20.0, **loop), wp(300, 60.0, **loop), wp(1500, 60.0, **loop),
        wp(1800, 30.0, diluent_o2_percent=18.0, diluent_he_percent=45.0),  # bailout: no setpoint
        wp(2400, 9.0), wp(3000, 6.0), wp(3600, 0.0),
    ]
    safety = [wp(5, 2.0), wp(120, 18.0), wp(1500, 18.0), wp(1650, 5.0), wp(1850, 5.0), wp(1880, 2.5), wp(1900, 0.5), wp(1930, 0.0)]
    return [
        process_case("air square profile, default GF", [square], air),
        process_case("air and loop of tests/test_ccr.py", [
            [wp(t, 30.0 if 120 <= t <= 1800 else 0.0 if t == 0 else 15.0) for t in (0, 120, 1800, 1900)],
        ], air),
        process_case(
            "trimix deco dive with two deco gases, GF 40/85",
            [deco],
            [GasDefinition("Tx18/45", 0.18, 0.45, 67.0), GasDefinition("EAN50", 0.5, 0.0, 18.0), GasDefinition("O2", 1.0, 0.0, 4.0)],
            dict(gf_low=0.40, gf_high=0.85),
        ),
        process_case(
            "the same dive out of order, simulated every 7 s, two gases of equal O2",
            [shuffled],
            [GasDefinition("first 21", 0.21, 0.0, 56.0), GasDefinition("second 21", 0.21, 0.35, 56.0), GasDefinition("EAN50", 0.5, 0.0, 21.0)],
            dict(gf_low=0.30, gf_high=0.70, simulation_interval=7),
        ),
        process_case("rebreather with a low setpoint, then a bailout", [ccr], [GasDefinition("EAN50", 0.5, 0.0, 21.0)]),
        process_case("first sample after 0, safety stop, back to the surface", [safety], air, dict(gf_low=0.40, gf_high=0.85)),
        process_case("two dives through one decompressor", [safety, square], air),
        process_case(
            "so deep on one gas that the look-ahead gives up after 10000 s",
            [[wp(0, 0.0), wp(300, 100.0), wp(2700, 100.0), wp(2760, 90.0)]],
            [GasDefinition("Tx10/70", 0.10, 0.70, 130.0)],
        ),
        process_case("no gas fits the depth", [[wp(0, 0.0), wp(60, 70.0), wp(300, 70.0), wp(600, 0.0)]], [GasDefinition("EAN50", 0.5, 0.0, 21.0)]),
        process_case("one waypoint", [[wp(0, 12.0)]], air),
        process_case("no waypoints", [[]], air),
    ]


def model_wp(t, depth, bars=(), **kw):
    tanks = {f"T{i + 1}": TankData(pressure_bar=bar) for i, bar in enumerate(bars)}
    return Waypoint(timestamp=START + timedelta(seconds=t), depth=depth, time_since_start=t, tanks=tanks, **kw)


def steady(depth, bar_per_min, seconds=600, tanks=1, start_bar=200.0):
    """The dives of tests/test_gas_consumption.py."""
    return [model_wp(t, depth, [start_bar - bar_per_min * t / 60.0] * tanks) for t in range(0, seconds + 1, 10)]


def dump(waypoints):
    """Only what differs from the model's defaults, to keep the file small."""
    return [w.model_dump(mode="json", exclude_defaults=True) for w in waypoints]


# What the deco pass and the SAC fill can change on a waypoint.
PASS_FIELDS = (
    "tts", "ceiling", "deco_stop_depth", "gf", "surf_gf", "po2", "cns", "next_stop_depth", "next_stop_time",
    "pressure_sac", "air_remaining",
)


def sac_case(name, waypoints, **args):
    before = dump(waypoints)
    fill_sac_and_gtr(waypoints, **args)
    return {
        "name": name,
        "args": args,
        "waypoints": before,
        "pressure_sac": [w.pressure_sac for w in waypoints],
        "air_remaining": [w.air_remaining for w in waypoints],
    }


def sac_cases():
    logged = steady(20.0, 3.0, seconds=300)
    logged[-1].pressure_sac = 9.9
    logged[-1].air_remaining = 42
    logged[-3].pressure_sac = 1.5
    logged[-4].air_remaining = 7
    uneven = []
    pressure = 210.0
    for i, t in enumerate([0, 7, 19, 31, 45, 66, 90, 121, 150, 151, 185, 240, 299, 300, 420, 421, 600, 601, 700]):
        depth = [0.0, 4.0, 12.5, 18.2, 25.0, 31.7, 30.1, 24.4, 18.0, 17.9, 12.0, 9.5, 6.0, 5.9, 5.0, 4.6, 1.2, -0.3, 0.0][i]
        pressure -= [0.0, 1.3, 2.9, 3.1, 4.4, 6.7, 7.9, 9.3, 6.2, 0.1, 5.5, 6.1, 4.0, 0.0, 5.2, 0.05, 3.3, -1.0, -2.0][i]
        bars = [pressure, pressure - 12.345] if 4 <= i <= 12 else [pressure]
        uneven.append(model_wp(t, depth, bars))
    gaps = steady(15.0, 2.0, seconds=400)
    gaps[25].tanks = {}
    gaps[26].tanks = {}
    return [
        sac_case("steady 20 m, 3 bar/min", steady(20.0, 3.0)),
        sac_case("steady 20 m, 5 min", steady(20.0, 3.0, seconds=300), reserve_bar=50.0),
        sac_case("sidemount pair, 10 m", steady(10.0, 1.0, seconds=300, tanks=2), reserve_bar=50.0),
        sac_case("logged values are left alone", logged),
        sac_case("uneven samples, changing depth and tank count, pressure rising at the end", uneven),
        sac_case("two samples without tanks", gaps),
        sac_case("another window, warm-up and reserve", steady(33.0, 4.4, seconds=400), reserve_bar=35.5, window_sec=60, warmup_sec=90),
        sac_case("no tanks at all", [model_wp(t, 10.0) for t in range(0, 300, 10)]),
    ]


def pass_case(name, waypoints, gases, file_gf=None):
    before = dump(waypoints)
    # SurfGF, which parsers/deco_pass.py leaves out and the port's one
    # shared pass sets (spec §10.16), from the engine itself.
    surf_gf = None
    try:
        decompressor = DiveDecompressor(gf_low=file_gf[0], gf_high=file_gf[1]) if file_gf else DiveDecompressor()
        dicts = [dict(w.model_dump(), divetime=w.time_since_start, datetime=w.timestamp) for w in waypoints]
        results = decompressor.process_waypoints(dicts, list(gases) or [GasDefinition("AIR", 0.21, 0.0, 56.0)])
        surf_gf = [results[w.time_since_start].surf_gf for w in waypoints]
    except Exception:  # noqa: BLE001 - the pass below fails the same way
        pass
    with contextlib.redirect_stdout(sys.stderr):
        apply_deco_and_gas(waypoints, gases, file_gf)
    return {
        "name": name,
        "gases": [gas_json(g) for g in gases],
        "file_gf": None if file_gf is None else list(file_gf),
        "waypoints": before,
        "after": {field: [getattr(w, field) for w in waypoints] for field in PASS_FIELDS},
        "surf_gf": surf_gf,
    }


def pass_cases():
    def dive(**first):
        profile = [(0, 0.0), (60, 18.0), (180, 42.0), (1500, 42.0), (1700, 21.0), (1900, 9.0), (2300, 6.0), (2900, 3.0), (3000, 0.0)]
        wps = []
        for (t0, d0), (t1, d1) in zip(profile, profile[1:]):
            for t in range(t0, t1, 20):
                depth = d0 + (d1 - d0) * (t - t0) / (t1 - t0)
                wps.append(model_wp(t, round(depth, 2), [220.0 - t * 0.05]))
        wps.append(model_wp(3000, 0.0, [70.0]))
        for key, value in first.items():
            setattr(wps[0], key, value)
        return wps

    logged = dive()
    for w in logged[40:60]:
        w.deco_stop_depth, w.next_stop_time, w.tts, w.gf, w.po2 = 6.0, 120, 900, 55.5, 1.11
    for w in logged[60:70]:
        w.deco_stop_depth = 0.0
    for w in logged[70:75]:
        w.deco_stop_depth = 4.5
    loop = dive()
    for w in loop[:90]:
        w.setpoint, w.diluent_o2_percent, w.diluent_he_percent, w.divemode = 1.3, 18.0, 45.0, "closedcircuit"
    return [
        pass_case("air and EAN50, engine GFs", dive(), [deco_gas("AIR", 21.0, 0.0), deco_gas("EAN50", 50.0, 0.0)]),
        pass_case("the file's GFs", dive(), [deco_gas("AIR", 21.0, 0.0), deco_gas("EAN50", 50.0, 0.0)], parse_gf("40", "85")),
        pass_case("logged stops, TTS, GF and PO2 win", logged, [deco_gas("AIR", 21.0, 0.0)], parse_gf(30, 70)),
        pass_case("on the loop, then bailed out", loop, [deco_gas("EAN50", 50.0, 0.0)]),
        pass_case("no gases: air", dive(), []),
        pass_case("no waypoints", [], [deco_gas("AIR", 21.0, 0.0)]),
    ]


def uddf_block():
    """The deco post-processing of parsers/uddf.py, from its own source: it
    is inline in the parser and cannot be called. Returns (the block from
    the decompressor to the last waypoint field, the SAC lines after it)."""
    lines = open("parsers/uddf.py").read().split("\n")
    first = next(i for i, line in enumerate(lines) if line.strip() == "decompressor = (")
    last = next(i for i in range(first, len(lines)) if lines[i].strip().startswith("wp.next_stop_time = 0"))
    sac = next(i for i in range(last, len(lines)) if lines[i].strip().startswith('if not any(getattr(wp, "pressure_sac"'))
    block = textwrap.dedent("\n".join(lines[first:last + 1]))
    tail = textwrap.dedent("\n".join(lines[sac:sac + 2]))
    assert "wp.surf_gf = res.surf_gf" in block and "if wp.cns is None" in block and "file_logs_stops" in block, block
    assert tail.strip().endswith("fill_sac_and_gtr(waypoints)"), tail
    return block, tail


def uddf_rule_case(name, waypoints, gases, file_gf=None, file_logs_stops=False):
    """What the port's one shared pass must give (spec §10.16): the UDDF
    block run on the waypoints, a sample without a depth taken at the
    surface for the recompute and the SAC fill (spec §10.17), which is what
    the Python parsers store for a missing depth."""
    block, tail = uddf_block()
    before = dump(waypoints)
    depthless = [w for w in waypoints if w.depth is None]
    for w in depthless:
        w.depth = 0.0
    scope = dict(waypoints=waypoints, deco_gases=list(gases) or [GasDefinition("AIR", 0.21, 0.0, 56.0)], file_gf=file_gf,
                 file_logs_stops=file_logs_stops, math=math, DiveDecompressor=DiveDecompressor)
    exec(block, scope)  # noqa: S102 - the Python app's own code
    exec(tail, dict(waypoints=waypoints, fill_sac_and_gtr=fill_sac_and_gtr))  # noqa: S102
    for w in depthless:
        w.depth = None
    return {
        "name": name,
        "gases": [gas_json(g) for g in gases],
        "file_gf": None if file_gf is None else list(file_gf),
        "file_logs_stops": file_logs_stops,
        "waypoints": before,
        "after": {field: [getattr(w, field) for w in waypoints] for field in PASS_FIELDS},
    }


def uddf_rule_cases():
    def dive(step=20):
        profile = [(0, 0.0), (60, 18.0), (180, 38.0), (1500, 38.0), (1700, 21.0), (1900, 9.0), (2300, 6.0), (2900, 3.0), (3000, 0.0)]
        wps = []
        for (t0, d0), (t1, d1) in zip(profile, profile[1:]):
            for t in range(t0, t1, step):
                wps.append(model_wp(t, round(d0 + (d1 - d0) * (t - t0) / (t1 - t0), 2), [215.0 - t * 0.045]))
        wps.append(model_wp(3000, 0.0, [80.0]))
        return wps

    air = [deco_gas("AIR", 21.0, 0.0)]

    def logged(**flags):
        wps = dive()
        for w in wps[30:40]:
            w.cns = 77
        for w in wps[45:60]:
            w.deco_stop_depth, w.next_stop_time = 6.0, 120
        for w in wps[60:80]:
            w.deco_stop_depth = 0.0
        wps[62].tts = 5
        wps[70].gf, wps[70].po2, wps[70].surf_gf = 12.5, 0.99, 1.0
        return wps

    one_sac = dive()
    one_sac[10].pressure_sac = 1.23
    depthless = dive()
    depthless[30].depth = None
    depthless[130].depth = None
    depthless[131].deco_stop_depth = 0.0
    depthless[130].deco_stop_depth = 0.0
    return [
        uddf_rule_case("nothing logged", dive(), air),
        uddf_rule_case("logged CNS, stops, TTS, GF, PO2 and SurfGF; the file logs its stops", logged(), air, parse_gf(40, 85), True),
        uddf_rule_case("the same without the file logging its stops", logged(), air, parse_gf(40, 85), False),
        uddf_rule_case("one logged SAC: none filled", one_sac, air),
        uddf_rule_case("samples without a depth", depthless, [], None, True),
        uddf_rule_case("a gas with no oxygen", dive(60), [deco_gas("none", 0.0, 0.0), deco_gas("EAN32", 32.0, 0.0)]),
    ]


def gf_cases():
    return [
        {"low": low, "high": high, "expected": None if (gf := parse_gf(low, high)) is None else list(gf)}
        for low, high in [(40, 85), (30.0, 70.0), (85, 40), (0, 70), (50, 50), (50, 101), (100, 100), (-5, 50), (None, 70), (30, None)]
    ]


def deco_gas_cases():
    return [
        {"name": name, "o2_percent": o2, "he_percent": he, "expected": gas_json(deco_gas(name, o2, he))}
        for name, o2, he in [("AIR", 21.0, 0.0), ("EAN50", 50.0, 0.0), ("O2", 100.0, 0.0), ("Tx18/45", 18.0, 45.0), ("none", 0.0, 0.0), ("Tx10/70", 10.0, 70.0)]
    ]


if __name__ == "__main__":
    json.dump(
        {
            "engine": engine_cases(),
            "cns_increment": cns_cases(),
            "ccr_effective_fractions": fraction_cases(),
            "mod_meters": mod_cases(),
            "ndl": ndl_cases(),
            "process_waypoints": process_cases(),
            "sac_gtr": sac_cases(),
            "deco_pass": pass_cases(),
            "uddf_rules": uddf_rule_cases(),
            "parse_gf": gf_cases(),
            "deco_gas": deco_gas_cases(),
        },
        sys.stdout,
        separators=(",", ":"),
    )
    sys.stdout.write("\n")
