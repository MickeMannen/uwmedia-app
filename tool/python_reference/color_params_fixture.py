"""Parity fixture for the Color Tuning page's sliders (utils/color_params.py
PARAM_GROUPS: group titles, and per parameter key, label, range, default
and whether it is whole) and its value text (backends/color_tuning_backend.py
_format_color_value).

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 QT_QPA_PLATFORM=offscreen .venv/bin/python -B \
        $APP_REPO/tool/python_reference/color_params_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/color/color_params_cases.json
"""
import json
import sys

sys.path.insert(0, ".")

from uwmedia.backends.color_tuning_backend import FLOAT_SLIDER_SCALE, NEW_PROFILE_NAME_MAX_LEN, _format_color_value  # noqa: E402
from utils.color_params import PARAM_GROUPS  # noqa: E402

groups = [
    {"title": title, "params": [list(param) for param in params]}
    for title, params in PARAM_GROUPS
]
values = [0.0, 0.0001, 0.00049, 0.0005, 0.0015, 0.0025, 0.125, 0.3, 1.0, 1.9995, -0.5, -0.0004, 2.5, 3.0]
texts = [[v, False, _format_color_value(v, False)] for v in values]
texts += [[v, True, _format_color_value(v, True)] for v in [0, 1, 9, 9.5, 10.5, 254.6, 31]]
json.dump(
    {
        "groups": groups,
        "slider_scale": FLOAT_SLIDER_SCALE,
        "name_max": NEW_PROFILE_NAME_MAX_LEN,
        "texts": texts,
    },
    sys.stdout,
    indent=1,
)
sys.stdout.write("\n")
