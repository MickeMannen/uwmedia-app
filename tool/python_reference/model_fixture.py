"""Parity fixture for the dive model (spec §4): models/dive.py and
models/manager.py of the Python app, on invented values.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/model_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/model/model_cases.json
"""
import json
import sys
from datetime import datetime, timedelta

sys.path.insert(0, ".")

from models.dive import Dive, TankData, Waypoint  # noqa: E402
from models.manager import DiveManager  # noqa: E402

START = datetime(2026, 1, 1, 10)


def wp(t, depth=None, **kw):
    return Waypoint(timestamp=START + timedelta(seconds=t), depth=depth, time_since_start=t, **kw)


def waypoint_expected(w):
    return {
        "gasmix": w.gasmix,
        "gas_percent": w.gas_percent,
        "circuit": w.circuit,
        "diluent_po2": w.diluent_po2,
        "primary_tank_pressure": w.primary_tank_pressure,
        "primary_tank_name": w.primary_tank_name,
        "secondary_tank_pressure": w.secondary_tank_pressure,
        "secondary_tank_name": w.secondary_tank_name,
        "log_filename": w.log_filename,
    }


def dive_case(name, dive, lookups):
    return {
        "name": name,
        "dive": dive.model_dump(mode="json"),
        "expected": {
            "is_ccr": dive.is_ccr,
            "max_depth": dive.max_depth,
            "duration": dive.duration,
            "waypoints": [waypoint_expected(w) for w in dive.waypoints],
            "lookups": [
                {
                    "at": at.isoformat(),
                    "index": None if (found := dive.get_waypoint_at(at)) is None else dive.waypoints.index(found),
                }
                for at in lookups
            ],
        },
    }


def dives():
    loop = dict(divemode="closedcircuit", diluent_o2_percent=18.0, diluent_he_percent=45.0, gas_o2_percent=18.0, gas_he_percent=45.0)
    sidemount = {
        "Left": TankData(pressure_bar=180, o2_percent=32.0),
        "Right": TankData(pressure_bar=190.5, o2_percent=32.0, name="Right Tank", mode="open_circuit", enabled=True),
    }
    oc = Dive(
        start_time=START,
        end_time=START + timedelta(seconds=95, microseconds=250000),
        waypoints=[
            wp(0, 0.0, temp=24.5, tanks=sidemount, dive_time=0),
            wp(10, 12.4, max_depth=12.4, ndl=3600, tts=120, tanks=sidemount, dive_alerts=["safety_stop_started"]),
            wp(40, None, max_depth=12.4, tanks={"1": TankData(pressure_bar=150)}),
            wp(90, 3.0, max_depth=12.4, heart_rate=88, cns=2, po2=0.42, gf=31.5, surf_gf=60.0, battery=3.9),
            # Every optional number set, each to its own value, so a wrong
            # JSON key on either side shows.
            wp(95, 1.5, temp=23.5, max_depth=12.4, deco_stop_depth=3.0, ceiling=1.25, tts=61, ndl=0, dive_time=96,
               next_stop_depth=6.0, next_stop_time=62, air_remaining=63, ascent_rate=-9.5, n2_tissue_load=101.5,
               pressure_sac=1.75, volume_sac=18.25, rmv=19.5, heart_rate=64, cns=3, po2=0.25, divemode="opencircuit",
               gf=65.5, surf_gf=66.5, switchmix=0.5, battery=3.75, cleared_gas_mix="EAN50", setpoint=1.25,
               gas_o2_percent=32.5, gas_he_percent=10.5, diluent_o2_percent=11.5, diluent_he_percent=12.5,
               po2_1=1.01, po2_2=1.02, po2_3=1.03, dive_alerts=["a", "b"]),
        ],
        device="Descent Mk3i", manufactor="Garmin", start_latitude=57.7, start_longitude=11.9,
        end_latitude=57.75, end_longitude=11.95,
        timezone="UTC+01:00", duration_seconds=95, gf_low=40, gf_high=85,
        log_filename="dive.fit", log_path="/logs/dive.fit", log_format="fit",
    )
    ccr = Dive(
        start_time=START,
        end_time=START + timedelta(seconds=120),
        waypoints=[
            wp(0, 5.0, setpoint=0.7, po2=0.7, po2_1=0.69, po2_2=0.7, po2_3=0.71, **loop),
            wp(60, 30.0, setpoint=1.3, po2=1.3, tanks={"O2": TankData(pressure_bar=180, o2_percent=100.0)}, **loop),
            wp(120, 30.0, divemode="opencircuit", gas_o2_percent=50.0, diluent_o2_percent=18.0, diluent_he_percent=45.0,
               cleared_gas_mix="EAN50", switchmix=1.0),
        ],
    )
    labels = Dive(
        start_time=START,
        end_time=START + timedelta(seconds=5),
        waypoints=[
            wp(0, 10.0, divemode="CC"), wp(1, 10.0, divemode="ccr"), wp(2, 10.0, divemode="SCR"),
            wp(3, 10.0, divemode="sc"), wp(4, 10.0, divemode="opencircuit"), wp(5, 10.0),
        ],
    )
    semiclosed = Dive(
        start_time=START, end_time=START + timedelta(seconds=1),
        waypoints=[wp(0, 4.0, divemode="semiclosedcircuit"), wp(1, 4.0, divemode="gauge")],
    )
    empty = Dive(start_time=START, end_time=START + timedelta(hours=1), waypoints=[])
    at = lambda s: START + timedelta(seconds=s)  # noqa: E731
    return [
        dive_case("open circuit, sidemount", oc, [at(-100), at(0), at(4), at(5), at(6), at(25), at(64.9), at(65), at(89), at(500)]),
        dive_case("rebreather with a bailout", ccr, [at(30), at(29.999), at(90)]),
        dive_case("circuit labels without a loop mode", labels, [at(2)]),
        dive_case("semi-closed", semiclosed, [at(0)]),
        dive_case("no waypoints", empty, [at(0)]),
    ]


def gasmix_cases():
    cases = []
    for o2, he in [
        (21.0, 0.0), (21.4, 0.0), (21.5, 0.0), (22.5, 0.0), (20.5, 0.0), (32.0, 0.0), (100.0, 0.0), (18.0, 45.0),
        (10.0, 70.0), (8.5, 0.0), (9.5, 0.0), (21.0, 0.5), (21.0, 1.5), (21.0, 0.4), (0.0, 0.0), (5.0, 2.5),
        (50.0, None), (99.5, 0.0),
    ]:
        named = wp(0, 0.0, gas_o2_percent=o2, gas_he_percent=he)
        from_tank = wp(0, 0.0, tanks={"1": TankData(pressure_bar=200, o2_percent=o2, he_percent=he or 0.0)})
        cases.append({"o2": o2, "he": he, "from_gas_fields": named.gasmix, "from_first_tank": from_tank.gasmix,
                      "percent_from_gas_fields": named.gas_percent, "percent_from_first_tank": from_tank.gas_percent})
    return cases


def diluent_po2_cases():
    return [
        {"depth": depth, "diluent_o2_percent": o2, "expected": wp(0, depth, diluent_o2_percent=o2).diluent_po2}
        for depth, o2 in [
            (30.0, 18.0), (None, 21.0), (0.0, 21.0), (2.5, 10.0), (15.0, 5.0), (7.5, 50.0), (40.0, 10.0),
            (33.3, 16.0), (6.1, 100.0), (2.5, 50.0), (27.5, 10.0), (20.0, 20.5), (45.0, 12.5),
        ]
    ]


def round_cases():
    values = [0.125, 0.375, 0.625, 2.675, 1.005, 0.005, 1.115, 2.5, 3.5, -0.125, -2.675, 0.7249999, 1.3, 0.0, 12.345, 100.125]
    others = [
        (0.25, 1), (0.75, 1), (0.35, 1), (-0.25, 1), (64.95, 1), (2.5, 0), (3.5, 0), (0.00645, 4), (0.00005, 4),
        (0.000145, 5), (0.0000235, 6), (1000000000000000.1, 0), (2986949804607827.5, 0), (4503599627370497.0, 2),
        (5e-324, 3), (1e300, 2), (0.0625, 3), (0.1875, 3), (123456.7890625, 6),
    ]
    return {
        "to_2_decimals": [{"value": v, "expected": round(v, 2)} for v in values],
        "to_digits": [{"value": v, "digits": n, "expected": round(v, n)} for v, n in others],
        "to_int": [{"value": v, "expected": round(v)} for v in [0.5, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5, 21.5, 22.5, 2.4999, 2.5001, -2.6, 0.0, 17.0]],
    }


def log_dive(start, fmt, maker=None, samples=10, path=None, end=None):
    waypoints = [Waypoint(timestamp=start + timedelta(seconds=i), depth=1.0, time_since_start=i) for i in range(samples)]
    return Dive(
        start_time=start, end_time=end or waypoints[-1].timestamp, waypoints=waypoints,
        log_format=fmt, manufactor=maker, log_path=path or f"/logs/{fmt}-{samples}",
    )


def manager_case(name, batches, finds):
    manager = DiveManager()
    for batch in batches:
        manager.add_dives(batch)
    return {
        "name": name,
        "batches": [[d.model_dump(mode="json") for d in batch] for batch in batches],
        "expected": {
            "kept": [
                {"start_time": start.isoformat(), "end_time": end.isoformat(), "log_format": d.log_format, "log_path": d.log_path}
                for (start, end), d in manager.dives.items()
            ],
            "finds": [
                {"at": at.isoformat(), "log_path": None if (found := manager.find_dive_for_timestamp(at)) is None else found.log_path}
                for at in finds
            ],
        },
    }


def manager_cases():
    start = datetime(2025, 10, 19, 11, 42, 39)
    shearwater = "Shearwater Research, Inc"
    hours = lambda h, s=0: start + timedelta(hours=h, seconds=s)  # noqa: E731
    same_file = [log_dive(start, "fit", samples=5), log_dive(start, "fit", samples=6)]
    same_file[1].log_path = same_file[0].log_path
    return [
        manager_case(
            "richest copy of one dive",
            [
                [log_dive(start, "subsurface_csv", samples=11)],
                [log_dive(start + timedelta(seconds=8), "shearwater_csv", shearwater)],
                [log_dive(start, "subsurface_xml", "Shearwater")],
            ],
            [start, start - timedelta(minutes=30), start - timedelta(minutes=30, seconds=1), start + timedelta(seconds=17), start + timedelta(seconds=18)],
        ),
        manager_case(
            "equal rank: more samples wins, a tie goes to the later one",
            [
                [log_dive(start, "uddf", shearwater, samples=5)],
                [log_dive(start, "shearwater_xml", shearwater, samples=20)],
                [log_dive(start, "fit", "shearwater,", samples=20, path="/logs/tie")],
            ],
            [start],
        ),
        manager_case(
            "only dives from different log files merge",
            [same_file + [log_dive(hours(3), None), log_dive(hours(3, 5), None, samples=4)]],
            [start, hours(3, 2), hours(3, 20)],
        ),
        manager_case(
            "two computers on one dive stay two dives",
            [
                [log_dive(start, "fit", "garmin"), log_dive(start, "uddf", shearwater, samples=12)],
                [log_dive(hours(2), "uddf", shearwater)],
            ],
            [start, start + timedelta(seconds=10), hours(2)],
        ),
        manager_case(
            "start tolerance and makers",
            [
                [log_dive(start, "uddf", None, samples=7, path="/logs/a")],
                [log_dive(start + timedelta(seconds=60), "subsurface_xml", "Suunto", samples=8, path="/logs/b")],
                [log_dive(start + timedelta(seconds=61), "fit", "Garmin", samples=3, path="/logs/c")],
                [log_dive(start + timedelta(seconds=61), "fit", " Garmin Ltd", samples=2, path="/logs/d")],
                [log_dive(start + timedelta(seconds=30), "bogus", None, samples=9, path="/logs/e")],
            ],
            [start, start + timedelta(seconds=61)],
        ),
        manager_case(
            "the same start and end replaces in place",
            [
                [log_dive(start, None, samples=3, path="/mem/1"), log_dive(hours(1), None, samples=3, path="/mem/2")],
                [log_dive(start, None, samples=3, path="/mem/3")],
            ],
            [start],
        ),
    ]


if __name__ == "__main__":
    json.dump(
        {
            "dives": dives(),
            "gasmix": gasmix_cases(),
            "diluent_po2": diluent_po2_cases(),
            "round": round_cases(),
            "manager": manager_cases(),
        },
        sys.stdout,
        separators=(",", ":"),
    )
    sys.stdout.write("\n")
