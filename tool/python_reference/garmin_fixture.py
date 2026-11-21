"""Parity fixture for the Garmin FIT parser (spec §4.1): parsers/garmin.py
of the Python app.

Two parts:

- `messages`: decoded-message dicts handed to the parser in place of the
  FIT decoder's output, as the Python tests do (tests/test_garmin_parsing.py;
  the cases are named after the test), plus odd ones. Every value and
  serial is invented.
- `files`: two FIT files written by the app's own FIT writer from invented
  plans, the messages the Python FIT SDK decodes from them, and the dives.
  The file bytes are part of the fixture.

A timestamp is written as {"$utc": "YYYY-MM-DDTHH:MM:SS"} where the Python
SDK gives a datetime, and as a number where it gives raw FIT seconds. The
dives are dumped without their `None` fields. No config.yaml is read: the
tank names are set per case.

Run from the Python repo's root with its own interpreter and write the
output into this repo (files are written to a temporary folder; nothing is
written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/garmin_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/dives/garmin.json
"""
import base64
import contextlib
import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, ".")

import utils.config as config  # noqa: E402

config.user_config_yaml_path = lambda: Path("/nonexistent/config.yaml")
config.bundled_config_yaml_path = lambda: None
config.ConfigManager._instance = None

import parsers.garmin as garmin  # noqa: E402
from garmin_fit_sdk import Decoder, Stream  # noqa: E402
from models.dive_plan import DiveProfilePlan, PlannedGas, PlannedWaypoint  # noqa: E402
from parsers.fit_writer import write_fit  # noqa: E402
from parsers.garmin import GarminParser, setpoint_timeline, timezone_from_pair  # noqa: E402
from utils.dive_plan_engine import plan_ascent, simulate  # noqa: E402

FIT_EPOCH = datetime(1989, 12, 31, tzinfo=timezone.utc)
START_UTC = datetime(2026, 5, 2, 3, 0, 0, tzinfo=timezone.utc)  # 10:00 at UTC+7

# The message lists and fields the Dart reader is compared on: what the
# parser reads.
READ_FIELDS = {
    "file_id_mesgs": ["manufacturer", "garmin_product"],
    "activity_mesgs": ["timestamp", "local_timestamp", "total_timer_time"],
    "session_mesgs": ["start_time", "total_elapsed_time", "start_position_lat", "start_position_long",
                      "end_position_lat", "end_position_long"],
    "device_info_mesgs": ["serial_number", "descriptor", "product_name"],
    "dive_gas_mesgs": ["message_index", "helium_content", "oxygen_content", "mode", "status"],
    "event_mesgs": ["timestamp", "event", "data", "dive_alert"],
    "tank_update_mesgs": ["timestamp", "sensor", "pressure"],
    "dive_settings_mesgs": ["ccr_low_setpoint", "ccr_high_setpoint"],
    "record_mesgs": ["timestamp", "depth", "temperature", "next_stop_depth", "next_stop_time", "time_to_surface", "ndl_time",
                     "air_time_remaining", "ascent_rate", "n2_load", "pressure_sac", "volume_sac", "rmv", "heart_rate",
                     "cns_load", "po2"],
}


def fit_int(dt):
    return int((dt - FIT_EPOCH).total_seconds())


def local_int(dt, offset_hours):
    return fit_int(dt) + offset_hours * 3600


def t(seconds):
    return START_UTC + timedelta(seconds=seconds)


def records(n=3, step=60, depth=10.0, as_int=False):
    out = []
    for i in range(n):
        ts = START_UTC + timedelta(seconds=i * step)
        out.append({"timestamp": fit_int(ts) if as_int else ts, "depth": 0.0 if i in (0, n - 1) else depth,
                    "temperature": 27, "ndl_time": 1800, "time_to_surface": 60, "po2": 0.6})
    return out


def activity(**extra):
    return [{"timestamp": START_UTC, "local_timestamp": local_int(START_UTC, 7), "total_timer_time": 120.0, **extra}]


def jsonable(value):
    if isinstance(value, datetime):
        assert value.tzinfo is not None and value.utcoffset() == timedelta(0), value
        return {"$utc": value.replace(tzinfo=None).isoformat()}
    if isinstance(value, dict):
        return {k: jsonable(v) for k, v in value.items() if isinstance(k, str)}
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    return value


def dump_dives(dives):
    return [
        {
            **d.model_dump(mode="json", exclude={"log_path"}, exclude_none=True),
            "max_depth_property": d.max_depth,
            "is_ccr": d.is_ccr,
            "circuits": [w.circuit for w in d.waypoints],
            "gasmixes": [w.gasmix for w in d.waypoints],
        }
        for d in dives
    ]


def parse_messages(messages):
    class FakeStream:
        @staticmethod
        def from_file(_name):
            return None

    class FakeDecoder:
        def __init__(self, _stream):
            pass

        def read(self):
            return messages, []

    real = garmin.Stream, garmin.Decoder
    garmin.Stream, garmin.Decoder = FakeStream, FakeDecoder
    try:
        with contextlib.redirect_stdout(sys.stderr):
            return GarminParser().parse(Path("/logs/dive.fit"))
    finally:
        garmin.Stream, garmin.Decoder = real


def message_cases():
    no_po2 = [{k: v for k, v in r.items() if k != "po2"} for r in records(3, depth=20.0)]
    ndl = records(n=4)
    del ndl[1]["ndl_time"]
    ndl[2]["ndl_time"] = 0
    raw_activity = activity()
    raw_activity[0]["timestamp"] = fit_int(START_UTC)
    end = START_UTC + timedelta(seconds=120)
    ccr_gases = [{"message_index": 0, "oxygen_content": 18, "helium_content": 20, "mode": "closed_circuit_diluent", "status": "enabled"},
                 {"message_index": 1, "oxygen_content": 50, "helium_content": 0, "mode": "open_circuit", "status": "enabled"}]
    full_record = {"depth": 21.5, "temperature": 24, "next_stop_depth": 6.0, "next_stop_time": 120, "time_to_surface": 615,
                   "ndl_time": 0, "air_time_remaining": 1234, "ascent_rate": -0.15, "n2_load": 104, "pressure_sac": 1.17,
                   "volume_sac": 14.12, "rmv": 19.5, "heart_rate": 88, "cns_load": 12, "po2": 0.66}
    cases = [
        ("test_activity_timing_device_and_records", {
            "file_id_mesgs": [{"garmin_product": "descent_mk3i", "manufacturer": "garmin"}],
            "activity_mesgs": activity(), "record_mesgs": records()}, None),
        ("test_record_defaults_for_missing_fields", {
            "activity_mesgs": activity(),
            "record_mesgs": [{"timestamp": START_UTC}, {"no": "timestamp"}, {"timestamp": START_UTC + timedelta(seconds=10)}]}, None),
        ("test_missing_ndl_is_unbounded_and_a_logged_zero_is_deco", {"activity_mesgs": activity(), "record_mesgs": ndl}, None),
        ("test_raw_integer_timestamps_are_fit_epoch_seconds", {
            "activity_mesgs": raw_activity, "record_mesgs": records(as_int=True),
            "tank_update_mesgs": [{"timestamp": fit_int(START_UTC), "sensor": 111, "pressure": 200.0}],
            "event_mesgs": [{"event": "dive_alert", "dive_alert": "ndl_reached", "timestamp": fit_int(t(60))}]}, None),
        ("test_activity_without_local_time_is_utc", {
            "activity_mesgs": [{"timestamp": START_UTC, "total_timer_time": 60.0}], "record_mesgs": records(2)}, None),
        *[(f"test_session_is_the_fallback_without_an_activity[{as_int}]", {
            "session_mesgs": [{"start_time": fit_int(START_UTC) if as_int else START_UTC, "local_timestamp": local_int(START_UTC, -5),
                               "total_elapsed_time": 300.0, "start_position_lat": 2 ** 30, "start_position_long": -(2 ** 29),
                               "end_position_lat": 0, "end_position_long": None}],
            "record_mesgs": records()}, None) for as_int in (False, True)],
        ("test_session_without_local_time_is_utc", {"session_mesgs": [{"start_time": START_UTC}], "record_mesgs": records(2)}, None),
        ("test_no_timing_messages_gives_no_dive", {"record_mesgs": records()}, None),
        ("test_no_records_gives_no_dive", {"activity_mesgs": activity()}, None),
        ("test_tank_updates_merge_onto_records", {
            "activity_mesgs": activity(), "record_mesgs": records(4),
            "device_info_mesgs": [{"serial_number": 111, "descriptor": "Left"}, {"serial_number": 222, "product_name": "Tank Pod"},
                                  {"serial_number": None, "descriptor": "watch"}],
            "dive_gas_mesgs": [{"message_index": 0, "oxygen_content": 32, "helium_content": 0, "status": "enabled"},
                               {"message_index": 1, "oxygen_content": 18, "helium_content": 45, "status": "disabled",
                                "mode": "closed_circuit_diluent"},
                               {"oxygen_content": 50}],
            "tank_update_mesgs": [
                {"timestamp": t(0), "sensor": 111, "pressure": 210.0, "gas_type_index": 0},
                {"timestamp": t(60), "sensor": 111, "pressure": 200.0, "gas_type_index": 0},
                {"timestamp": t(60), "sensor": 222, "pressure": 190.0, "gas_type_index": 1},
                {"timestamp": t(120), "gas_type_index": 7, "pressure": 180.0}]}, None),
        ("test_tank_order_follows_the_sensor_names_order", {
            "activity_mesgs": activity(), "record_mesgs": records(3),
            "tank_update_mesgs": [
                {"timestamp": t(0), "sensor": 333, "pressure": 100.0}, {"timestamp": t(0), "sensor": 111, "pressure": 210.0},
                {"timestamp": t(60), "sensor": 222, "pressure": 190.0}, {"timestamp": t(60), "sensor": 111, "pressure": 200.0}]},
         {"222": "Left", "111": "Right"}),
        ("test_dive_alerts_land_on_the_next_record", {
            "activity_mesgs": activity(), "record_mesgs": records(3),
            "event_mesgs": [
                {"event": "dive_alert", "dive_alert": "safety_stop_started", "timestamp": t(90)},
                {"event": "dive_alert", "dive_alert": 59, "timestamp": t(30)},
                {"event": "dive_alert", "dive_alert": "ndl_reached", "timestamp": t(60)},
                {"event": "timer", "timestamp": t(60)},
                {"event": "dive_alert", "dive_alert": None, "timestamp": t(60)},
                {"event": "dive_alert", "dive_alert": "deco_ceiling_broken"}]}, None),
        ("test_unmapped_product_id_is_named", {
            "file_id_mesgs": [{"garmin_product": 4518, "manufacturer": "garmin"}],
            "activity_mesgs": activity(), "record_mesgs": records(2)}, None),
        ("test_tanks_take_the_gas_switched_to", {
            "activity_mesgs": activity(), "record_mesgs": records(4),
            "dive_gas_mesgs": [{"message_index": 0, "oxygen_content": 31, "helium_content": 0, "status": "enabled"},
                               {"message_index": 1, "oxygen_content": 50, "helium_content": 0, "status": "enabled"}],
            "event_mesgs": [{"timestamp": t(0), "event": "dive_gas_switched", "event_type": "marker", "data": 0},
                            {"timestamp": t(120), "event": "dive_gas_switched", "event_type": "marker", "data": 1},
                            {"timestamp": t(150), "event": "dive_gas_switched", "event_type": "marker", "data": 9}],
            "tank_update_mesgs": [{"timestamp": t(0), "sensor": 111, "pressure": 210.0},
                                  {"timestamp": fit_int(t(60)), "sensor": 222, "pressure": 190.0}]}, None),
        ("test_first_listed_gas_when_nothing_was_switched", {
            "activity_mesgs": activity(), "record_mesgs": records(2),
            "dive_gas_mesgs": [{"message_index": 0, "oxygen_content": 32, "helium_content": 0, "status": "enabled"}],
            "tank_update_mesgs": [{"timestamp": START_UTC, "sensor": 111, "pressure": 200.0}]}, None),
        ("test_po2_without_a_logged_value_is_the_gas_at_depth", {
            "activity_mesgs": activity(), "record_mesgs": no_po2,
            "dive_gas_mesgs": [{"message_index": 0, "oxygen_content": 32, "helium_content": 0, "status": "enabled"}]}, None),
        ("test_rebreather_setpoints_from_the_switch_alerts_and_bailout", {
            "activity_mesgs": activity(),
            "record_mesgs": [{"timestamp": t(60 * i), "depth": d} for i, d in enumerate([2.0, 30.0, 30.0, 30.0, 10.0, 0.0])],
            "dive_gas_mesgs": ccr_gases,
            "dive_settings_mesgs": [{"ccr_low_setpoint": 0.7, "ccr_high_setpoint": 1.3}],
            "event_mesgs": [{"timestamp": t(60), "event": "dive_alert", "dive_alert": "setpoint_switch_auto_high"},
                            {"timestamp": t(180), "event": "dive_alert", "dive_alert": "setpoint_switch_manual_low"},
                            {"timestamp": t(240), "event": "dive_gas_switched", "data": 1}]}, None),
        ("test_no_setpoint_without_a_switch", {
            "activity_mesgs": activity(),
            "record_mesgs": [{"timestamp": START_UTC + timedelta(seconds=60 * i), "depth": d} for i, d in enumerate([0.0, 20.0, 0.0])],
            "dive_gas_mesgs": [{"message_index": 0, "oxygen_content": 21, "helium_content": 0, "mode": "closed_circuit_diluent", "status": "enabled"}],
            "dive_settings_mesgs": [{"ccr_low_setpoint": 0.7, "ccr_high_setpoint": 1.3}]}, None),
        ("test_the_session_start_wins_over_an_activity_stamped_at_the_end", {
            "activity_mesgs": [{"timestamp": end, "local_timestamp": local_int(end, 7), "total_timer_time": 120.0}],
            "session_mesgs": [{"start_time": START_UTC}], "record_mesgs": records()}, None),
        ("every record field, a deco dive on two gases, a half-hour zone, a fractional duration", {
            "file_id_mesgs": [{"garmin_product": 9999, "manufacturer": 300}],
            "activity_mesgs": [{"timestamp": START_UTC, "local_timestamp": fit_int(START_UTC) + 5 * 3600 + 30 * 60 + 29,
                                "total_timer_time": 1830.466}],
            "session_mesgs": [{"start_time": START_UTC, "start_position_lat": 50698327, "start_position_long": 1415324494,
                               "end_position_lat": -50698352, "end_position_long": 1415322408}],
            "device_info_mesgs": [{"serial_number": 0, "descriptor": "zero"}, {"serial_number": 7, "descriptor": "", "nickname": "Nick"}],
            "dive_gas_mesgs": [{"message_index": 2, "oxygen_content": 50, "helium_content": 0, "status": "enabled"},
                               {"message_index": 1, "oxygen_content": 21, "status": "enabled"},
                               {"message_index": 3, "oxygen_content": 100, "status": "backup_only"},
                               {"message_index": 4, "oxygen_content": 0, "status": "enabled"}],
            "event_mesgs": [{"timestamp": t(61), "event": "dive_gas_switched", "data": 1},
                            {"timestamp": t(1500), "event": "dive_gas_switched", "data": 2},
                            {"timestamp": t(1500), "event": "dive_alert", "dive_alert": "gas_switch_prompted"},
                            {"timestamp": t(1500), "event": "dive_alert", "dive_alert": "deco_ceiling_broken"}],
            "tank_update_mesgs": [{"timestamp": t(30), "sensor": 7, "pressure": 201.5}, {"timestamp": t(30), "sensor": 0, "pressure": 55.0},
                                  {"timestamp": t(900), "sensor": 7}, {"timestamp": t(1200), "sensor": 7, "pressure": 120.25}],
            "record_mesgs": [{"timestamp": t(s), **full_record, "depth": d}
                             for s, d in [(-5, 0.5), (0, 1.0), (60, 20.0), (120, 40.0), (600, 40.0), (1200, 40.0), (1500, 15.0),
                                          (1700, 6.0), (1830, 0.0)]]
                            + [{"timestamp": t(1840), "depth": 0.0, "heart_rate": 77.9, "ascent_rate": 0.0}],
        }, {"7": "Main"}),
        ("a rebreather dive that starts with a switch to the bailout and has no setpoint values", {
            "activity_mesgs": activity(),
            "record_mesgs": [{"timestamp": t(60 * i), "depth": d} for i, d in enumerate([1.0, 12.0, 12.0, 1.0])],
            "dive_gas_mesgs": ccr_gases,
            "dive_settings_mesgs": [{"ccr_high_setpoint": 1.2}],
            "event_mesgs": [{"timestamp": t(60), "event": "dive_gas_switched", "data": 1},
                            {"timestamp": t(120), "event": "dive_gas_switched", "data": 0},
                            {"timestamp": t(120), "event": "dive_alert", "dive_alert": "setpoint_switch_auto_low"},
                            {"timestamp": t(180), "event": "dive_alert", "dive_alert": "setpoint_switch_manual_high"}]}, None),
    ]
    out = []
    cfg = config.get_config()
    for name, messages, mapping in cases:
        cfg._config = {"tanks": mapping} if mapping else {}
        out.append({"name": name, "messages": jsonable(messages), "tank_config": mapping, "dives": dump_dives(parse_messages(messages))})
    cfg._config = {}
    return out


def file_cases(folder):
    start = datetime(2026, 5, 2, 10, 0)
    oc = DiveProfilePlan(
        name="Synthetic test dive", dive_type="oc", gf_low=40, gf_high=85, sac_lpm=15, water_temp_c=28.0,
        computer="Garmin Descent Mk3i", start_time=start,
        gases=[PlannedGas(id="Air", gas_type="air", o2_percent=21.0, start_pressure_bar=200),
               PlannedGas(id="EAN50", gas_type="nitrox", o2_percent=50.0, start_pressure_bar=200)],
        waypoints=[PlannedWaypoint(runtime_sec=180, depth_m=38.0, gas_id="Air"),
                   PlannedWaypoint(runtime_sec=25 * 60, depth_m=38.0, gas_id="Air")])
    ascent, _, _ = plan_ascent(oc)
    oc.waypoints.extend(ascent)
    ccr = DiveProfilePlan(
        name="Synthetic CCR dive", dive_type="ccr", gf_low=40, gf_high=85, water_temp_c=24.0,
        computer="Garmin Descent X50i", start_time=start,
        gases=[PlannedGas(id="Dil", gas_type="trimix", o2_percent=18.0, he_percent=45.0, diluent=True, tank_ref="T1", tank_size_l=3.0),
               PlannedGas(id="EAN50", gas_type="nitrox", o2_percent=50.0, tank_ref="T2", tank_size_l=7.0)],
        waypoints=[PlannedWaypoint(runtime_sec=180, depth_m=40.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=1200, depth_m=40.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=1500, depth_m=15.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=1800, depth_m=6.0, gas_id="EAN50", gas_auto=False),
                   PlannedWaypoint(runtime_sec=2400, depth_m=6.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=2500, depth_m=1.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=2560, depth_m=0.0, gas_id="Dil", gas_auto=False)])
    out = []
    for name, plan in [("written by the app: open circuit with a deco gas", oc), ("written by the app: rebreather with a bailout", ccr)]:
        samples, _ = simulate(plan, resolution_sec=20)
        path = folder / "written.fit"
        write_fit(plan, samples, path)
        raw = path.read_bytes()
        messages, errors = Decoder(Stream.from_file(str(path))).read()
        assert not errors, errors
        with contextlib.redirect_stdout(sys.stderr):
            dives = GarminParser().parse(path)
            serials = GarminParser().get_unique_tank_serials(path)
        out.append({
            "name": name,
            "file_name": "written.fit",
            "bytes_base64": base64.b64encode(raw).decode("ascii"),
            "read_fields": READ_FIELDS,
            "messages": {
                list_name: [jsonable({k: m[k] for k in fields if k in m}) for m in messages.get(list_name, [])]
                for list_name, fields in READ_FIELDS.items()
            },
            "unique_tank_serials": sorted(serials),
            "dives": dump_dives(dives),
        })
    return out


if __name__ == "__main__":
    naive = lambda *a: datetime(*a)  # noqa: E731
    with tempfile.TemporaryDirectory() as tmp:
        out = {
            "messages": message_cases(),
            "files": file_cases(Path(tmp)),
            "timezone_from_pair": [
                {"local_minus_utc_seconds": seconds,
                 "expected": str(timezone_from_pair(naive(2026, 1, 1, 12) + timedelta(seconds=seconds), naive(2026, 1, 1, 12)))}
                for seconds in [0, 7200, 19820, -18000, -19800, 30, 90, 150, -30, -90, 29, 31, 45900, -43200, 50400]
            ],
            "setpoint_timeline": [
                {"switches": switches, "setpoints": setpoints,
                 "expected": [[when, bar] for when, bar in setpoint_timeline([(w, s) for w, s in switches], setpoints)]}
                for switches, setpoints in [
                    ([], {"low": 0.7, "high": 1.3}), ([[10, "high"]], {"low": 0.7, "high": 1.3}),
                    ([[10, "low"], [20, "high"]], {"low": 0.7, "high": 1.3}), ([[10, "high"]], {"low": None, "high": 1.3}),
                    ([[10, "high"], [20, "low"]], {"low": 0.7, "high": None}), ([[10, "low"]], {"low": None, "high": None}),
                ]
            ],
        }
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
