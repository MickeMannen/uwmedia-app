"""Parity fixture for the Log Viewer's two FIT tools (spec §7):
parsers/fit_time.py ("Adjust time": every timestamp of a Garmin FIT log
shifted, the time zone set) and parsers/fit_merge.py ("Merge dives": two
logs of one dive joined), which both rewrite a file record by record, and
the small helpers of uwmedia/backends/log_viewer_backend.py around them.

The source files are invented: dives written by the app's own FIT writer
and a few files built by hand here (compressed timestamps, big-endian
messages, developer fields, messages no profile knows). They are kept in
the fixture as base64; each result is kept as its length and SHA-256.
`--full <folder>` writes the results as files into a folder (the session's
scratch folder), for looking at a difference.

With `--real <folder of .fit files> <output.json>` it instead adjusts
each real FIT log in the folder and merges each with the next one by name
(the owner's logs under test_data/, never in git), and writes the lengths
and SHA-256s of the results to the output file, which belongs under
test_data/python_reference/.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/fit_edit_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/dives/fit_edit_cases.json.gz
"""
import base64
import contextlib
import datetime as real_datetime
import hashlib
import io
import json
import struct
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import plan_fixture as P  # noqa: E402

import parsers.fit_merge as M  # noqa: E402
import parsers.fit_time as T  # noqa: E402
import parsers.fit_writer as fit_writer  # noqa: E402
import parsers.uddf_writer as uddf_writer  # noqa: E402
from models.dive_plan import DiveProfilePlan  # noqa: E402
from parsers.garmin import GarminParser  # noqa: E402
from utils import dive_plan_engine as E  # noqa: E402

NOW = real_datetime.datetime(2026, 11, 13, 12, 0, 0)


class FixedDatetime(real_datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW


uddf_writer.datetime = FixedDatetime

MK3I = "Garmin Descent Mk3i"
AIR = {"id": "Air", "gas_type": "air", "o2_percent": 21.0, "start_pressure_bar": 200}
NX32 = {"id": "Nx32", "gas_type": "nitrox", "o2_percent": 32.0, "start_pressure_bar": 200}


def written(start, gases=(AIR,), bottom_min=6, resolution=10, plan_name=None, **changes):
    """A dive by the app's FIT writer, as bytes."""
    if plan_name:
        data = {**P.PLANS[plan_name], "computer": MK3I, "start_time": start, **changes}
        plan = P.fresh(data)
    else:
        first = gases[0]["id"]
        plan = DiveProfilePlan.model_validate({
            "name": "Synthetic test dive", "gf_low": 40, "gf_high": 85, "sac_lpm": 15, "water_temp_c": 28.0, "computer": MK3I,
            "start_time": start, "gases": list(gases), **changes,
            "waypoints": [{"runtime_sec": 120, "depth_m": 18.0, "gas_id": first}, {"runtime_sec": bottom_min * 60, "depth_m": 18.0, "gas_id": first}]})
    waypoints, _, _ = E.plan_ascent(plan)
    plan.waypoints.extend(waypoints)
    samples, _ = E.simulate(plan, resolution_sec=resolution)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "dive.fit"
        fit_writer.write_fit(plan, samples, path)
        return path.read_bytes()


# --- files built by hand -----------------------------------------------------------

def definition(local, mesg_num, fields, big=False, dev=()):
    endian = ">" if big else "<"
    out = bytes([0x40 | (0x20 if dev else 0) | local, 0, 1 if big else 0]) + struct.pack(endian + "H", mesg_num)
    out += bytes([len(fields)])
    for num, size, base in fields:
        out += bytes([num, size, base])
    if dev:
        out += bytes([len(dev)])
        for num, size, index in dev:
            out += bytes([num, size, index])
    return out


def data(local, fmt, *values):
    return bytes([local]) + struct.pack(fmt, *values)


def compressed(local, timestamp, fmt, *values):
    return bytes([0x80 | (local << 5) | (timestamp & 0x1F)]) + struct.pack(fmt, *values)


def fit(records, header14=False, protocol=0x10):
    header = struct.pack("<BBHI4s", 14 if header14 else 12, protocol, 2100, len(records), b".FIT")
    if header14:
        header += struct.pack("<H", T.fit_crc(header))
    body = header + records
    return body + struct.pack("<H", T.fit_crc(body))


T0 = 1_100_000_000  # seconds since the FIT epoch
U32, U16, U8, ENUM, U32Z, S32 = 0x86, 0x84, 0x02, 0x00, 0x8C, 0x85


def hand_time():
    """The file of tests/test_fit_time.py: compressed timestamps and a
    big-endian activity."""
    return fit(
        definition(0, 20, [(253, 4, U32), (3, 1, U8)])
        + definition(1, 20, [(3, 1, U8)])
        + definition(2, 34, [(253, 4, U32), (5, 4, U32)], big=True)
        + data(0, "<IB", T0, 60)
        + compressed(1, T0 + 5, "<B", 61)
        + compressed(1, T0 + 9, "<B", 62)
        + data(2, ">II", T0, T0 + 3600), protocol=0x20)


def hand_odd_times():
    """Timestamps a shift leaves alone (not set, seconds since power-on),
    date_time fields of other messages, an activity without a local time."""
    return fit(
        definition(0, 0, [(3, 4, U32Z), (4, 4, U32)])  # file_id: serial, time_created
        + definition(1, 18, [(253, 4, U32), (2, 4, U32), (7, 4, U32)])  # session: timestamp, start_time, elapsed
        + definition(2, 19, [(2, 4, U32), (253, 4, U32)])  # lap
        + definition(3, 20, [(253, 4, U32), (92, 4, U32)])  # record
        + definition(4, 34, [(253, 4, U32)])  # activity without local_timestamp
        + definition(5, 20, [(253, 2, U16), (92, 4, U32)])  # a timestamp of the wrong size
        + definition(6, 21, [(253, 4, S32), (3, 4, U32)])  # ... and of the wrong type
        + data(0, "<II", 12345, T0)
        + data(3, "<II", 0xFFFFFFFF, 1000)
        + data(3, "<II", 500, 1500)
        + data(3, "<II", T0 + 1, 2000)
        + data(5, "<HI", 77, 2500)
        + data(6, "<iI", T0, 3)
        + data(1, "<III", T0 + 2, T0, 2000)
        + data(2, "<II", T0, T0 + 2)
        + data(4, "<I", T0 + 2))


def hand_first():
    f = M
    return fit(
        definition(0, f.RECORD, [(253, 4, U32), (f.F_DEPTH, 4, U32)])
        + definition(1, f.RECORD, [(f.F_DEPTH, 4, U32)])  # with compressed timestamps
        + definition(2, f.FILE_ID, [(3, 4, U32Z), (4, 4, U32)])
        + definition(3, f.DEVICE_INFO, [(253, 4, U32), (f.F_SERIAL, 4, U32Z)])
        + definition(4, f.DIVE_GAS, [(254, 2, U16), (f.F_GAS_HE, 1, U8), (f.F_GAS_O2, 1, U8), (f.F_GAS_MODE, 1, ENUM)])
        + definition(5, f.EVENT, [(253, 4, U32), (f.F_EVENT, 1, ENUM), (f.F_EVENT_TYPE, 1, ENUM), (f.F_EVENT_DATA, 4, U32)])
        + definition(6, 0xFF00, [(253, 4, U32), (1, 2, U16)])  # a message no profile knows
        + definition(7, f.GPS_METADATA, [(253, 4, U32), (f.F_GPS_UTC, 4, U32)])
        + definition(8, f.TANK_SUMMARY, [(253, 4, U32), (f.F_SENSOR, 4, U32Z), (f.F_END_PRESSURE, 2, U16), (f.F_VOLUME_USED, 4, U32)])
        + definition(9, f.DIVE_SUMMARY, [(253, 4, U32), (f.F_AVG_DEPTH, 4, U32), (f.F_MAX_DEPTH, 4, U32), (f.F_BOTTOM_TIME, 4, U32),
                                         (f.F_END_CNS, 1, U8), (f.F_END_N2, 2, U16), (f.F_O2_TOX, 2, U16)])
        + definition(10, f.SESSION, [(253, 4, U32), (f.F_START_TIME, 4, U32), (f.F_ELAPSED, 4, U32), (f.F_TIMER, 4, U32),
                                     (f.F_END_LAT, 4, S32), (f.F_END_LONG, 4, S32)])
        + definition(11, f.LAP, [(253, 4, U32), (f.F_START_TIME, 4, U32), (f.F_ELAPSED, 4, U32), (f.F_TIMER, 4, U32)])
        + definition(12, f.ACTIVITY, [(253, 4, U32), (f.F_ACTIVITY_TIMER, 4, U32), (5, 4, U32)])
        + data(2, "<II", 4242, T0)
        + data(3, "<II", T0, 111)
        + data(4, "<HBBB", 0, 0, 21, 0)
        + data(4, "<HBBB", 1, 0, 50, 0)
        + data(6, "<IH", T0, 7)
        + data(5, "<IBBI", T0, f.EVENT_TIMER, f.EVENT_TYPE_START, 0)
        + data(0, "<II", T0, 1000)
        + data(0, "<II", T0 + 10, 12000)
        + compressed(1, T0 + 20, "<I", 15500)
        + data(6, "<IH", T0 + 20, 8)
        + data(5, "<IBBI", T0 + 20, f.EVENT_GAS_SWITCHED, f.EVENT_TYPE_MARKER, 1)
        + data(7, "<II", T0 + 25, T0 + 25)
        + data(0, "<II", T0 + 30, 9000)
        + compressed(1, T0 + 40, "<I", 3000)
        + data(5, "<IBBI", T0 + 40, f.EVENT_TIMER, 4, 0)  # stop_all at the last sample: dropped
        + data(8, "<IIHI", T0 + 40, 111, 15000, 40000)
        + data(8, "<IIHI", T0 + 40, 333, 18000, 1000)
        + data(9, "<IIIIBHH", T0 + 40, 8000, 15500, 40000, 5, 80, 10)
        + data(11, "<IIII", T0 + 40, T0, 40000, 40000)
        + data(10, "<IIIIii", T0 + 40, T0, 40000, 40000, 100, -200)
        + data(12, "<III", T0 + 40, 40000, T0 + 40 + 7200))


def hand_second(start, gases=((50, 0), (32, 0)), header14=True, switch_at_start=True):
    """The continuation of hand_first: a 14-byte header, developer fields,
    big-endian tank updates, its own gases, pods and summaries."""
    f = M
    t = start
    out = (
        definition(0, f.RECORD, [(253, 4, U32), (f.F_DEPTH, 4, U32)], dev=[(0, 2, 0)])
        + definition(1, f.RECORD, [(f.F_DEPTH, 4, U32)])
        + definition(2, f.FILE_ID, [(3, 4, U32Z), (4, 4, U32)])
        + definition(3, f.DEVICE_INFO, [(253, 4, U32), (f.F_SERIAL, 4, U32Z)])
        + definition(4, f.DIVE_GAS, [(254, 2, U16), (f.F_GAS_HE, 1, U8), (f.F_GAS_O2, 1, U8), (f.F_GAS_MODE, 1, ENUM)])
        + definition(5, f.EVENT, [(253, 4, U32), (f.F_EVENT, 1, ENUM), (f.F_EVENT_TYPE, 1, ENUM), (f.F_EVENT_DATA, 4, U32)])
        + definition(6, 0xFF00, [(253, 4, U32), (1, 2, U16)])
        + definition(7, f.GPS_METADATA, [(253, 4, U32), (f.F_GPS_UTC, 4, U32)])
        + definition(8, f.TANK_SUMMARY, [(253, 4, U32), (f.F_SENSOR, 4, U32Z), (f.F_END_PRESSURE, 2, U16), (f.F_VOLUME_USED, 4, U32)])
        + definition(9, f.DIVE_SUMMARY, [(253, 4, U32), (f.F_AVG_DEPTH, 4, U32), (f.F_MAX_DEPTH, 4, U32), (f.F_BOTTOM_TIME, 4, U32),
                                         (f.F_END_CNS, 1, U8), (f.F_END_N2, 2, U16), (f.F_O2_TOX, 2, U16)])
        + definition(10, f.SESSION, [(253, 4, U32), (f.F_START_TIME, 4, U32), (f.F_ELAPSED, 4, U32), (f.F_TIMER, 4, U32),
                                     (f.F_END_LAT, 4, S32), (f.F_END_LONG, 4, S32)])
        + definition(11, f.TANK_UPDATE, [(253, 4, U32), (0, 4, U32Z), (1, 2, U16)], big=True)
        + definition(12, f.DEVELOPER_DATA_ID, [(3, 1, U8), (4, 4, U32)])
        + definition(13, f.FIELD_DESCRIPTION, [(0, 1, U8), (1, 1, U8), (2, 1, U8)])
        + definition(14, M._mesg("dive_settings"), [(253, 4, U32), (2, 1, U8)])
        + data(2, "<II", 4242, t)
        + data(12, "<BI", 0, 9)
        + data(13, "<BBB", 0, 0, 0x84)
        + data(14, "<IB", t, 30)
        + data(3, "<II", t, 111)
        + data(3, "<II", t, 222)
        + data(3, "<II", t, 0)  # a device without a serial
    )
    for i, (o2, he) in enumerate(gases):
        out += data(4, "<HBBB", i, he, o2, 0)
    out += data(4, "<HBBB", 0xFFFF, 0, 80, 0)  # a gas without an index
    out += data(6, "<IH", t, 1)  # before the first sample: left behind
    out += data(5, "<IBBI", t, f.EVENT_TIMER, f.EVENT_TYPE_START, 0)
    if switch_at_start:
        out += data(5, "<IBBI", t, f.EVENT_GAS_SWITCHED, f.EVENT_TYPE_MARKER, 0)
    out += (
        data(0, "<IIH", t, 2000, 501)
        + data(11, ">IIH", t, 111, 14000)
        + compressed(1, t + 10, "<I", 21000)
        + data(6, "<IH", t + 10, 2)  # between the samples: comes along
        + data(5, "<IBBI", t + 10, f.EVENT_GAS_SWITCHED, f.EVENT_TYPE_MARKER, 1)
        + data(5, "<IBBI", t + 12, f.EVENT_GAS_SWITCHED, f.EVENT_TYPE_MARKER, 7)  # a gas the file does not list
        + data(7, "<II", t + 15, t + 15)
        + data(7, "<II", t + 16, 500)
        + data(0, "<IIH", t + 20, 16000, 502)
        + compressed(1, t + 45, "<I", 4000)  # 25 s on: the 5-bit time wraps
        + data(0, "<IIH", t + 50, 0xFFFFFFFF, 503)  # a sample without a depth
        + data(5, "<IBBI", t + 50, f.EVENT_TIMER, 4, 0)
        + data(6, "<IH", t + 50, 3)  # after the last sample: left behind
        + data(8, "<IIHI", t + 50, 111, 9000, 25000)
        + data(8, "<IIHI", t + 50, 222, 17000, 3000)
        + data(9, "<IIIIBHH", t + 50, 9000, 21000, 50000, 9, 95, 14)
        + data(10, "<IIIIii", t + 50, t, 50500, 50500, 300, 0x7FFFFFFF)
    )
    return fit(out, header14=header14, protocol=0x10)


def hand_no_gases(start):
    """A first file that lists no gas and whose samples are all compressed."""
    f = M
    return fit(
        definition(0, f.RECORD, [(253, 4, U32), (f.F_DEPTH, 4, U32)])
        + definition(1, f.RECORD, [(f.F_DEPTH, 4, U32)])
        + definition(2, f.EVENT, [(253, 4, U32), (f.F_EVENT, 1, ENUM), (f.F_EVENT_TYPE, 1, ENUM), (f.F_EVENT_DATA, 4, U32)])
        + data(2, "<IBBI", start, f.EVENT_TIMER, f.EVENT_TYPE_START, 0)
        + data(0, "<II", start, 1000)
        + compressed(1, start + 4, "<I", 5000)
        + compressed(1, start + 8, "<I", 5000)
        + compressed(1, start + 13, "<I", 2000))


def only_compressed(start):
    """Samples that never carry a full timestamp: nothing to fill a gap with."""
    f = M
    return fit(
        definition(0, f.EVENT, [(253, 4, U32), (f.F_EVENT, 1, ENUM), (f.F_EVENT_TYPE, 1, ENUM), (f.F_EVENT_DATA, 4, U32)])
        + definition(1, f.RECORD, [(f.F_DEPTH, 4, U32)])
        + data(0, "<IBBI", start, f.EVENT_TIMER, f.EVENT_TYPE_START, 0)
        + compressed(1, start + 1, "<I", 5000)
        + compressed(1, start + 3, "<I", 5000))


def sources():
    a = written("2026-01-01T10:00:00")
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "a.fit"
        path.write_bytes(a)
        with contextlib.redirect_stdout(io.StringIO()):
            end = GarminParser().parse(path)[0].end_time.replace(microsecond=0)
    out = {
        "air": a,
        "nitrox_30_min_later": written((end + timedelta(minutes=30)).isoformat(), gases=(NX32,)),
        "air_5_min_later": written((end + timedelta(minutes=5)).isoformat(), bottom_min=4, resolution=7),
        "deco_20_min_later": written((end + timedelta(minutes=20)).isoformat(), plan_name="deco_three_gases", resolution=30),
        "ccr_1_h_later": written((end + timedelta(minutes=60)).isoformat(), plan_name="ccr", resolution=30),
        "air_3_h_later": written((end + timedelta(hours=3)).isoformat()),
        "hand_time": hand_time(),
        "hand_odd_times": hand_odd_times(),
        "hand_first": hand_first(),
        "hand_second": hand_second(T0 + 100),
        "hand_second_other_gases": hand_second(T0 + 47, gases=((21, 0), (18, 45), (50, 0)), header14=False, switch_at_start=False),
        "hand_no_gases": hand_no_gases(T0 - 600),
        "only_compressed": only_compressed(T0 - 30),
        "two_files": hand_time() + hand_odd_times(),
        "cut_short": hand_first()[:-40],
        "trailing_bytes": hand_time() + b"abc",
        "not_fit": b"not a fit file at all",
        "empty": b"",
        "no_activity": hand_no_gases(T0),
    }
    return out


ADJUST = [
    # source, local start, UTC offset in minutes
    ("air", "2026-03-05T14:23:07", 420),
    ("air", "2026-01-01T10:00:00", -330),
    ("air", "2026-03-05T14:23:07.900000", 0),
    ("deco_20_min_later", "2019-12-31T23:59:59", 840),
    ("ccr_1_h_later", "2031-07-01T00:00:00", -720),
    ("hand_time", (datetime(1989, 12, 31) + timedelta(seconds=T0 + 1234 + 7200)).isoformat(), 120),
    ("hand_time", (datetime(1989, 12, 31) + timedelta(seconds=T0 - 77)).isoformat(), 0),
    ("hand_odd_times", "2026-03-05T14:23:07", 60),
    ("two_files", "2026-03-05T14:23:07", 60),
    ("hand_first", "2026-03-05T14:23:07", 0),
    ("hand_second", "2020-02-29T12:00:00", -60),
    ("air", "1990-01-01T00:00:00", 0),  # out of the file's range
    ("air", "2130-01-01T00:00:00", 0),
    ("hand_no_gases", "2026-03-05T14:23:07", 0),  # no activity
    ("cut_short", "2026-03-05T14:23:07", 0),
    ("trailing_bytes", "2026-03-05T14:23:07", 0),
    ("not_fit", "2026-01-01T00:00:00", 0),
    ("empty", "2026-01-01T00:00:00", 0),
]
MERGE = [
    ("air", "nitrox_30_min_later"), ("air", "air_5_min_later"), ("air", "deco_20_min_later"), ("air", "ccr_1_h_later"),
    ("nitrox_30_min_later", "ccr_1_h_later"), ("deco_20_min_later", "ccr_1_h_later"), ("air_5_min_later", "deco_20_min_later"),
    ("hand_first", "hand_second"), ("hand_first", "hand_second_other_gases"), ("hand_no_gases", "hand_first"),
    ("hand_no_gases", "hand_second"), ("only_compressed", "hand_first"), ("hand_second", "hand_first"),
    ("nitrox_30_min_later", "air"), ("air", "air"), ("air", "air_3_h_later"), ("air", "not_fit"), ("not_fit", "air"),
    ("hand_time", "air"), ("air", "hand_time"), ("air", "cut_short"), ("hand_first", "two_files"),
]


def digest(data):
    return {"length": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def activity_time(path):
    try:
        utc, offset = T.fit_activity_time(path)
        return [utc.replace(tzinfo=None).isoformat(), offset]
    except Exception as e:  # noqa: BLE001
        return ["raise", type(e).__name__, str(e)]


def run(tmp, files, full):
    paths = {}
    for name, content in files.items():
        folder = tmp / name
        folder.mkdir()
        paths[name] = folder / f"Dive {name}.fit"
        paths[name].write_bytes(content)
    adjust = []
    for i, (name, start, offset) in enumerate(ADJUST):
        dest = tmp / f"adjusted{i}.fit"
        case = {"source": name, "local_start": start, "utc_offset_minutes": offset, "activity_time": activity_time(paths[name])}
        try:
            case["delta"] = T.adjust_fit_time(paths[name], dest, datetime.fromisoformat(start), offset)
            case["result"] = digest(dest.read_bytes())
            case["result_activity_time"] = activity_time(dest)
            if full:
                (full / f"adjusted{i}_{name}.fit").write_bytes(dest.read_bytes())
        except Exception as e:  # noqa: BLE001
            case["raises"] = [type(e).__name__, str(e)]
        adjust.append(case)
    merge = []
    for i, (first, second) in enumerate(MERGE):
        for close_gap in (False, True):
            dest = tmp / f"merged{i}{close_gap}.fit"
            case = {"first": first, "second": second, "first_name": paths[first].name, "second_name": paths[second].name,
                    "close_gap": close_gap}
            try:
                r = M.merge_fit_dives(paths[first], paths[second], dest, close_gap)
                case["result"] = digest(dest.read_bytes())
                case["merge"] = {"gap_seconds": r.gap_seconds, "shift_seconds": r.shift_seconds, "filled_samples": r.filled_samples,
                                 "gases_added": r.gases_added}
                if full:
                    (full / f"merged{i}_{first}_{second}_{close_gap}.fit").write_bytes(dest.read_bytes())
            except Exception as e:  # noqa: BLE001
                case["raises"] = [type(e).__name__, str(e)]
            merge.append(case)
    return adjust, merge


def viewer_helpers(tmp, files):
    import uwmedia.backends.log_viewer_backend as V

    def attempt(fn, *args):
        try:
            return ["ok", fn(*args)]
        except ValueError:
            return ["raise"]

    starts = ["2026-03-05  14:23", "2026-03-05 14:23:07", " 2026-03-05\t14:23 ", "5 March", "2026-03-05", "2026-3-5 4:03", "2026-03-05 14:23:07.5",
              "2026-02-30 10:00", "2026-03-05T14:23", ""]
    offsets = ["+07:00", "-5:30", "+7", "UTC+08:00", "gmt-3", "0", "+0545", "", "seven", "+15:00", "-13", "+07:75", "+1:2:3", "+14:00", "-12:00",
               "-12:01", " utc +3 ", "UTC", "12", "+123", "1234", "-0030", "+7:5", "١"]
    out = {
        "parse_local_start": [[t, (lambda r: ["ok", r[1].isoformat()] if r[0] == "ok" else r)(attempt(V.parse_local_start, t))] for t in starts],
        "parse_utc_offset": [[t, attempt(V.parse_utc_offset, t)] for t in offsets],
        "format_utc_offset": [[m, V.format_utc_offset(m)] for m in (-330, 0, 420, 345, -1, 59, 840, -720, 600)],
        "names": [[p, str(V.adjusted_name(Path(p))), str(V.merged_name(Path(p)))]
                  for p in ("logs/Dive 12.fit", "/x/Dive 12.fit", "Dive.FIT", "a.b.fit", "noext", "/x/.hidden")],
        "max_gap_seconds": M.MAX_GAP_SECONDS,
    }
    # merge_candidates and candidate_label on the written dives.
    names = ["air", "nitrox_30_min_later", "air_5_min_later", "deco_20_min_later", "ccr_1_h_later", "air_3_h_later"]
    dives = []
    for name in names:
        path = tmp / name / f"Dive {name}.fit"
        with contextlib.redirect_stdout(io.StringIO()):
            dive = GarminParser().parse(path)[0]
        dive.log_path, dive.log_filename, dive.log_format = str(path), path.name, "fit"
        dives.append(dive)
    out["candidates"] = [{"dive": names[i], "candidates": [names[dives.index(c)] for c in V.merge_candidates(dives, d)],
                          "labels": [V.candidate_label(d, c) for c in V.merge_candidates(dives, d)]} for i, d in enumerate(dives)]
    return out


def constants():
    names = [n for n in dir(M) if n.isupper() and isinstance(getattr(M, n), (int, set))]
    out = {}
    for n in names:
        v = getattr(M, n)
        out[n] = sorted(list(x) if isinstance(x, tuple) else x for x in v) if isinstance(v, set) else v
    out["TIME_DATE_TIME_FIELDS"] = sorted(list(x) for x in T.DATE_TIME_FIELDS)
    out["ACTIVITY_LOCAL_TIMESTAMP"] = T.ACTIVITY_LOCAL_TIMESTAMP
    return out


def real(folder, output):
    paths = sorted(Path(folder).glob("*.fit"))
    out = {"adjust": {}, "merge": []}
    with tempfile.TemporaryDirectory() as tmp_name:
        dest = Path(tmp_name) / "out.fit"
        for path in paths:
            case = {"local_start": "2026-03-05T14:23:07", "utc_offset_minutes": -210, "activity_time": activity_time(path)}
            try:
                case["delta"] = T.adjust_fit_time(path, dest, datetime(2026, 3, 5, 14, 23, 7), -210)
                case["result"] = digest(dest.read_bytes())
            except Exception as e:  # noqa: BLE001
                case["raises"] = [type(e).__name__, str(e)]
            out["adjust"][path.name] = case
        for first, second in zip(paths, paths[1:]):
            for close_gap in (False, True):
                case = {"first": first.name, "second": second.name, "close_gap": close_gap}
                try:
                    r = M.merge_fit_dives(first, second, dest, close_gap)
                    case["result"] = digest(dest.read_bytes())
                    case["merge"] = {"gap_seconds": r.gap_seconds, "shift_seconds": r.shift_seconds,
                                     "filled_samples": r.filled_samples, "gases_added": r.gases_added}
                except Exception as e:  # noqa: BLE001
                    case["raises"] = [type(e).__name__, str(e)]
                out["merge"].append(case)
    Path(output).write_text(json.dumps(out, separators=(",", ":"), allow_nan=False))
    print(len(out["adjust"]), "adjusted,", sum(1 for m in out["merge"] if "result" in m), "merged", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) > 3 and sys.argv[1] == "--real":
        real(sys.argv[2], sys.argv[3])
        sys.exit(0)
    full = None
    if len(sys.argv) > 2 and sys.argv[1] == "--full":
        full = Path(sys.argv[2])
        full.mkdir(parents=True, exist_ok=True)
    files = sources()
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        adjust, merge = run(tmp, files, full)
        helpers = viewer_helpers(tmp, files)
    out = {
        "constants": constants(),
        "sources": {name: base64.b64encode(content).decode("ascii") for name, content in files.items()},
        "adjust": adjust, "merge": merge, "viewer": helpers,
    }
    if full is None:
        json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
        sys.stdout.write("\n")
    print(len(adjust), "adjusted,", len(merge), "merged", file=sys.stderr)
