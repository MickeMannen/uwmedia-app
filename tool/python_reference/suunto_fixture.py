"""Parity fixture for the Suunto app JSON export parser (spec §4.1):
parsers/suunto.py of the Python app (0.8.0), on invented exports. The
export texts are part of the fixture (base64), so the Dart test parses
exactly what Python parsed; every value in them is made up (no serial, no
GPS, no real dive), built the way tests/test_suunto.py builds its files.

For each export: the registry's format, the dives parsed by
`parse_log_file` (every field, without the `None` ones), `gasmix` and
`gas_percent` of every waypoint, the builder's `logged_plan_parts` and
`plan_from_log` (default base), or the exception's name.

Python's parsers/deco_pass.py (which this parser calls) differs from the
port's one shared pass (spec §10.16) in `surf_gf` only for this format
(set by the port, absent here); SAC and gas time are filled by both on
every sample, as no Suunto export logs a SAC.

Run from the Python repo's root with its own interpreter and write the
output into this repo (the files are written to a temporary folder;
nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/suunto_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/dives/suunto.json
"""
import base64
import contextlib
import dataclasses
import io
import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, ".")

from models.dive_plan import DiveProfilePlan  # noqa: E402
from parsers.registry import detect_log_format, parse_log_file  # noqa: E402
from parsers.suunto import is_suunto_json  # noqa: E402
from utils import dive_plan_import as I  # noqa: E402

START = datetime(2026, 5, 2, 10, 0, 0, tzinfo=timezone(timedelta(hours=7)))


def at(seconds, start=START):
    return (start + timedelta(seconds=seconds)).isoformat(timespec="milliseconds")


def doc(header, samples, start=START):
    header = {"ActivityType": 51, "DateTime": start.isoformat(timespec="milliseconds"), **header}
    return json.dumps({"DeviceLog": {"Header": header, "Samples": samples}}).encode()


def eon():
    """tests/test_suunto.py `_eon`."""
    header = {
        "Device": {"Name": "EON Core", "SerialNumber": "0000000000"},
        "Duration": 90,
        "Diving": {
            "Algorithm": "Suunto Fused2 RGBM",
            "Gases": [
                {"State": "Primary", "Oxygen": 0.32, "Helium": 0, "TankSize": 0.012, "StartPressure": 20000000},
                {"State": "Primary", "Oxygen": 0.5, "Helium": 0, "TankSize": 0.0057},
            ],
        },
    }
    samples = [
        {"TimeISO8601": at(0), "Events": [{"State": {"Type": "Dive Active", "Active": True}}, {"GasSwitch": {"GasNumber": 1}}]},
        {"TimeISO8601": at(10), "Depth": 10.0, "Temperature": 293.15, "NoDecTime": 6000, "TimeToSurface": 60,
         "Ceiling": 0, "GasTime": 3000, "Ventilation": 0.0002,
         "Cylinders": [{"GasNumber": 1, "Pressure": 19500000}]},
        {"TimeISO8601": at(30), "Depth": 30.0, "NoDecTime": 0, "TimeToSurface": 600, "Ceiling": 6.0,
         "Cylinders": [{"GasNumber": 1, "Pressure": 18000000}]},
        {"TimeISO8601": at(20), "Depth": 20.0, "NoDecTime": 300, "TimeToSurface": 120},
        {"TimeISO8601": at(30.4), "Depth": 31.0},
        {"TimeISO8601": at(35), "Events": [{"Warning": {"Type": "Ceiling Broken", "Active": True}},
                                            {"Notify": {"Type": "Deco Window", "Active": False}}]},
        {"TimeISO8601": at(40), "Events": [{"GasSwitch": {"GasNumber": 2}}]},
        {"TimeISO8601": at(50), "Depth": 6.0, "NoDecTime": -1, "Ceiling": 3.0},
        {"TimeISO8601": at(90), "Depth": 0.5, "NoDecTime": 6000, "TimeToSurface": 0, "Ceiling": 0},
    ]
    return doc(header, samples)


def nautic():
    """tests/test_suunto.py `_nautic`."""
    header = {"Device": {"Name": "Vaasa"}, "DiveTime": 60, "Duration": 200}
    samples = [
        {"TimeISO8601": at(0), "DiveEvents": {"GasSwitch": {"GasNumber": 0}}},
        {"TimeISO8601": at(5), "Depth": 5.0, "NoDecTime": 6000, "TimeToSurface": 30,
         "Cylinders": [{"GasNumber": 0, "Pressure": 20000000, "Pressure2": 19000000, "GasTime": 1200, "Ventilation": 0.00025},
                       {"GasNumber": 1, "Pressure": None, "GasTime": 0, "Ventilation": 0}]},
        {"TimeISO8601": at(10), "Temperature": 300.15},
        {"TimeISO8601": at(20), "Depth": 18.0, "DiveEvents": [{"Alarm": {"Type": "PO2 High", "Active": True}}]},
        {"TimeISO8601": at(60), "Depth": 1.0,
         "Cylinders": [{"GasNumber": 0, "Pressure": 15000000, "Pressure2": 14000000, "GasTime": 900, "Ventilation": 0.0002}]},
        {"TimeISO8601": at(150), "Depth": 0.0, "Cylinders": [{"GasNumber": 0, "Pressure": 14062}]},
    ]
    return doc(header, samples)


def long_dive():
    """A 40 m dive of 35 minutes on 21/35 and 50 %, 10 s records, a logged
    ceiling on the ascent, a switch at 21 m, a Bühlmann algorithm."""
    header = {
        "Device": {"Name": "EON Steel"}, "Duration": 2200,
        "Diving": {
            "Algorithm": "Suunto Bühlmann 16 GF",
            "Gases": [
                {"Oxygen": 0.21, "Helium": 0.35, "TankSize": 0.024, "StartPressure": 21000000},
                {"Oxygen": 0.5, "Helium": 0, "TankSize": 0.0057, "TankFillPressure": 20000000},
            ],
        },
    }
    samples = [{"TimeISO8601": at(0), "Events": [{"GasSwitch": {"GasNumber": 1}}]}]
    pa = 21000000
    for t in range(10, 2201, 10):
        if t <= 160:
            depth = 40.0 * t / 160
        elif t <= 1200:
            depth = 40.0
        elif t <= 1700:
            depth = 40.0 - 34.0 * (t - 1200) / 500
        elif t <= 2100:
            depth = 6.0
        else:
            depth = max(0.0, 6.0 - 6.0 * (t - 2100) / 100)
        pa -= 20000
        s = {"TimeISO8601": at(t), "Depth": round(depth, 2), "Temperature": 285.15 + (t % 50) / 100.0,
             "Cylinders": [{"GasNumber": 2 if t > 1500 else 1, "Pressure": pa}]}
        if t % 30 == 0:
            s["NoDecTime"] = 6000 if t < 100 else -1
        if t >= 1500 and t % 20 == 0:
            s["Ceiling"] = 6.0 if t < 2000 else 3.0
        if t == 1500:
            s["Events"] = [{"GasSwitch": {"GasNumber": 2}}]
        samples.append(s)
    return doc(header, samples)


def odd_cases():
    z = datetime(2026, 5, 2, 3, 0, 0, tzinfo=timezone.utc)
    basic = [{"TimeISO8601": at(0), "Depth": 0.0}, {"TimeISO8601": at(10), "Depth": 5.0}, {"TimeISO8601": at(20), "Depth": 3.0}]
    out = [
        ("EON Core, tests/test_suunto.py", "eon.json", eon()),
        ("Nautic, tests/test_suunto.py", "nautic.json", nautic()),
        ("40 m trimix dive with a logged ceiling", "long.json", long_dive()),
        ("another JSON file: settings", "settings.json", json.dumps({"units": "metric"}).encode()),
        ("another JSON file: a list", "list.json", b"[1, 2]"),
        ("not JSON", "broken.json", b'{"DeviceLog": '),
        ("not a dive: a run", "run.json", doc({"ActivityType": 3}, [{"TimeISO8601": at(0), "Speed": 3.1}])),
        ("no samples", "empty.json", doc({}, [])),
        ("no start time", "nostart.json", json.dumps({"DeviceLog": {"Header": {"ActivityType": 51}, "Samples": basic}}).encode()),
        ("UTF-8 byte order mark", "bom.json", b"\xef\xbb\xbf" + doc({}, basic)),
        ("Z time zone", "z.json", doc({}, [{**s, "TimeISO8601": s["TimeISO8601"]} for s in basic], start=z)),
        ("no time zone", "naive.json", doc({}, [{"TimeISO8601": "2026-05-02T10:00:%02d" % t, "Depth": d} for t, d in ((0, 0.0), (10, 5.0))]).replace(b"+07:00", b"")),
        ("negative offset, microsecond start", "neg.json", json.dumps({"DeviceLog": {"Header": {"ActivityType": 51, "DateTime": "2026-05-02T10:00:00.123456-03:30"}, "Samples": [
            {"TimeISO8601": "2026-05-02T10:00:00.123456-03:30", "Depth": 0.0}, {"TimeISO8601": "2026-05-02T10:00:10.6-03:30", "Depth": 4.0}]}}).encode()),
        ("samples in another zone than the header", "zones.json", json.dumps({"DeviceLog": {"Header": {"ActivityType": 51, "DateTime": "2026-05-02T10:00:00+07:00"}, "Samples": [
            {"TimeISO8601": "2026-05-02T03:00:00Z", "Depth": 0.0}, {"TimeISO8601": "2026-05-02T03:00:10+00:00", "Depth": 4.0}, {"TimeISO8601": "2026-05-02T10:00:20+07:00", "Depth": 4.0}]}}).encode()),
        ("sample naive, header with a zone", "mixed.json", json.dumps({"DeviceLog": {"Header": {"ActivityType": 51, "DateTime": "2026-05-02T10:00:00+07:00"}, "Samples": [
            {"TimeISO8601": "2026-05-02T10:00:00", "Depth": 0.0}]}}).encode()),
        ("date and time split by a space", "space.json", json.dumps({"DeviceLog": {"Header": {"ActivityType": 51, "DateTime": "2026-05-02 10:00:00+07:00"}, "Samples": [
            {"TimeISO8601": "2026-05-02 10:00:00+07:00", "Depth": 0.0}, {"TimeISO8601": "garbage", "Depth": 9.0}, {"Depth": 9.0}, "text", {"TimeISO8601": "2026-05-02 10:00:05+07:00", "Depth": 2.0}]}}).encode()),
        ("DeviceLog is null", "bare.json", json.dumps({"Header": {"ActivityType": 51, "DateTime": START.isoformat()}, "Samples": basic, "DeviceLog": None}).encode()),
        ("records before the start", "before.json", doc({}, [{"TimeISO8601": at(-10), "Depth": 3.0}, *basic])),
        ("Ocean: internal name, Celsius, negative depth and ceiling", "ocean.json", doc({"Device": {"Name": "Porvoo"}}, [
            {"TimeISO8601": at(0), "Depth": -0.2, "Temperature": 26.4, "Ceiling": -1.0},
            {"TimeISO8601": at(10), "Depth": 12.34, "Temperature": 26.0, "Ceiling": 1.5, "NoDecTime": 0, "TimeToSurface": 7.9}])),
        ("device in the log, not the header", "device.json", json.dumps({"DeviceLog": {"Device": {"Name": " D5 "}, "Header": {"ActivityType": 51, "DateTime": START.isoformat()}, "Samples": basic}}).encode()),
        ("Nautic with a gas list: 40/85 gradient factors", "nautic_gas.json", doc({"Device": {"Name": "Vaasa"}, "Diving": {"Gases": [
            {"GasNumber": 0, "Oxygen": 0.21, "Helium": 0}, {"GasNumber": 1, "Oxygen": 0.36, "Helium": 0.1, "TankSize": 0, "StartPressure": 0, "TankFillPressure": 23000000}]}}, [
            {"TimeISO8601": at(0), "DiveEvents": [{"GasSwitch": {"GasNumber": 0}}]},
            {"TimeISO8601": at(10), "Depth": 20.0, "Cylinders": [{"GasNumber": 1, "Pressure": 22000000, "Pressure3": 21000000, "GasTime": "840", "Ventilation": "0.0003"}]},
            {"TimeISO8601": at(20), "Depth": 20.0, "DiveEvents": {"GasSwitch": {"GasNumber": 1}}},
            {"TimeISO8601": at(30), "Depth": 21.0, "Cylinders": [{"GasNumber": 1, "Pressure": 21900000, "GasTime": None}]},
            {"TimeISO8601": at(40), "Depth": 5.0, "DiveEvents": {"GasSwitch": {"GasNumber": 7}}}])),
        ("EON with a Buhlmann algorithm, explicit gas numbers, a gas with a text number", "buhlmann.json", doc({"Diving": {"Algorithm": "Buhlmann 16", "Gases": [
            {"GasNumber": "3", "Oxygen": 0.3}, {"GasNumber": 1.9, "Oxygen": 0.18, "Helium": 0.45, "TankSize": 0.0113}, {"Oxygen": 0.99}, "text"]}}, [
            {"TimeISO8601": at(0), "Depth": 1.0}, {"TimeISO8601": at(10), "Depth": 2.0, "Cylinders": [{"GasNumber": 1, "Pressure": 1000000}, {"Pressure": 5}, "x"]},
            {"TimeISO8601": at(20), "Depth": 3.0, "Cylinders": {"a": 1}}])),
        ("events: alerts, states, repeats, a type with no name, an inactive one", "events.json", doc({}, [
            {"TimeISO8601": at(0), "Depth": 0.0, "Events": [{"Alarm": {"Type": "CNS 80%", "Active": True}}, {"Alarm": {"Type": "CNS 100", "Active": True}},
                                                               {"State": {"Type": "Dive Active", "Active": True}}, {"Alarm": {"Type": "", "Active": True}}]},
            {"TimeISO8601": at(5), "Events": [{"Warning": {"Type": "Ascent Speed"}}, {"Warning": {"Type": "Ascent Speed", "Active": True}},
                                               {"Warning": {"Type": "Safety Stop Broken", "Active": None}}, {"Notify": {"Type": "Ceiling Broken", "Active": False}},
                                               {"Other": {"Type": "x"}}, {"Alarm": "text"}]},
            {"TimeISO8601": at(10), "Depth": 5.0, "DiveEvents": [{"Alarm": {"Type": "PO2 Low", "Active": True}}, {"Alarm": {"Type": "OTU 250", "Active": True}}, {"Alarm": {"Type": "Odd Thing", "Active": 0}}]},
            {"TimeISO8601": at(20), "Depth": 6.0}])),
        ("same second twice, a record without a depth, text numbers, ndl and ttl limits", "values.json", doc({"DiveTime": 100}, [
            {"TimeISO8601": at(0), "Depth": 0.0, "NoDecTime": -5, "TimeToSurface": -3},
            {"TimeISO8601": at(0.4), "Depth": 1.0, "Temperature": 280.0, "NoDecTime": "90", "TimeToSurface": "12.9"},
            {"TimeISO8601": at(0.6), "Depth": 2.0},
            {"TimeISO8601": at(15), "Temperature": 14.5, "Ceiling": 4.5, "GasTime": 0, "Ventilation": 0},
            {"TimeISO8601": at(20), "Depth": "7.5", "Ceiling": "x", "Temperature": True, "GasTime": 600, "Ventilation": 0.0001},
            {"TimeISO8601": at(100), "Depth": 2.0, "Ceiling": 0}, {"TimeISO8601": at(101), "Depth": 2.0}])),
        ("not a scuba activity as text", "text_activity.json", doc({"ActivityType": "51"}, basic)),
        ("a scuba activity as 51.0", "float_activity.json", doc({"ActivityType": 51.0}, basic)),
    ]
    return out


def dump_parts(parts):
    return dataclasses.asdict(parts)


def run(path):
    entry = {}
    with contextlib.redirect_stdout(io.StringIO()):
        entry["format"] = detect_log_format(path)
        try:
            dives = parse_log_file(path)
        except Exception as e:  # noqa: BLE001
            entry["raise"] = type(e).__name__
            return entry
        if dives is None:
            entry["dives"] = None
            return entry
        entry["dives"] = [
            {**d.model_dump(mode="json", exclude={"log_path"}, exclude_none=True),
             "max_depth_property": d.max_depth,
             "gasmix": [w.gasmix for w in d.waypoints], "gas_percent": [w.gas_percent for w in d.waypoints]}
            for d in dives
        ]
        if dives:
            try:
                entry["parts"] = dump_parts(I.logged_plan_parts(path, dives[0]))
            except Exception as e:  # noqa: BLE001
                entry["parts"] = {"raise": type(e).__name__}
            try:
                plan = I.plan_from_log(path, dives[0], DiveProfilePlan.model_validate({}))
                entry["plan"] = ["ok", plan.model_dump(mode="json")]
            except Exception as e:  # noqa: BLE001
                entry["plan"] = ["raise", type(e).__name__]
    return entry


if __name__ == "__main__":
    cases = []
    with tempfile.TemporaryDirectory() as tmp_name:
        for i, (name, file_name, data) in enumerate(odd_cases()):
            folder = Path(tmp_name) / str(i)
            folder.mkdir()
            path = folder / file_name
            path.write_bytes(data)
            cases.append({"name": name, "file_name": file_name, "bytes_base64": base64.b64encode(data).decode(), **run(path)})
    heads = ['{"DeviceLog": 1}', '{"deviceLog": 1}', "", '{"x": "DeviceLog"}', '"DeviceLog"']
    json.dump({"parse": cases, "is_suunto_json": [[h, is_suunto_json(h)] for h in heads]}, sys.stdout, separators=(",", ":"))
