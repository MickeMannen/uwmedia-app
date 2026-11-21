"""Local parity references from the owner's real dive logs: what the Python
app's parsers make of every log under test_data/logs. Real logs carry
serial numbers and personal data, so neither they nor these references are
ever committed: the output goes into this repo's git-ignored test_data/.

Only the formats whose parser is ported are dumped (FORMATS below; Suunto app
JSON since Python 0.8.0). The
Shearwater exports are parsed with the SAC rule of the port's one shared
deco pass, as in shearwater_fixture.py.

Run from the Python repo's root with its own interpreter (nothing is
written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/real_logs_fixture.py \
        $APP_REPO/test_data
"""
import contextlib
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")

import utils.config as config  # noqa: E402

# Tanks keep their sensor serials as keys: the tank names of this machine's
# own config.yaml are not read.
config.user_config_yaml_path = lambda: Path("/nonexistent/config.yaml")
config.bundled_config_yaml_path = lambda: None
config.ConfigManager._instance = None

import parsers.deco_pass as deco_pass  # noqa: E402
from parsers.registry import detect_log_format, parse_log_file  # noqa: E402
from utils.gas_consumption import fill_sac_and_gtr  # noqa: E402

FORMATS = {"uddf", "shearwater_xml", "shearwater_csv", "subsurface_csv", "subsurface_xml", "fit", "suunto_json"}


def _uddf_rule_fill(waypoints):
    if not any(getattr(wp, "pressure_sac", None) is not None for wp in waypoints):
        fill_sac_and_gtr(waypoints)


def clean(value):
    """NaN and infinity are not JSON; none of the compared fields should
    hold one, and if one does the reference says so."""
    if isinstance(value, float) and (value != value or value in (float("inf"), float("-inf"))):
        return f"non-finite: {value}"
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(v) for v in value]
    return value


if __name__ == "__main__":
    test_data = Path(sys.argv[1])
    logs = test_data / "logs"
    out_root = test_data / "python_reference" / "dives"
    deco_pass.fill_sac_and_gtr = _uddf_rule_fill
    count = 0
    for path in sorted(p for p in logs.rglob("*") if p.is_file()):
        log_format = detect_log_format(path)
        if log_format not in FORMATS:
            continue
        with contextlib.redirect_stdout(sys.stderr):
            try:
                dives = parse_log_file(path)
                result = {
                    "format": log_format,
                    "dives": [
                        {
                            **d.model_dump(mode="json", exclude={"log_path"}, exclude_none=True),
                            "max_depth_property": d.max_depth,
                            "is_ccr": d.is_ccr,
                            "circuits": [w.circuit for w in d.waypoints],
                            "gasmixes": [w.gasmix for w in d.waypoints],
                        }
                        for d in dives
                    ],
                }
            except Exception as e:  # noqa: BLE001 - recorded, the Dart side must fail too
                result = {"format": log_format, "error": f"{type(e).__name__}: {e}"}
        relative = path.relative_to(logs)
        out = out_root / (str(relative) + ".json")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(clean(result), separators=(",", ":")))
        count += 1
        print(f"{log_format:15} {relative}  {len(result.get('dives', []))} dive(s) {result.get('error', '')}", file=sys.stderr)
    print(f"{count} reference(s) written under {out_root}", file=sys.stderr)
