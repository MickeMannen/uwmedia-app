"""Parity fixture for the text shown when ffmpeg, ffprobe or exiftool is
missing (utils/dependency_check.py's get_installation_instructions), for
every set of missing tools on each system.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/tools_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/engine/tools_cases.json
"""
import itertools
import json
import sys

sys.path.insert(0, ".")

from utils import dependency_check as D  # noqa: E402

TOOLS = ["ffmpeg", "ffprobe", "exiftool"]

if __name__ == "__main__":
    out = {"instructions": [
        {"missing": list(missing), "system": system, "text": D.get_installation_instructions(list(missing), system)}
        for system in ("Darwin", "Windows", "Linux")
        for n in (1, 2, 3) for missing in itertools.combinations(TOOLS, n)
    ]}
    json.dump(out, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")
