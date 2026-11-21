"""Parity fixture for the exiftool command lines (spec §3): what
metadata/exif.py's MetadataHandler asks of exiftool through pyexiftool in
copy_all, get_metadata, get_tags, set_tags and set_quicktime_tags. No
exiftool runs: pyexiftool's process is replaced by a recorder that answers
with the metadata of the case, so the fixture holds the argument lists
pyexiftool would send (after its own "-G -n", and "-j" for a read) and
what the handler returns.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/exiftool_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/engine/exiftool_cases.json
"""
import contextlib
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")

import exiftool  # noqa: E402

import metadata.exif as X  # noqa: E402

CALLS = []
META = {}


def _text(value):
    return value.decode("utf-8") if isinstance(value, bytes) else str(value)


class _Recorder:
    """Stands in for pyexiftool's running process: what would be sent is
    recorded (after the common arguments), and a read is answered with the
    metadata of the case."""

    def __del__(self):
        pass

    @property
    def running(self):
        return getattr(self, "_fake_running", False)

    def run(self):
        self._fake_running = True

    def terminate(self, **_kwargs):
        self._fake_running = False

    @property
    def last_stderr(self):
        return ""

    def execute(self, *params, **_kwargs):
        args = [_text(p) for p in params]
        CALLS.append(list(self._common_args) + args)
        if "-j" in args:
            return json.dumps([{"SourceFile": args[-1], **META}])
        return "    1 image files updated"

    def execute_json(self, *params, **_kwargs):
        # pyexiftool's own puts "-j" first and parses the answer.
        return json.loads(self.execute("-j", *params))


class RecordingExifTool(_Recorder, exiftool.ExifTool):
    pass


class RecordingHelper(_Recorder, exiftool.ExifToolHelper):
    pass


X.ExifTool = RecordingExifTool
X.ExifToolHelper = RecordingHelper

VIDEO = {"QuickTime:CreateDate": "2025:10:19 02:21:31", "QuickTime:CreationDate": "2025:10:19 10:21:31+08:00",
         "QuickTime:Make": "Sony", "File:FileModifyDate": "2025:10:19 10:21:35+08:00"}
NO_TZ = {"QuickTime:CreateDate": "2025:10:19 02:21:31"}
PHOTO = {"EXIF:DateTimeOriginal": "2026:05:21 06:58:22", "EXIF:OffsetTimeOriginal": "+08:00", "EXIF:Make": "SONY",
         "Composite:SubSecDateTimeOriginal": "2026:05:21 06:58:22.123+08:00"}
SONY_XML = {**VIDEO, "XML:LastUpdate": "2025:09:13 09:37:36+07:00", "XML:CreationDateValue": "2025-09-13T09:37:30+07:00",
            "XML:VideoFormatVideoFrameCaptureFps": "50.00p", "XML:DeviceManufacturer": "Sony", "XML:DeviceModelName": "ILCE-6700",
            "XML:LensModelName": "E PZ 16-50mm F3.5-5.6 OSS", "XML:Other": "left alone"}
ODD_XML = {"XML:DeviceModelName": 6700, "XML:VideoFormatVideoFrameCaptureFps": 59.94, "XML:DeviceManufacturer": True,
           "XML:LastUpdate": "2025:09:13 09:37:36", "XML:CreationDateValue": "2025-09-13T02:37:30Z", "XML:LensModelName": "50p"}

COPIES = [
    # name, metadata of the source, source, target, forced timezone, custom tags
    ("video_with_timezone", VIDEO, "/in/C0001.MP4", "/out/20251019_102131.mp4", None, None),
    ("video_forced_timezone", VIDEO, "/in/C0001.MP4", "/out/a b/ö.mp4", -210, None),
    ("video_without_timezone", NO_TZ, "/in/C0001.MP4", "/out/x.mp4", None, None),
    ("video_without_timezone_forced", NO_TZ, "/in/C0001.MP4", "/out/x.mp4", 0, ["QuickTime:Make=UWMedia", "Keys:Model=x y"]),
    ("photo", PHOTO, "/in/DSC1.JPG", "/out/DSC1.jpg", None, ["Artist=Me"]),
    ("no_metadata", {}, "/in/a.mp4", "/out/a.mp4", None, []),
    ("sony_xml", SONY_XML, "/in/C0001.MP4", "/out/c.mp4", None, None),
    ("odd_xml", ODD_XML, "/in/C0001.MP4", "/out/c.mp4", None, ["Artist=Me"]),
    ("xml_date_0", {"XML:LastUpdate": '2025:09:13 09:37:36.25+07:00', "XML:CreationDateValue": '2025:09:13 09:37:36.25+07:00'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_1", {"XML:LastUpdate": '2025:09:13 09:37:36,5-03:30', "XML:CreationDateValue": '2025:09:13 09:37:36,5-03:30'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_2", {"XML:LastUpdate": '2025-09-13 09:37:36', "XML:CreationDateValue": '2025-09-13 09:37:36'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_3", {"XML:LastUpdate": '2025-09-13 09:37:36-00:00', "XML:CreationDateValue": '2025-09-13 09:37:36-00:00'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_4", {"XML:LastUpdate": '2025-09-13T09:37:36+14:00', "XML:CreationDateValue": '2025-09-13T09:37:36+14:00'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_5", {"XML:LastUpdate": '2025:13:13 09:37:36', "XML:CreationDateValue": '2025:13:13 09:37:36'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_6", {"XML:LastUpdate": '2025:09:13 09:37:36+7:00', "XML:CreationDateValue": '2025:09:13 09:37:36+7:00'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_7", {"XML:LastUpdate": '2025:09:13 09:37:36+24:00', "XML:CreationDateValue": '2025:09:13 09:37:36+24:00'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_8", {"XML:LastUpdate": '2025:09:13 09:37:36+07:60', "XML:CreationDateValue": '2025:09:13 09:37:36+07:60'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_9", {"XML:LastUpdate": '13 Sep 2025', "XML:CreationDateValue": '13 Sep 2025'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_10", {"XML:LastUpdate": '2025:09:13 09:37:36.1234567+07:00', "XML:CreationDateValue": '2025:09:13 09:37:36.1234567+07:00'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_11", {"XML:LastUpdate": '2025:9:3 9:7:6+07:00', "XML:CreationDateValue": '2025:9:3 9:7:6+07:00'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_12", {"XML:LastUpdate": '25:09:13 09:37:36', "XML:CreationDateValue": '25:09:13 09:37:36'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_13", {"XML:LastUpdate": '2025:09:13 09:37:60', "XML:CreationDateValue": '2025:09:13 09:37:60'}, "/in/a.mp4", "/out/a.mp4", None, None),
    ("xml_date_14", {"XML:LastUpdate": '', "XML:CreationDateValue": ''}, "/in/a.mp4", "/out/a.mp4", None, None),
]
READS = [
    ("all", VIDEO, None),
    ("named", VIDEO, ["QuickTime:CreateDate", "CreateDate", "QuickTime:Make", "EXIF:Nothing"]),
    ("loose", {"EXIF:CreateDate": "2026:05:21 06:58:22", "XMP:xCreateDate": "x", "QuickTime:Rotation": 90, "QuickTime:Zero": 0},
     ["CreateDate", "QuickTime:CreateDate", "Composite:Rotation", "Zero", "Missing"]),
]
WRITES = [
    ("set_tags", "/m/a.mp4", {"QuickTime:CreationDate": "2026:05:21 06:58:22+08:00", "EXIF:CreateDate": "2026:05:21 06:58:22"}),
    ("set_tags", "/m/a b.jpg", {"EXIF:OffsetTime": "+05:45"}),
    ("set_tags", "/m/a.mp4", {}),
    ("set_quicktime_tags", "/m/a.mp4", {"QuickTime:Timezone": "+08:00", "QuickTime:Rotation": 90}),
]


def recorded(fn):
    del CALLS[:]
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            result = ["ok", fn()]
        except Exception as e:  # noqa: BLE001
            result = ["raise", type(e).__name__, str(e)]
    return result, [list(c) for c in CALLS]


if __name__ == "__main__":
    handler = X.MetadataHandler()
    out = {"copies": [], "reads": [], "writes": []}
    for name, meta, src, dest, tz, custom in COPIES:
        META.clear()
        META.update(meta)
        result, calls = recorded(lambda: handler.copy_all(Path(src), Path(dest), force_tz_mins=tz, custom_tags=custom))
        out["copies"].append({"name": name, "meta": meta, "src": src, "dest": dest, "force_tz_mins": tz, "custom_tags": custom,
                              "result": result[0], "calls": calls})
    for name, meta, tags in READS:
        META.clear()
        META.update(meta)
        if tags is None:
            result, calls = recorded(lambda: handler.get_metadata(Path("/m/a.mp4")))
        else:
            result, calls = recorded(lambda: handler.get_tags(Path("/m/a.mp4"), tags))
        out["reads"].append({"name": name, "meta": meta, "tags": tags, "result": result, "calls": calls})
    for kind, path, tags in WRITES:
        result, calls = recorded(lambda: getattr(handler, kind)(Path(path), tags))
        out["writes"].append({"kind": kind, "path": path, "tags": tags, "result": result[0], "calls": calls})
    json.dump(out, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")
