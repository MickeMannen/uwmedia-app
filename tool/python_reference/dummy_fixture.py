"""Parity fixture for the Overlay Designer's sample dive (spec §5):
utils/dummy_telemetry.py's build_dummy_dive, waypoint_at, apply_state and
forced_dive, with what the rules engine and the notices say about the
dives it makes.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/dummy_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/hud_designer/dummy_cases.json.gz
"""
import json
import sys

sys.path.insert(0, ".")

from utils import dummy_telemetry as dummy  # noqa: E402
from utils.hud_notices import active_notice  # noqa: E402
from utils.hud_rules_engine import resolve_state, resolve_tank_variant, stop_phase  # noqa: E402

BRANDS = [("Shearwater", "Perdix 2"), ("Garmin", "mk3i"), ("Garmin", "x50i"), (None, None)]


def dump(wp):
    return wp.model_dump(mode="json", exclude_none=True)


def said(wp, history):
    """Per brand: state, phase and notice text."""
    out = []
    for manufacturer, model in BRANDS:
        state, phase, _, _ = stop_phase(manufacturer, model, wp, history)
        notice = active_notice(manufacturer, model, wp, history)
        out.append([state, phase, notice["text"] if notice else None])
    return out


def dive_cases():
    out = []
    for variant, ccr in [("single_tank", False), ("sidemount", False), (None, False), ("no_tank", False), ("single_tank", True),
                         ("sidemount", True)]:
        dive = dummy.build_dummy_dive(variant, ccr=ccr)
        out.append({
            "variant": variant, "ccr": ccr, "tank_variant": resolve_tank_variant(dive),
            "dive": dive.model_dump(mode="json", exclude_none=True, exclude={"log_path"}),
            "said": [said(wp, dive.waypoints) for wp in dive.waypoints],
            "waypoint_at": [[t, dummy.waypoint_at(dive, t).time_since_start] for t in (0, 95, 100, 100.5, 719.9, 1920, 10 ** 6, -5)],
        })
    return out


def state_cases():
    """apply_state and forced_dive for every state from several moments of
    the dive (and of the sidemount and rebreather ones)."""
    out = []
    for variant, ccr, times in [("single_tank", False, (0, 60, 720, 930, 1230, 1530, 1600, 1920)), ("sidemount", False, (720,)),
                                ("single_tank", True, (720, 1300))]:
        dive = dummy.build_dummy_dive(variant, ccr=ccr)
        for t in times:
            base = dummy.waypoint_at(dive, t)
            for state in [*dummy.STATE_OPTIONS, "not-a-state"]:
                applied = dummy.apply_state(base, state)
                forced, history = dummy.forced_dive(base, state)
                out.append({
                    "variant": variant, "ccr": ccr, "t": t, "state": state,
                    "applied": dump(applied), "applied_same": applied is base,
                    "applied_states": [resolve_state(m, mo, applied) for m, mo in BRANDS],
                    "forced": dump(forced), "forced_same": forced is base,
                    "history": None if history is None else [dump(wp) for wp in history],
                    "said": said(forced, history),
                })
    return out


if __name__ == "__main__":
    out = {
        "start": dummy.DUMMY_START.isoformat(), "duration_s": dummy.DUMMY_DURATION_S, "sample_s": dummy.DUMMY_SAMPLE_S,
        "state_options": dummy.STATE_OPTIONS, "state_labels": dummy.STATE_LABELS, "state_outer": dummy.STATE_OUTER,
        "brands": BRANDS,
        "dives": dive_cases(),
        "states": state_cases(),
    }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
