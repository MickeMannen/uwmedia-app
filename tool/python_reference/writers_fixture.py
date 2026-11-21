"""Parity fixture for the Dive Profile Builder's log writers and the plan
it embeds in them (spec §7): parsers/uddf_writer.py,
parsers/subsurface_writer.py and parsers/plan_embed.py (the text formats;
FIT is not here). The files are written into a temporary folder that is
removed again and kept in the fixture as text: invented dives, no
person's log.

"Now" is fixed (2026-11-13 12:00:00) so that the files are the same every
time; the machine's UTC offset at each dive's start, which the UDDF writer
puts into the file, is recorded with the case.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/writers_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/plan/writers_cases.json.gz
"""
import datetime as real_datetime
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import plan_fixture as P  # noqa: E402

import parsers.plan_embed as embed  # noqa: E402
import parsers.subsurface_writer as subsurface_writer  # noqa: E402
import parsers.uddf_writer as uddf_writer  # noqa: E402
from utils import dive_plan_engine as E  # noqa: E402

NOW = real_datetime.datetime(2026, 11, 13, 12, 0, 0, 654321)


class FixedDatetime(real_datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW


uddf_writer.datetime = FixedDatetime

ODD_NAME = 'Wreck & <Reef> "A" åäö it\'s'
CASES = [
    # name of a plan of plan_fixture, changes to it, start time argument, simulate resolution, add the planned ascent
    ("simple", {}, None, 10, False),
    ("simple", {"name": ODD_NAME, "start_time": "2026-05-02T10:06:59", "computer": "Garmin Descent Mk3i", "computer_serial": ""}, None, 30, False),
    ("deco_bottom_with_gases", {"start_time": "2026-01-15T08:00:00.250000", "water_temp_c": 4.5, "gf_low": 35.5}, None, 20, True),
    ("trimix", {"computer": "Shearwater Petrel"}, "2025-07-01T23:59:30", 60, True),
    ("ccr", {"computer": "Shearwater Petrel 3"}, "2026-03-29T09:30:00", 15, True),
    ("ccr_bailout", {}, "2026-10-25T14:00:00", 20, False),
    ("sidemount", {"computer": "Garmin Descent X50i", "computer_serial": "3456789012"}, "2026-06-01T12:00:00", 30, True),
    ("sidemount_small_switch", {}, "2026-06-01T12:00:00", 45, True),
    ("own_rates_and_sac", {"computer": "Nobody"}, "2026-06-01T12:00:00", 25, False),
    ("legacy_keys", {}, None, 60, False),
]


def case(name, changes, start, resolution, with_ascent, tmp):
    data = {**P.PLANS[name], **changes}
    plan = P.fresh(data)
    if with_ascent:
        waypoints, _, _ = E.plan_ascent(plan)
        plan.waypoints.extend(waypoints)
    samples, _ = E.simulate(plan, resolution_sec=resolution)
    start_time = real_datetime.datetime.fromisoformat(start) if start else None
    local_start = uddf_writer.log_start_time(plan, start_time)
    uddf, ssrf = tmp / "dive.uddf", tmp / "dive.ssrf"
    uddf_writer.write_uddf(plan, samples, uddf, start_time)
    subsurface_writer.write_subsurface(plan, samples, ssrf, start_time if start_time else (None if plan.start_time else NOW))
    origins = {}
    for path in (uddf, ssrf):
        origin = embed.read_log_origin(path)
        origins[path.suffix] = {"created_by_uwmedia": origin.created_by_uwmedia,
                                "plan": origin.plan.model_dump(mode="json") if origin.plan else None}
    return {
        "plan_name": name, "changes": changes, "start": start, "resolution": resolution, "with_ascent": with_ascent,
        "plan": plan.model_dump(mode="json"), "plan_json": embed.plan_to_json(plan),
        "local_start": local_start.isoformat(), "utc_offset_minutes": uddf_writer.utc_offset_minutes(local_start),
        "uddf": uddf.read_text(encoding="utf-8"), "subsurface": ssrf.read_text(encoding="utf-8"), "origins": origins,
    }


def origin_cases(tmp):
    """read_log_origin on files that are not the builder's, or only partly."""
    texts = {
        "other.uddf": '<uddf xmlns="http://www.streit.cc/uddf/3.2/"><generator><name>Shearwater Cloud Desktop</name></generator></uddf>',
        "marked.uddf": '<uddf><generator><name>uwmedia dive profile BUILDER 0.7</name></generator></uddf>',
        "plan_only.uddf": '<uddf><profiledata><repetitiongroup><dive><applicationdata><uwmedia><plan>'
                          '{"format":"uwmedia_dive_plan","version":1,"plan":{"name":"In a file","gases":[{"id":"Air"}]}}'
                          '</plan></uwmedia></applicationdata></dive></repetitiongroup></profiledata></uddf>',
        "bad_plan.uddf": '<uddf><generator><name>x</name></generator><dive><applicationdata><uwmedia><plan>{"format":"uwmedia_dive_plan",'
                         '"plan":{"gf_low":500}}</plan></uwmedia></applicationdata></dive></uddf>',
        "broken.uddf": "<uddf><generator>",
        "other.ssrf": '<divelog program="subsurface"><dives><dive><notes>A nice dive</notes><divecomputer model="x"/></dive></dives></divelog>',
        "marked.xml": '<divelog><dives><dive><notes>made by the uwmedia dive profile builder</notes></dive></dives></divelog>',
        "plan_only.ssrf": '<divelog><dives><dive><divecomputer><extradata key="Serial" value="1"/><extradata key="UWMedia plan" '
                          'value="{&quot;format&quot;:&quot;uwmedia_dive_plan&quot;,&quot;plan&quot;:{}}"/></divecomputer></dive></dives></divelog>',
        "other_format.ssrf": '<divelog><dives><dive><divecomputer><extradata key="UWMedia plan" value="{&quot;format&quot;:&quot;else&quot;}"/>'
                             '</divecomputer></dive></dives></divelog>',
        "notes.txt": "UWMedia Dive Profile Builder",
    }
    out = []
    for name, text in texts.items():
        path = tmp / name
        path.write_text(text, encoding="utf-8")
        origin = embed.read_log_origin(path)
        out.append({"name": name, "text": text, "created_by_uwmedia": origin.created_by_uwmedia,
                    "plan": origin.plan.model_dump(mode="json") if origin.plan else None})
    return out


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        out = {
            "now": NOW.isoformat(),
            "constants": {"plan_format": embed.PLAN_FORMAT, "plan_format_version": embed.PLAN_FORMAT_VERSION,
                          "generator_name": embed.GENERATOR_NAME, "notes_mark": embed.SUBSURFACE_NOTES_MARK,
                          "plan_key": embed.SUBSURFACE_PLAN_KEY, "uddf_ns": uddf_writer.UDDF_NS, "ndl_cap_sec": uddf_writer.NDL_CAP_SEC,
                          "ccr_o2_mix_id": uddf_writer.CCR_O2_MIX_ID, "gaschange_event_type": subsurface_writer.GASCHANGE_EVENT_TYPE},
            "cases": [case(*c, tmp) for c in CASES],
            "origins": origin_cases(tmp),
            "plan_from_json": [[t, (embed.plan_from_json(t).model_dump(mode="json") if embed.plan_from_json(t) else None)]
                               for t in (None, "", "not json", "[1]", '{"format":"x"}', '{"format":"uwmedia_dive_plan"}',
                                         '{"format":"uwmedia_dive_plan","plan":{"name":"n","computer":"Shearwater Petrel"}}',
                                         '{"format":"uwmedia_dive_plan","plan":{"gases":[{"o2_percent":21}]}}')],
        }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
