"""Parity fixture for rebuilding a plan from a log (spec §7):
utils/dive_plan_import.py's plan_from_log and its helpers, on the
synthetic logs this repo's parser fixtures already hold
(test/fixtures/python_reference/dives/{uddf,subsurface,shearwater,
subsurface_csv}.json) and on the logs of writers_cases.json.gz, each
parsed with the Python parsers as the builder's Open log does (the first
dive of the file). FIT logs are not here.

The logs are written into a temporary folder that is removed again. The
fixture names each log by its fixture file and case, so no log is copied.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/import_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/plan/import_cases.json.gz
"""
import base64
import contextlib
import gzip
import io
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")

from models.dive_plan import DiveProfilePlan  # noqa: E402
from parsers.registry import detect_log_format, parse_log_file  # noqa: E402
from utils import dive_plan_import as I  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "test" / "fixtures" / "python_reference"
BASES = {
    "default": {},
    "own": {"gf_low": 45.0, "gf_high": 80.0, "sac_lpm": 15.0, "computer": "Garmin Descent Mk3i", "water_temp_c": 12.0,
            "max_po2_bottom": 1.3, "name": "Base name", "ccr_low_setpoint": 0.5, "sidemount_switch_bar": 20.0,
            "gases": [{"id": "Old"}], "waypoints": [{"runtime_sec": 60, "depth_m": 5, "gas_id": "Old"}]},
}


def rebuilt(path):
    """As the builder's Open log: the first dive of the file, then
    plan_from_log on each base; or why it cannot."""
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            log_format = detect_log_format(path)
            dives = parse_log_file(path, log_format) if log_format else None
        except Exception as e:  # noqa: BLE001
            return {"parse": "raise " + type(e).__name__}
        if not dives:
            return {"parse": "no dive", "format": log_format}
        out = {"format": log_format, "plans": {}}
        for name, base in BASES.items():
            try:
                plan = I.plan_from_log(path, dives[0], DiveProfilePlan.model_validate(base))
                out["plans"][name] = ["ok", plan.model_dump(mode="json")]
            except Exception as e:  # noqa: BLE001
                out["plans"][name] = ["raise", type(e).__name__]
    return out


def log_cases(tmp):
    out = []
    for source in ("uddf", "subsurface", "shearwater", "subsurface_csv"):
        data = json.loads((FIXTURES / "dives" / f"{source}.json").read_text())
        for i, case in enumerate(data["parse"]):
            folder = tmp / f"{source}{i}"
            folder.mkdir()
            path = folder / case["file_name"]
            path.write_bytes(base64.b64decode(case["bytes_base64"]))
            out.append({"source": f"dives/{source}.json", "name": case["name"], "index": i, **rebuilt(path)})
    writers = json.loads(gzip.decompress((FIXTURES / "plan" / "writers_cases.json.gz").read_bytes()))
    for i, case in enumerate(writers["cases"]):
        for key, suffix in (("uddf", ".uddf"), ("subsurface", ".ssrf")):
            folder = tmp / f"written{i}{key}"
            folder.mkdir()
            path = folder / f"Wreck_dive {i}{suffix}"
            path.write_text(case[key], encoding="utf-8")
            out.append({"source": "plan/writers_cases.json.gz", "name": key, "index": i, "file_name": path.name, **rebuilt(path)})
    return out


def simplify_cases():
    profiles = {
        "flat": [(t, 20.0) for t in range(0, 600, 10)],
        "v": [(0, 0.0), (60, 20.0), (120, 0.0)],
        "noisy": [(t * 10, 20.0 + ((t * 7) % 5) * 0.3) for t in range(60)],
        "steps": [(0, 0.0), (30, 10.0), (300, 10.0), (330, 20.0), (600, 20.0), (700, 5.0), (880, 5.0), (900, 0.0)],
        "two": [(0, 1.0), (10, 2.0)], "one": [(5, 5.0)], "none": [],
        "same_ends": [(0, 5.0), (10, 9.0), (20, 5.4), (30, 5.0), (0, 5.0)],
    }
    return [[name, [list(p) for p in points], tol, [list(p) for p in I.simplify_profile(points, tol)]]
            for name, points in profiles.items() for tol in (0.6, 0.1, 5.0)]


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp_name:
        cases = log_cases(Path(tmp_name))
    out = {
        "tolerance_m": I.PROFILE_TOLERANCE_M, "max_waypoints": I.MAX_PROFILE_WAYPOINTS, "bases": BASES,
        "mix_names": [[o2, he, I.mix_name(o2, he), I.gas_type_for(o2, he)]
                      for o2, he in ((21.0, 0.0), (20.6, 0.0), (21.5, 0.0), (20.4, 0.0), (32.0, 0.0), (32.5, 0.0), (100.0, 0.0), (18.0, 45.0),
                                     (10.5, 70.25), (21.0, 0.1))],
        "mmss": [[t, I._mmss_seconds(t)] for t in ("12:34 min", "45 s", "12:34", "0:05.9 min", "", "7", " 3:00 min ", "90.7 s", "1:5")],
        "pair_up": [[refs, mixes, [list(p) for p in I._pair_up(refs, mixes)]] for refs, mixes in (
            (["T1"], None), (["T1L", "T1R"], None), (["T1", "T2"], ["a", "a"]), (["T1", "T2"], ["a", "b"]), (["T1", "T2", "T3"], ["a", "b", "b"]),
            (["AL", "AR", "BL", "BR"], None), (["T1", "T2", "T3", "T4"], ["a", "a", "b", "b"]), ([], None), (["L", "R"], None),
            (["T1L", "T2R"], None))],
        "simplify": simplify_cases(),
        "logs": cases,
    }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
    print(len(cases), "logs", file=sys.stderr)
