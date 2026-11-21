"""Parity fixture for the two YAML files of the app (spec §7, §13):
config.yaml with the tank names (utils/config.py) and color.yaml with the
colour profiles (utils/color_profiles.py, utils/color_params.py), and for
the YAML text PyYAML writes, which the port's own writer follows.

Both modules write into the user's config folder; here their paths point
into a temporary folder that is removed again, and the checkout's legacy
config.yaml is switched off.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/config_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/config/config_cases.json
"""
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path

import yaml

sys.path.insert(0, ".")

import utils.color_profiles as color_profiles  # noqa: E402
import utils.config as config  # noqa: E402
from utils.color_params import PARAM_GROUPS  # noqa: E402

STRINGS = [
    "Left", "Tank 100", "100", "1.5", "1e3", "0x10", "010", "1_000", "+5", "-5", ".5", "5.", "1:30", "yes", "No", "TRUE",
    "false", "on", "Off", "null", "Null", "~", "", " ", " lead", "trail ", "it's", "a#b", "a #b", "#x", "- x", "-x", "-", "--- x",
    "x: y", "x:y", ":x", "x:", "? x", "?x", "*x", "&x", "!x", "|x", ">x", "'x'", '"x"', "`x`", "@x", "%x", "a, b", "[x]", "{x}",
    "a]b", "x=y", "=", "<<", "2026-01-01", "2026-01-01 10:00:00", "åäö", "Stage é", "日本", "multi\nline", "tab\there", "back\\slash",
    "quote\"double", "emoji 😀", "y", "n", ".inf", ".nan", "1e5", "0o17", "0b11", "12345678901234567890", "a\u00a0b", "\u2028x",
    "end.", "a/b", "a\\b", "C:\\x", "x\r", "bell\x07",
]
VALUES = [0, 1, -7, 100, 1.0, 0.3, 0.001, 0.0001, 1e-05, 1.5e-07, 100.0, 1e16, 1.5e16, 123456789.123, -0.26, 2.0, float("inf"),
          float("-inf"), True, False, None, 9, 218, 0.07]


def dump(value):
    return yaml.dump(value, default_flow_style=False, sort_keys=False)


def dump_cases():
    """[value, text]: what yaml.dump writes. Non-finite numbers are given
    as the texts "inf" and "-inf" in the JSON (it has no such numbers)."""
    def plain(v):
        return str(v) if isinstance(v, float) and v in (float("inf"), float("-inf")) else v

    objects = [
        {}, {"tanks": {}}, {"tanks": {"200": "Left"}, "other": "kept"},
        {"tanks": {"222": "Left", "111": "Right", "333": "Left"}},
        {"default": {"cifval": 1.0, "gw_blur_radius": 9, "darkness": -0.26}, "vivid": {"sharpness": 0.47}},
        {"a": [1, 2, "x"], "b": [], "c": {"d": {"e": [{"f": 1, "g": 2}, [1, [2, 3]], {}]}}, "h": None},
        {"list": [{"a": 1}, {"b": {"c": [1]}}], "nested": [[], [[]], [{}]]},
        {"1": "text key", 2: "int key", 3.5: "float key", True: "bool key", None: "null key"},
    ]
    return {
        "strings": [[s, dump({"k": s}), dump({s: 1}), dump([s])] for s in STRINGS],
        "values": [[plain(v), dump({"k": v})] for v in VALUES],
        "objects": [[json.loads(json.dumps(o)) if all(isinstance(k, str) for k in o) else None, dump(o)] for o in objects],
    }


TANK_TEXTS = [
    None, "", "tanks: {'200': Left}\nother: kept\n", "tanks:\n  3456789: Left\n  '100': Right\n", "tanks: [unclosed",
    "tanks:\n", "other: 1\n", "- a\n- b\n", "just text\n", "tanks: text\n", "tanks: [a, b]\n",
    "tanks:\n  '0123': Zero\n  A1: Stage\n  '77': 'Deco 50'\n  88: 5\n", "# a comment\ntanks:\n  '1': One  # the first\n",
    "tanks:\n  '1': Åland\n  '2': \"quoted: name\"\n  '3': ''\n",
]


@contextlib.contextmanager
def tank_file(tmp, text):
    """A ConfigManager of its own on a config.yaml with `text` (None: no file)."""
    path = tmp / "config.yaml"
    if path.exists():
        path.unlink()
    if text is not None:
        path.write_text(text)
    config.ConfigManager._instance = None
    with contextlib.redirect_stdout(io.StringIO()):
        yield config.get_config(), path
    config.ConfigManager._instance = None


def read(path):
    return path.read_text() if path.exists() else None


def tank_cases(tmp):
    out = []
    for text in TANK_TEXTS:
        with tank_file(tmp, text) as (cfg, path):
            try:
                case = {"text": text, "loaded": cfg.is_loaded(), "mapping": list(cfg.get_tank_mapping().items()),
                        "names": [[s, cfg.map_tank_name(s)] for s in ("200", "3456789", "0123", "1", "none")],
                        "order": cfg.order_tanks(["9", "Right", "5", "Left", "One", "Stage", "Zero"])}
            except Exception as e:  # noqa: BLE001  (a file that is not a mapping: Python fails on it)
                out.append({"text": text, "raise": type(e).__name__})
                continue
        ops = []
        for name, run in [
            ("save", lambda c: c.save_config(["300", 200, "100"])),
            ("save_none", lambda c: c.save_config([])),
            ("rename", lambda c: c.set_tank_name(200, "Stage")),
            ("rename_new", lambda c: c.set_tank_name("555", "New: tank")),
            ("remove", lambda c: c.remove_tank("200")),
            ("remove_missing", lambda c: c.remove_tank("never-there")),
            ("replace", lambda c: c.set_tank_mapping({"222": "Left", 111: "Right", "333": "Left"})),
            ("replace_empty", lambda c: c.set_tank_mapping({})),
        ]:
            with tank_file(tmp, text) as (cfg, path):
                try:
                    run(cfg)
                    ops.append([name, read(path), list(cfg.get_tank_mapping().items())])
                except Exception as e:  # noqa: BLE001
                    ops.append([name, "raise " + type(e).__name__, None])
        case["ops"] = ops
        out.append(case)
    return out


BUNDLED = Path("color.yaml").read_text()
USER_TEXTS = [
    None, "", "mine:\n  sharpness: 1.0\n  darkness: 0.1\n", "default:\n  sharpness: 0.0\n", "broken: [unclosed",
    "vivid:\n  cifval: 0.5\nReef 2:\n  red_scale: 0.25\n  gw_blur_radius: 11\n", "note: text\n",
]


def color_cases(tmp):
    user = tmp / "color.yaml"
    bundled = tmp / "bundled_color.yaml"
    color_profiles.user_color_yaml_path = lambda: user
    out = {"bundled": BUNDLED, "merged": [], "saved": []}
    for bundled_text in (BUNDLED, None, "", "only:\n  cifval: 0.5\n"):
        for user_text in USER_TEXTS:
            for path, text in ((bundled, bundled_text), (user, user_text)):
                if path.exists():
                    path.unlink()
                if text is not None:
                    path.write_text(text)
            color_profiles.bundled_color_yaml_path = lambda: bundled if bundled.exists() else None
            with contextlib.redirect_stdout(io.StringIO()):
                merged = color_profiles.load_merged_color_profiles()
            out["merged"].append({"bundled": bundled_text, "user": user_text, "names": list(merged), "profiles": merged})
    values = {"cifval": 1.0, "red_threshold": 0.25, "gw_blur_radius": 9, "gw_isolation_min_sum": 100.0, "darkness": -0.26,
              "black_point_cutoff": 0.0001}
    for user_text in USER_TEXTS:
        for name in ("mine", "default", "Reef 2", "100"):
            if user.exists():
                user.unlink()
            if user_text is not None:
                user.write_text(user_text)
            with contextlib.redirect_stdout(io.StringIO()):
                color_profiles.save_user_profile(name, values)
            out["saved"].append({"user": user_text, "name": name, "values": values, "text": user.read_text()})
    return out


if __name__ == "__main__":
    config.bundled_config_yaml_path = lambda: None
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        config.user_config_yaml_path = lambda: tmp / "config.yaml"
        out = {
            "pyyaml": yaml.__version__,
            "dump": dump_cases(),
            "tanks": tank_cases(tmp),
            "color": color_cases(tmp),
            "param_groups": [[group, [list(p) for p in params]] for group, params in PARAM_GROUPS],
        }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
