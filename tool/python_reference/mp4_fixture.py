"""Reference for the port's own MP4 date reader and writer (spec §3): what
exiftool, called the way the Python app's MetadataHandler calls it, reads
from small MP4 and MOV files and what it leaves in them after writing date
tags.

The files are synthetic: one or two frames of ffmpeg's test pattern (and a
sine tone), a few kilobytes each, made in a temporary folder that is
removed again. They are kept in the fixture as base64, so no video file
goes into git. Only the tags the port's reader claims are recorded.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/mp4_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/mp4/mp4_cases.json
"""
import base64
import contextlib
import io
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")

from metadata.exif import MetadataHandler  # noqa: E402
from utils.tool_paths import get_exiftool_path, get_ffmpeg_path  # noqa: E402

CLAIMED = ["CreateDate", "ModifyDate", "TrackCreateDate", "TrackModifyDate", "MediaCreateDate", "MediaModifyDate",
           "CreationDate", "Make", "Model", "Software"]
VIDEO = ["-f", "lavfi", "-i", "testsrc=size=64x64:rate=1"]
AUDIO = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=8000:duration=1"]
ENCODE = ["-frames:v", "1", "-pix_fmt", "yuv420p", "-bitexact"]


def ffmpeg(path, *args, inputs=VIDEO):
    subprocess.run([str(get_ffmpeg_path()), "-v", "error", "-y", *inputs, *ENCODE, *args, str(path)], check=True)


def tags_of(handler, path):
    meta = handler.get_metadata(path) or {}
    return {k: v for k, v in meta.items() if k.startswith("QuickTime:") and k.split(":")[1] in CLAIMED}


def write(handler, path, tags):
    with contextlib.redirect_stdout(io.StringIO()):
        handler.set_quicktime_tags(path, tags)


SOURCES = {
    # name: (file name, ffmpeg arguments, ffmpeg inputs, tags exiftool then writes)
    "bare": ("bare.mp4", [], VIDEO, {}),
    "ffmpeg_creation_time": ("ct.mp4", ["-metadata", "creation_time=2025-10-19T02:21:31Z"], VIDEO, {}),
    "faststart": ("fast.mp4", ["-movflags", "+faststart", "-metadata", "creation_time=2025-10-19T02:21:31Z"], VIDEO, {}),
    "two_tracks": ("two.mp4", ["-c:a", "aac", "-b:a", "16k", "-shortest", "-metadata", "creation_time=2026-05-02T03:06:59Z"],
                   VIDEO + AUDIO, {}),
    "two_tracks_faststart": ("twofast.mp4", ["-c:a", "aac", "-b:a", "16k", "-shortest", "-movflags", "+faststart"],
                             VIDEO + AUDIO, {}),
    "mov_keys": ("keys.mov", ["-f", "mov", "-movflags", "use_metadata_tags", "-metadata",
                              "com.apple.quicktime.creationdate=2025-10-19T10:21:31+0800", "-metadata",
                              "com.apple.quicktime.make=Sony", "-metadata", "com.apple.quicktime.model=ILCE-6700"], VIDEO, {}),
    "mov_plain": ("plain.mov", ["-f", "mov", "-metadata", "creation_time=2025-10-19T02:21:31Z"], VIDEO, {}),
    "exiftool_dates": ("et.mp4", [], VIDEO, {
        "QuickTime:CreateDate": "2025:10:19 02:21:31", "QuickTime:ModifyDate": "2025:10:19 02:21:32",
        "QuickTime:TrackCreateDate": "2025:10:19 02:21:33", "QuickTime:TrackModifyDate": "2025:10:19 02:21:34",
        "QuickTime:MediaCreateDate": "2025:10:19 02:21:35", "QuickTime:MediaModifyDate": "2025:10:19 02:21:36",
        "QuickTime:CreationDate": "2025:10:19 10:21:31+08:00"}),
    "exiftool_keys": ("etkeys.mp4", [], VIDEO, {
        "QuickTime:CreationDate": "2025:10:19 10:21:31.98-03:30", "Keys:Make": "Sony", "Keys:Model": "ILCE-6700",
        "Keys:Software": "ILCE-6700 v2.00"}),
    "creation_utc": ("etz.mp4", [], VIDEO, {"QuickTime:CreationDate": "2025:10:19 10:21:31Z"}),
    "creation_naive": ("etn.mp4", [], VIDEO, {"QuickTime:CreationDate": "2025:10:19 10:21:31"}),
    "late_dates": ("late.mp4", [], VIDEO, {"QuickTime:CreateDate": "2039:12:31 23:59:59",
                                          "QuickTime:ModifyDate": "1970:01:01 00:00:01"}),
}

CONTAINERS = (b"moov", b"trak", b"mdia")


def rebuild(data, change):
    """`data` (a run of boxes) with `change(type, payload)` applied to every
    box, the boxes inside moov, trak and mdia included, and the sizes set
    again."""
    out = b""
    off = 0
    while off + 8 <= len(data):
        size, kind = struct.unpack(">I4s", data[off:off + 8])
        payload = data[off + 8:off + size]
        if kind in CONTAINERS:
            payload = rebuild(payload, change)
        payload = change(kind, payload)
        out += struct.pack(">I4s", len(payload) + 8, kind) + payload
        off += size
    return out


def to_version_1(kind, payload):
    """mvhd, tkhd and mdhd with 64-bit dates and durations."""
    if kind == b"mvhd" or kind == b"mdhd":
        created, modified, timescale, duration = struct.unpack(">IIII", payload[4:20])
        return b"\x01" + payload[1:4] + struct.pack(">QQIQ", created, modified, timescale, duration) + payload[20:]
    if kind == b"tkhd":
        created, modified, track, reserved, duration = struct.unpack(">IIIII", payload[4:24])
        return b"\x01" + payload[1:4] + struct.pack(">QQIIQ", created, modified, track, reserved, duration) + payload[24:]
    return payload


def tracks_apart(data):
    """Track n's tkhd creation date n days later, its mdhd's n hours."""
    data = bytearray(data)
    for kind, step in ((b"tkhd", 86400), (b"mdhd", 3600)):
        at, n = data.find(kind), 0
        while at >= 0:
            n += 1
            struct.pack_into(">I", data, at + 8, struct.unpack(">I", data[at + 8:at + 12])[0] + n * step)
            at = data.find(kind, at + 4)
    return bytes(data)


def movie_date(value):
    def change(data):
        data = bytearray(data)
        struct.pack_into(">I", data, data.find(b"mvhd") + 8, value)
        return bytes(data)
    return change


# name: (the source it is made from, the change to its bytes); moov is the
# last box of every one of these sources, so no chunk offset moves.
DERIVED = {
    "version_1": ("ffmpeg_creation_time", lambda data: rebuild(data, to_version_1)),
    "tracks_apart": ("two_tracks", tracks_apart),
    # exiftool takes a value under 1904 + 66 years for seconds from 1970
    "epoch_1": ("bare", movie_date(1)),
    "epoch_below": ("bare", movie_date(2082844799)),
    "epoch_at": ("bare", movie_date(2082844800)),
    "epoch_above": ("bare", movie_date(2082844801)),
    "epoch_max": ("bare", movie_date(0xFFFFFFFF)),
}

WRITES = {
    # what copy_all writes after the copy
    "copy_all": {"QuickTime:CreationDate": "2025:10:19 10:21:31+08:00", "QuickTime:Timezone": "+08:00",
                 "QuickTime:TimeZone": "+08:00"},
    # the batch timezone change of a video
    "batch": {"QuickTime:CreationDate": "2026:05:02 10:06:59-03:30", "QuickTime:Timezone": "-03:30",
              "QuickTime:TimeZone": "-03:30", "EXIF:DateTimeOriginal": "2026:05:02 10:06:59",
              "EXIF:CreateDate": "2026:05:02 10:06:59"},
    # the Tag Editor's fields
    "editor": {"QuickTime:CreationDate": "2026:05:21 06:58:22+08:00", "QuickTime:CreateDate": "2026:05:20 22:58:22"},
    "headers": {"QuickTime:CreateDate": "2026:05:20 22:58:22", "QuickTime:ModifyDate": "2026:05:20 22:58:23",
                "QuickTime:TrackCreateDate": "2026:05:20 22:58:24", "QuickTime:TrackModifyDate": "2026:05:20 22:58:25",
                "QuickTime:MediaCreateDate": "2026:05:20 22:58:26", "QuickTime:MediaModifyDate": "2026:05:20 22:58:27"},
    "zero": {"QuickTime:CreateDate": "0000:00:00 00:00:00", "QuickTime:TrackCreateDate": "0000:00:00 00:00:00"},
    "utc_creation": {"QuickTime:CreationDate": "2026:05:21 06:58:22Z"},
    "subseconds": {"QuickTime:CreationDate": "2026:05:21 06:58:22.5+05:45"},
}

if __name__ == "__main__":
    handler = MetadataHandler()
    version = subprocess.run([str(get_exiftool_path()), "-ver"], capture_output=True, text=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        sources = {}
        for name, (file_name, args, inputs, tags) in SOURCES.items():
            path = tmp / file_name
            ffmpeg(path, *args, inputs=inputs)
            if tags:
                write(handler, path, tags)
            sources[name] = {"file": file_name, "base64": base64.b64encode(path.read_bytes()).decode(),
                             "tags": tags_of(handler, path)}
        files = {name: file_name for name, (file_name, *_rest) in SOURCES.items()}
        for name, (parent, change) in DERIVED.items():
            file_name = name + ".mp4"
            path = tmp / file_name
            path.write_bytes(change((tmp / files[parent]).read_bytes()))
            files[name] = file_name
            sources[name] = {"file": file_name, "base64": base64.b64encode(path.read_bytes()).decode(),
                             "tags": tags_of(handler, path)}
        writes = []
        for name, file_name in files.items():
            for write_name, tags in WRITES.items():
                copy = tmp / ("w_" + file_name)
                shutil.copyfile(tmp / file_name, copy)
                write(handler, copy, tags)
                writes.append({"source": name, "write": write_name, "tags": tags_of(handler, copy)})
        out = {"exiftool": version, "claimed": CLAIMED, "sources": sources, "write_sets": WRITES, "writes": writes}
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
