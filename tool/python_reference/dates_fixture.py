"""Parity fixture for the date and timezone logic (spec §3, E2 and E3):
metadata/exif.py's _parse_timezone, get_timezone_offset,
get_standardized_creation_date, get_local_creation_date and the timezone
tags of copy_all, and utils/tag_editor.py, all fed with invented metadata
dicts in the shape exiftool's JSON has. exiftool itself is not run and no
file is read: every path given to the functions does not exist, so the
"file's modification time" step always fails here.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/dates_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/dates/dates_cases.json
"""
import contextlib
import io
import json
import sys
from datetime import timedelta, timezone
from pathlib import Path

sys.path.insert(0, ".")

import metadata.exif as exif  # noqa: E402
from utils import tag_editor  # noqa: E402

GONE = Path("/nonexistent-uwmedia-fixture")


class NoExifTool:
    """Stands in for exiftool.ExifTool: copy_all's copy step does nothing."""

    def __init__(self, *a, **kw):
        self.last_stderr = ""

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, *a):
        return ""


exif.ExifTool = NoExifTool


class Handler(exif.MetadataHandler):
    def __init__(self, meta):
        self.exiftool_path = None
        self.meta = meta
        self.written = None

    def get_metadata(self, src):
        return self.meta

    def get_tags(self, src, tag_names):
        # As MetadataHandler.get_tags reads exiftool's answer: the tag by
        # its full name, else the first one whose name ends the same way.
        result = {}
        meta = self.meta or {}
        for name in tag_names:
            val = meta.get(name)
            if val is None:
                tag_only = name.split(":")[-1]
                for k, v in meta.items():
                    if k.split(":")[-1] == tag_only:
                        val = v
                        break
            result[name] = str(val) if val is not None else ""
        return result

    def set_quicktime_tags(self, src, tags):
        self.written = dict(tags)

    def set_tags(self, src, tags):
        self.written = dict(tags)


def call(fn, *args):
    """["ok", value] or ["raise", exception type]."""
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            value = fn(*args)
    except Exception as e:  # noqa: BLE001
        return ["raise", type(e).__name__]
    if hasattr(value, "isoformat"):
        value = value.isoformat()
    return ["ok", value]


def tz_minutes(value):
    tz = exif.MetadataHandler._parse_timezone(None, value)
    return None if tz is None else tz.utcoffset(None).total_seconds() / 60


TIMEZONES = [None, "", "Z", "UTC", "+2", "+02:00", "02:00", "+0530", "-03:30", "-00:00", 480, -150.0, 0, 0.0, 59.9, -0.5,
             "+08:00:00", "+0800 extra", " +08:00", "2026:05:21", "+23:59", "-23:59", "+24:00", "+99:99", "12:60", 1439,
             1440, -1440, "local", "+8:00", "0800", "08", "+08", "−08:00", 90, "90", "-90"]

METAS = [
    None, {}, {"File:FileName": "x.mp4"},
    # Sony: local time with offset, UTC CreateDate
    {"QuickTime:CreationDate": "2025:10:19 10:21:31+08:00", "QuickTime:CreateDate": "2025:10:19 02:21:31"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31+0800", "QuickTime:CreateDate": "2025:10:19 02:21:31"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31-03:30"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31.98+08:00"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31.5", "QuickTime:CreateDate": "2025:10:19 02:21:31"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31Z", "QuickTime:CreateDate": "2025:10:19 02:21:31"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31+99:00", "QuickTime:CreateDate": "2025:10:19 02:21:31",
     "QuickTime:TimeZone": "+01:00"},
    # the offset from the difference, rounded to 15 minutes
    {"QuickTime:CreateDate": "2025:10:19 02:21:31", "QuickTime:CreationDate": "2025:10:19 07:52:20"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:18 22:00:00"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:19 02:07:29"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:19 02:07:30"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:19 02:22:30"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:19 02:23:00"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:19 01:37:30"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:19 01:52:00"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:19 01:59:30"},
    {"CreateDate": "2025:10:19 02:00:00", "CreationDate": "2025:10:20 16:00:00"},
    {"QuickTime:CreateDate": "2025:10:19 02:21:31", "CreationDate": "2025:10:19 07:52:20", "QuickTime:TimeZone": "+01:00"},
    # unreadable dates: the Timezone tags decide
    {"QuickTime:CreateDate": "garbage", "QuickTime:CreationDate": "also garbage", "QuickTime:TimeZone": "-05:00"},
    {"Timezone": "+09:30"}, {"TimeZone": "+09:30"}, {"QuickTime:Timezone": 480}, {"QuickTime:TimeZone": -150.0},
    {"QuickTime:Timezone": 0, "TimeZone": "+02:00"}, {"QuickTime:Timezone": "", "Timezone": "-01:00"},
    {"QuickTime:TimeZone": "local"}, {"QuickTime:TimeZone": "+99:00"}, {"Timezone": 0},
    {"QuickTime:CreationDate": "broken", "QuickTime:CreateDate": "2025:10:19 02:21:31"},
    {"CreationDate": "2025:10:19 10:21:31", "CreateDate": "2025:10:19 02:21:31"},
    {"QuickTime:CreationDate": "", "CreationDate": "2025:10:19 10:21:31+02:00", "CreateDate": "2025:10:19 08:21:31"},
    {"QuickTime:CreateDate": "broken"}, {"QuickTime:CreateDate": 20251019},
    # photos
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48", "EXIF:SubSecTimeOriginal": 980, "EXIF:OffsetTimeOriginal": "+08:00"},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48.05", "EXIF:SubSecTimeOriginal": "999"},
    {"DateTimeOriginal": "2025:12:03 09:15:48", "SubSecTime": 7},
    {"EXIF:CreateDate": "2025:12:03 09:15:48", "EXIF:SubSecTimeDigitized": "  "},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48", "EXIF:SubSecTimeOriginal": 0, "EXIF:SubSecTimeDigitized": "45"},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48", "EXIF:SubSecTimeOriginal": "007"},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48", "EXIF:SubSecTimeOriginal": "9999999"},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48", "EXIF:SubSecTimeOriginal": "12 ms"},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48", "EXIF:SubSecTimeOriginal": 0.25},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48", "SubSecTimeDigitized": 3, "EXIF:SubSecTime": 4},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48+08:00.123"},
    {"EXIF:DateTimeOriginal": "2025:12:03 09:15:48.999999999"},
    {"EXIF:DateTimeOriginal": "2025:12:3 9:5:8"}, {"EXIF:DateTimeOriginal": "2025-12-03 09:15:48"},
    {"EXIF:DateTimeOriginal": "2025:02:30 09:15:48", "EXIF:CreateDate": "2025:03:01 10:00:00"},
    {"EXIF:DateTimeOriginal": "    :  :     :  :  ", "QuickTime:CreateDate": "2025:10:19 22:21:31"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31+08:00", "EXIF:DateTimeOriginal": "2024:01:01 00:00:00"},
    {"CreationDate": "2025:10:19 10:21:31", "QuickTime:CreationDate": 0, "EXIF:DateTimeOriginal": "2024:01:01 00:00:00"},
    # UTC CreateDate shifted by the Timezone tag
    {"QuickTime:CreationDate": "0000:00:00 00:00:00", "QuickTime:CreateDate": "2025:10:19 22:21:31", "TimeZone": "+08:00"},
    {"QuickTime:CreateDate": "2025:10:19 22:21:31", "QuickTime:Timezone": "-03:30"},
    {"QuickTime:CreateDate": "2025:12:31 22:21:31", "QuickTime:Timezone": 600},
    {"CreateDate": "2025:10:19 22:21:31"}, {"QuickTime:CreateDate": "0000:00:00 00:00:00"},
    {"QuickTime:CreateDate": "0000:00:00 00:00:00", "TimeZone": "+08:00"}, {"QuickTime:CreateDate": "2025:99:99 00:00:00"},
    {"QuickTime:CreateDate": "2025:10:19 22:21:31", "QuickTime:Timezone": "+99:00"},
    {"QuickTime:CreateDate": "2025:10:19 22:21:31.50", "TimeZone": "+01:00"},
    {"QuickTime:CreateDate": "0001:01:01 00:00:00", "TimeZone": "-01:00"},
    # `a or b or c or d` is d when none counts: a TimeZone of 0 is an answer
    {"TimeZone": 0}, {"TimeZone": 0.0}, {"TimeZone": ""}, {"QuickTime:Timezone": 0, "Timezone": 0, "TimeZone": 0},
    {"QuickTime:CreateDate": "2025:10:19 22:21:31", "TimeZone": 0},
    {"QuickTime:CreationDate": "0001:01:01 00:00:00+08:00", "QuickTime:CreateDate": "2025:10:19 22:21:31"},
    {"QuickTime:CreationDate": "2025:1:9 1:2:3", "QuickTime:CreateDate": "2025:1:9 0:2:3"},
    {"QuickTime:CreationDate": "2025:10:19 10:21:31+08:00\n", "QuickTime:CreateDate": "2025:10:19 02:21:31"},
]


def meta_cases():
    out = []
    for meta in METAS:
        h = Handler(meta)
        out.append({
            "meta": meta,
            "timezone_offset": call(h.get_timezone_offset, GONE / "x.mp4"),
            "standardized": call(h.get_standardized_creation_date, GONE / "x.mp4"),
            "local": call(h.get_local_creation_date, GONE / "x.mp4"),
        })
    return out


def copy_all_cases():
    """The tags copy_all writes after the copy, per metadata and forced
    offset (None: the source's own)."""
    out = []
    for meta in [METAS[3], METAS[5], METAS[10], METAS[11], METAS[22], METAS[37], METAS[55], METAS[58], METAS[2], METAS[6]]:
        for forced in (None, 0, 480, -210, 345, -5, 5, 840, -720):
            h = Handler(meta)
            got = call(h.copy_all, GONE / "src.mp4", GONE / "dest.mp4", forced)
            out.append({"meta": meta, "forced": forced, "want": [got[0], h.written if got[0] == "ok" else got[1]]})
    return out


def dji_cases():
    names = ["DJI_20260502110658_0002_D_A001.MP4", "dji_20260502_110658.mp4", "DJI_0001.MP4", "clip.mp4",
             "DJI_20261302110658_0002.MP4", "DJI_20260502110658.jpg"]
    tag_sets = [
        {"QuickTime:OriginalFilePath": "/mnt/media_rw/sd/DCIM/DJI_001/DJI_20260502100659_0002_D_A001.MP4",
         "QuickTime:CreateDate": "2026:05:02 03:06:59", "CreateDate": "2026:05:02 03:06:59"},
        {"QuickTime:CreateDate": "2026:05:02 03:06:59"}, {"CreateDate": "2026-05-02 03:06:59"}, {},
        {"QuickTime:CreateDate": "garbage"}, {"QuickTime:CreateDate": "", "CreateDate": "2026:05:02 14:36:58"},
        {"QuickTime:OriginalFilePath": "", "QuickTime:CreateDate": "2026:05:02 11:14:00"},
        {"QuickTime:OriginalFilePath": "DJI_20261302100659.MP4", "QuickTime:CreateDate": "2026:05:02 03:06:59"},
        {"QuickTime:CreateDate": "2026:05:03 03:06:59.12+00:00"}, {"QuickTime:CreateDate": "2026:05:02 11:14:28"},
        {"QuickTime:CreateDate": "2026:05:02 11:14:29"},
    ]
    return [{"name": n, "tags": t, "want": tag_editor.calculate_dji_datetimes(Path(n), t)} for n in names for t in tag_sets]


def filename_date_cases():
    names = ["DJI_20260502110658_0002_D_A001.MP4", "20260905_143000.jpg", "2026-09-05_143000.jpg", "2026_09_05-143000.mov",
             "20260905-143000.jpg", "IMG_20260905_143000_123.jpg", "DSC06641.JPG", "20261305_143000.jpg",
             "2026-13-05_143000 20260905_143000.jpg", "VID_20260905143000999.mp4", "20260905_250000.jpg",
             "x2026-09-05-143000x.jpg", "2026-09-05 143000.jpg", "20260230_120000_2026-03-01_120000.jpg", "1234567890123456.jpg",
             "00000000_000000.jpg"]
    out = []
    for n in names:
        got = tag_editor.parse_date_from_filename(GONE / n)
        out.append([n, got.isoformat() if got else None])
    return out


def batch_cases():
    """apply_batch_timezone_to_file: the tags it writes, or None when it
    found no date. The file does not exist, so its modification time is
    never the answer."""
    metas = [METAS[3], METAS[5], METAS[6], METAS[7], METAS[10], METAS[32], METAS[34], METAS[35], METAS[37], METAS[38],
             METAS[55], METAS[58], METAS[59], METAS[2], None, {"EXIF:CreateDate": "2025:12:03 09:15:48"},
             {"XMP:CreateDate": "2025:12:03 09:15:48"}, {"QuickTime:TrackCreateDate": "2025:12:03 09:15:48"},
             {"QuickTime:CreateDate": "broken", "XMP:CreateDate": "2025:12:03 09:15:48"}]
    names = ["clip.MP4", "photo.jpg", "20260905_143000.mov", "IMG_20260905_143000.png", "dive.m4v"]
    out = []
    for meta in metas:
        for name in names:
            for mode in tag_editor.TZ_MODE_OPTIONS:
                for minutes in (0, 480, -210, 345):
                    sign = "+" if minutes >= 0 else "-"
                    tz_iso = f"{sign}{abs(minutes) // 60:02}:{abs(minutes) % 60:02}"
                    h = Handler(meta)
                    got = call(tag_editor.apply_batch_timezone_to_file, h, GONE / name, mode, timezone(timedelta(minutes=minutes)),
                               tz_iso)
                    out.append({"meta": meta, "name": name, "mode": mode, "minutes": minutes,
                                "want": [got[0], h.written if got[1] is True else got[1]]})
    return out


def filter_cases():
    rows = [{"tag": "EXIF:DateTimeOriginal", "value": "2026:05:21 06:58:22"}, {"tag": "EXIF:Make", "value": "Sony"},
            {"tag": "EXIF:Model", "value": "ILCE-6700"}, {"tag": "QuickTime:CreateDate", "value": "2026:05:20 22:58:22"},
            {"tag": "EXIF:ISO", "value": 400}, {"tag": "Composite:Åland", "value": "ÅÄÖ"}]
    return {"rows": rows, "filters": [[t, [r["tag"] for r in tag_editor.filter_metadata_rows(rows, t)]]
                                      for t in ["Sony", "", None, "sony", "EXIF", "2026", "400", "åä", "quicktime:", "zzz"]]}


if __name__ == "__main__":
    out = {
        "parse_timezone": [[v, call(tz_minutes, v)] for v in TIMEZONES],
        "metas": meta_cases(),
        "copy_all": copy_all_cases(),
        "tag_guide": tag_editor.TAG_GUIDE,
        "extensions": sorted(tag_editor.TAG_EDITOR_EXTENSIONS),
        "tz_modes": tag_editor.TZ_MODE_OPTIONS,
        "tz_offsets": tag_editor.TZ_OFFSETS,
        "dji": dji_cases(),
        "filename_dates": filename_date_cases(),
        "batch": batch_cases(),
        "filter": filter_cases(),
    }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
