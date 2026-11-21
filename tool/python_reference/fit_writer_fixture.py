"""Parity fixture for the Dive Profile Builder's Garmin FIT log (spec §7):
parsers/fit_writer.py on garmin_fit_sdk's Encoder, the plan it embeds
(parsers/plan_embed.py: fit_plan_messages, read_log_origin on a .fit) and
a plan rebuilt from a FIT log (utils/dive_plan_import.py's _fit_parts).

The files are written into a temporary folder that is removed again and
kept in the fixture as base64: invented dives, no person's log, no real
device's serial number.

"Now" is fixed (2026-11-13 12:00:00) so that the files are the same every
time; the machine's UTC offset at each dive's start, which decides the
file's UTC times, is recorded with the case.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/fit_writer_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/plan/fit_cases.json.gz

With `--real <folder of .fit files> <output.json>` it instead writes what
plan_from_log and read_log_origin make of each real FIT log in the folder
(the owner's logs under test_data/, never in git) to the output file,
which belongs under test_data/python_reference/.

With `--dart` it prints the Dart source of the profile table
(lib/core/plan/fit_profile_subset.dart) instead of the fixture.
"""
import base64
import datetime as real_datetime
import json
import sys
import tempfile
from importlib.metadata import version
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import import_fixture as IMPORT  # noqa: E402
import plan_fixture as P  # noqa: E402
from garmin_fit_sdk import Encoder, Profile  # noqa: E402
from garmin_fit_sdk import fit as FIT  # noqa: E402

import parsers.fit_writer as fit_writer  # noqa: E402
import parsers.plan_embed as embed  # noqa: E402
import parsers.uddf_writer as uddf_writer  # noqa: E402
from utils import dive_plan_engine as E  # noqa: E402

NOW = real_datetime.datetime(2026, 11, 13, 12, 0, 0, 654321)
FIXTURES = Path(__file__).resolve().parents[2] / "test" / "fixtures" / "python_reference"


class FixedDatetime(real_datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW


uddf_writer.datetime = FixedDatetime

MK3I, X50I = "Garmin Descent Mk3i", "Garmin Descent X50i"
LONG_NAME = "Wreck & <Reef> åäö 沈船 " + " ".join(f"leg {i} of the long way round" for i in range(40))
CASES = [
    # name of a plan of plan_fixture, changes to it, start time argument, simulate resolution, add the planned ascent
    ("simple", {"computer": MK3I}, None, 10, False),
    ("simple", {"computer": X50I, "computer_serial": "3456789012", "start_time": "2026-05-02T10:06:59", "water_temp_c": 4.5,
                "gf_low": 35.9, "gf_high": 70.2}, None, 30, False),
    ("simple", {"computer": MK3I, "computer_serial": "AB12", "name": LONG_NAME, "water_temp_c": -1.5}, "2026-03-29T02:30:00", 60, False),
    ("deco_three_gases", {"computer": MK3I, "computer_serial": "", "start_time": "2026-01-15T08:00:00.250000"}, None, 20, True),
    ("deco_bottom_with_gases", {"computer": MK3I}, "2026-10-25T02:30:00", 15, True),
    ("trimix", {"computer": X50I, "computer_serial": "99999999999"}, "2025-07-01T23:59:30", 60, True),
    ("ccr", {"computer": MK3I}, "2026-03-29T09:30:00", 15, True),
    ("ccr_bailout", {"computer": MK3I}, "2026-10-25T14:00:00", 20, False),
    ("ccr_long", {"computer": X50I}, "1995-01-01T00:00:00", 30, True),
    ("sidemount", {"computer": X50I, "computer_serial": "3456789012"}, "2026-06-01T12:00:00", 30, True),
    ("sidemount_small_switch", {"computer": MK3I}, "2026-06-01T12:00:00", 45, True),
    ("pair_on_oc_dive", {"computer": MK3I}, "2026-06-01T12:00:00", 30, False),
    ("own_rates_and_sac", {"computer": MK3I}, "2026-06-01T12:00:00", 25, False),
    ("late_transit", {"computer": MK3I}, "2038-06-01T12:00:00", 7, False),
    ("shallow", {"computer": MK3I}, "2026-06-01T12:00:00", 1, False),
    ("legacy_keys", {"computer": MK3I}, None, 60, False),
]
REFUSED = [
    ("simple", {"computer": "Shearwater Perdix 2"}, 10),
    ("simple", {"computer": "Nobody"}, 10),
    ("simple", {"computer": MK3I}, None),  # no samples
]

USED_FIELDS = {}  # message name -> field names, in the order first written
USED_VALUES = {}  # profile type -> {name: number}
_write_mesg = Encoder.write_mesg


def _recording_write(self, mesg):
    profile = Profile["messages"][mesg["mesg_num"]]
    by_name = {f["name"]: f for f in profile["fields"].values()}
    seen = USED_FIELDS.setdefault(profile["name"], [])
    for name, value in mesg.items():
        if name in ("mesg_num", "developer_fields") or name not in by_name:
            continue
        if name not in seen:
            seen.append(name)
        if isinstance(value, str) and by_name[name]["type"] != "string":
            numbers = [int(k) for k, v in Profile["types"][by_name[name]["type"]].items() if v == value]
            USED_VALUES.setdefault(by_name[name]["type"], {})[value] = numbers[0]
    return _write_mesg(self, mesg)


Encoder.write_mesg = _recording_write


def _one(raw, default):
    return raw[0] if isinstance(raw, list) and raw else raw if raw is not None and raw != [] else default


def profile_subset():
    """The part of the SDK's profile the writer uses, as _MesgDefinition
    reads it: per message its number and per field the number, base type,
    type, scale and offset (the defaults when the field has components)."""
    messages = {}
    for num, profile in Profile["messages"].items():
        if profile["name"] not in USED_FIELDS:
            continue
        by_name = {f["name"]: f for f in profile["fields"].values()}
        fields = {}
        for name in USED_FIELDS[profile["name"]]:
            f = by_name[name]
            many = len(f["components"]) > 1
            fields[name] = {
                "num": f["num"], "base_type": FIT.FIELD_TYPE_TO_BASE_TYPE[f["base_type"]], "type": f["type"],
                "scale": FIT.FIELD_DEFAULT_SCALE if many else _one(f["scale"], FIT.FIELD_DEFAULT_SCALE),
                "offset": FIT.FIELD_DEFAULT_OFFSET if many else _one(f["offset"], FIT.FIELD_DEFAULT_OFFSET),
            }
        messages[profile["name"]] = {"num": num, "fields": fields}
    return {
        "sdk": version("garmin-fit-sdk"),
        "version": Profile["version"]["major"] * 1000 + Profile["version"]["minor"],
        "messages": dict(sorted(messages.items(), key=lambda kv: kv[1]["num"])),
        "values": {t: dict(sorted(v.items(), key=lambda kv: kv[1])) for t, v in sorted(USED_VALUES.items())},
        "base_types": {str(k): {"size": d["size"], "signed": d["signed"], "code": d["type_code"], "invalid": d["invalid"],
                                "endian_flag": d["endian_flag"]} for k, d in FIT.BASE_TYPE_DEFINITIONS.items()},
        "numeric_types": FIT.NUMERIC_FIELD_TYPES,
    }


def origin_of(path):
    origin = embed.read_log_origin(path)
    return {"created_by_uwmedia": origin.created_by_uwmedia, "plan": origin.plan.model_dump(mode="json") if origin.plan else None}


def case(name, changes, start, resolution, with_ascent, tmp, index):
    data = {**P.PLANS[name], **changes}
    plan = P.fresh(data)
    if with_ascent:
        waypoints, _, _ = E.plan_ascent(plan)
        plan.waypoints.extend(waypoints)
    samples, _ = E.simulate(plan, resolution_sec=resolution)
    start_time = real_datetime.datetime.fromisoformat(start) if start else None
    local_start = uddf_writer.log_start_time(plan, start_time)
    folder = tmp / f"case{index}"
    folder.mkdir()
    path = folder / f"Wreck_dive {index}.fit"
    fit_writer.write_fit(plan, samples, path, start_time)
    return {
        "plan_name": name, "changes": changes, "start": start, "resolution": resolution, "with_ascent": with_ascent,
        "plan": plan.model_dump(mode="json"), "local_start": local_start.isoformat(),
        "utc_offset_minutes": int(local_start.astimezone().utcoffset().total_seconds() // 60),
        "packed": "".join(embed._fit_chunks(plan)), "file_name": path.name,
        "fit_base64": base64.b64encode(path.read_bytes()).decode("ascii"),
        "origin": origin_of(path), **IMPORT.rebuilt(path),
    }


def refused(name, changes, resolution, tmp):
    plan = P.fresh({**P.PLANS[name], **changes})
    samples = E.simulate(plan, resolution_sec=resolution)[0] if resolution else []
    try:
        fit_writer.write_fit(plan, samples, tmp / "refused.fit", None)
        return {"plan": plan.model_dump(mode="json"), "resolution": resolution, "raises": None}
    except ValueError as e:
        return {"plan": plan.model_dump(mode="json"), "resolution": resolution, "raises": str(e)}


def other_fit_cases(tmp):
    """read_log_origin and plan_from_log on FIT files the builder did not
    write: the synthetic files of the Garmin parser fixture, and junk."""
    out = []
    garmin = json.loads((FIXTURES / "dives" / "garmin.json").read_text())
    for i, f in enumerate(garmin["files"]):
        folder = tmp / f"other{i}"
        folder.mkdir()
        path = folder / f["file_name"]
        path.write_bytes(base64.b64decode(f["bytes_base64"]))
        out.append({"source": "dives/garmin.json", "index": i, "name": f["name"], "file_name": path.name, "origin": origin_of(path),
                    **IMPORT.rebuilt(path)})
    junk = tmp / "junk.fit"
    junk.write_bytes(b"not a fit file")
    out.append({"source": "junk", "bytes_base64": base64.b64encode(junk.read_bytes()).decode("ascii"), "file_name": junk.name,
                "origin": origin_of(junk)})
    return out


def real(folder, output):
    out = {}
    for path in sorted(Path(folder).glob("*.fit")):
        out[path.name] = {"origin": origin_of(path), **IMPORT.rebuilt(path)}
    Path(output).write_text(json.dumps({"bases": IMPORT.BASES, "logs": out}, separators=(",", ":"), allow_nan=False))
    print(len(out), "logs", file=sys.stderr)


def dart_source(profile):
    """lib/core/plan/fit_profile_subset.dart."""
    lines = [
        "// Generated by tool/python_reference/fit_writer_fixture.py --dart from the",
        f"// profile of garmin_fit_sdk {profile['sdk']}: the messages, fields and named",
        "// values the Dive Profile Builder's FIT log uses. Do not edit by hand.",
        "",
        "/// One field of a FIT message: its number, base type, type, scale and",
        "/// offset.",
        "typedef FitFieldProfile = ({",
        "  int num,",
        "  int baseType,",
        "  String type,",
        "  num scale,",
        "  num offset,",
        "});",
        "",
        "/// The profile version in a written file's header (major * 1000 + minor).",
        f"const int fitProfileVersion = {profile['version']};",
        "",
        "/// Message numbers by name.",
        "const Map<String, int> fitMesgNums = {",
    ]
    for name, m in profile["messages"].items():
        lines.append(f"  '{name}': {m['num']},")
    lines += ["};", "", "/// The fields by message number and field name.", "const Map<int, Map<String, FitFieldProfile>> fitMesgFields = {"]
    for name, m in profile["messages"].items():
        lines.append(f"  // {name}")
        lines.append(f"  {m['num']}: {{")
        for field, f in m["fields"].items():
            lines.append(f"    '{field}': (")
            lines.append(f"      num: {f['num']},")
            lines.append(f"      baseType: {f['base_type']},")
            lines.append(f"      type: '{f['type']}',")
            lines.append(f"      scale: {f['scale']},")
            lines.append(f"      offset: {f['offset']},")
            lines.append("    ),")
        lines.append("  },")
    lines += ["};", "", "/// The numbers of the named values, by profile type.", "const Map<String, Map<String, int>> fitTypeValues = {"]
    for type_name, values in profile["values"].items():
        lines.append(f"  '{type_name}': {{")
        for value, number in values.items():
            lines.append(f"    '{value}': {number},")
        lines.append("  },")
    lines.append("};")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--real":
        real(sys.argv[2], sys.argv[3])
        sys.exit(0)
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        cases = [case(*c, tmp, i) for i, c in enumerate(CASES)]
        out = {
            "now": NOW.isoformat(),
            "constants": {"tank_sensor_base": fit_writer.TANK_SENSOR_BASE, "plan_software_version": fit_writer.PLAN_SOFTWARE_VERSION,
                          "application_id": list(embed.FIT_APPLICATION_ID.bytes), "field_prefix": embed.FIT_PLAN_FIELD_PREFIX,
                          "chunk_bytes": embed.FIT_CHUNK_BYTES, "dive_alert": fit_writer.DIVE_ALERT},
            "bases": IMPORT.BASES,
            "cases": cases,
            "refused": [refused(*r, tmp) for r in REFUSED],
            "others": other_fit_cases(tmp),
        }
        out["profile"] = profile_subset()
    if len(sys.argv) > 1 and sys.argv[1] == "--dart":
        sys.stdout.write(dart_source(out["profile"]))
        sys.exit(0)
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
    print(len(cases), "files", file=sys.stderr)
