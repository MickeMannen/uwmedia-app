"""Parity fixture for the Subsurface CSV parser and the format detection
(spec §4.1): parsers/subsurface_csv.py and parsers/registry.py of the
Python app, on invented exports. The CSV texts are part of the fixture, so
the Dart test parses exactly what Python parsed; every value in them is
made up, there is no device or personal data.

Run from the Python repo's root with its own interpreter and write the
output into this repo (the files are written to a temporary folder; nothing
is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/subsurface_csv_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/dives/subsurface_csv.json
"""
import base64
import contextlib
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")

from parsers.registry import detect_log_format, parse_log_file  # noqa: E402
from parsers.subsurface import parse_time_str  # noqa: E402
from parsers.subsurface_csv import SubsurfaceCSVParser, is_subsurface_profile_header  # noqa: E402

HEADER = ('"dive number","date","time","sample time (min)","sample depth (m)",'
          '"sample temperature (C)","sample pressure (bar)","sample heartrate"\n')


def long_dive():
    """A 40-minute dive to 32 m with a pressure reading, long enough for the
    SAC window and a ceiling."""
    rows = []
    pressure = 215.0
    for t in range(0, 2401, 20):
        if t <= 120:
            depth = 32.0 * t / 120
        elif t <= 1500:
            depth = 32.0
        elif t <= 2100:
            depth = 32.0 - 27.0 * (t - 1500) / 600
        else:
            depth = max(0.0, 5.0 - 5.0 * (t - 2280) / 120) if t > 2280 else 5.0
        pressure -= 0.9 + depth / 40.0
        temp = "21.5" if t == 0 else "18.0" if t == 400 else ""
        rows.append(f'"12","2026-06-01","09:30:00","{t // 60}:{t % 60:02d}","{depth:.1f}",{temp and chr(34) + temp + chr(34)},"{pressure:.1f}",\n')
    rows.append('"12","2026-06-01","09:30:00","0:01","0.0",,,\n')
    return HEADER + "".join(rows)


CASES = {
    "metric, values carried forward, a stray last sample": HEADER
    + '"5","2026-04-05","08:15:00","0:00","0.0","28.0","210.0","70"\n'
    + '"5","2026-04-05","08:15:00","1:00","12.4",,,\n'
    + '"5","2026-04-05","08:15:00","2:00","18.0","27.0","190.5",""\n'
    + '"5","2026-04-05","08:15:00","3:00","-0.2",,"0",\n'
    + '"5","2026-04-05","08:15:00","0:01","0.0",,,\n',
    "minimal columns in feet, a row without a time":
        '"dive number","date","time","sample time (min)","sample depth (ft)"\n'
        '"1","2026-04-05","10:00:00","0:00","0"\n'
        '"1","2026-04-05","10:00:00","","50"\n'
        '"1","2026-04-05","10:00:00","0:30","33"\n',
    "bad date, no samples, then a good dive": HEADER
    + '"1","05/04/2026","08:00:00","0:10","5",,,\n'
    + '"2","2026-04-05","10:00:00","",,,,\n'
    + '"3","2026-04-05","12:00:00","0:10","7",,,\n',
    "no time column": '"dive number","date","time","sample depth (m)"\n"1","2026-04-05","08:00:00","5"\n',
    "no depth column": '"dive number","date","time","sample time (min)"\n"1","2026-04-05","08:00:00","5"\n',
    "no header": '"1","2026-04-05","08:00:00","5"\n',
    "empty file": "",
    "two dives, feet, Fahrenheit and psi":
        '"dive number","date","time","sample time (min)","sample depth (ft)","sample temperature (F)","sample pressure (psi)","sample heartrate"\n'
        '"1","2026-01-01","09:00:00","0:10","10","50","3000","80"\n'
        '"1","2026-01-01","09:00:00","0:20","20",,,\n'
        '"2","2026-01-01","11:00:00","0:10","5",,,\n',
    "a long dive with a tank: deco values, SAC and gas time": long_dive(),
    "rows of two dives interleaved, CRLF, a quoted comma and line break, loose text": (
        'dive number,date,time,Sample Time,"Sample Depth (m",Sample Temperature,"note, with comma","sample pressure ( BAR )"\r\n'
        '7,2026-2-3,7:05:09,0:05,3.5,11,"a ""quoted""\nline",200.5\r\n'
        '8,2026-02-03,18:00:00, 1:30 ,4,,,\r\n'
        '\r\n'
        '7,2026-2-3,7:05:09,90 s,nan,,x\r\n'
        '7,2026-2-3,7:05:09,2.5min,1_0.5,-4e0,,-5\r\n'
        '7,2026-2-3,7:05:09,2:60,abc,bad,,0\r\n'
        '8,2026-02-03,18:00:00,0:01:31,1e1,+7.,,1.5E2,extra,cells\r\n'
        '8,2026-02-03,18:00:00,1:2:3:4,5,,,\r\n'
        '9,2026-02-30,10:00:00,0:10,5,,,\r\n'
        '10,2026-02-03,10:00:60,0:10,5,,,\r\n'
        '11,2026-02-03 ,10:00:00,0:10,5,,,\r\n'
        '12,2026-02-03,  9:1:2,0:10,5,,,'
    ),
    "a byte order mark, bytes that are not UTF-8, old Mac line ends": None,  # bytes below
}
RAW = {
    "a byte order mark, bytes that are not UTF-8, old Mac line ends": (
        b'\xef\xbb\xbf"dive number","date","time","sample time (min)","sample depth (m)","sample temperature (C)"\r'
        b'"1","2026-03-04","05:06:07","0:10","5.5","1\xff2"\r'
        b'"1","2026-03-04","05:06:07","0:20","6.5","13"\r'
    ),
}


def parse_cases(folder):
    cases = []
    for name, text in CASES.items():
        raw = RAW[name] if text is None else text.encode("utf-8")
        path = folder / "profile.csv"
        path.write_bytes(raw)
        with contextlib.redirect_stdout(sys.stderr):
            # The parser itself, so a table the registry would not send to
            # it is covered too; and through the registry, which tags the
            # dives with the format.
            dives = SubsurfaceCSVParser().parse(path)
            through_registry = parse_log_file(path)
        cases.append({
            "name": name,
            "file_name": path.name,
            "bytes_base64": base64.b64encode(raw).decode("ascii"),
            "format": detect_log_format(path),
            "registry_log_formats": None if through_registry is None else [d.log_format for d in through_registry],
            "dives": [
                {**d.model_dump(mode="json", exclude={"log_path"}), "max_depth_property": d.max_depth} for d in dives
            ],
        })
    return cases


def detect_cases(folder):
    cases = []
    for file_name, raw in [
        ("dive.uddf", b""), ("DIVE.FIT", b"junk"), ("export.ssrf", b""), ("notes.txt", b"sample time sample depth"),
        ("budget.csv", b"a,b,c\n1,2,3\n"), ("dive.xml", b"<divelog program='subsurface' version='3'><dives/></divelog>"),
        ("shearwater.xml", b'<?xml version="1.0" encoding="utf-16"?><dive version="3"><diveLog><number>7</number></diveLog></dive>'),
        ("lower.xml", b"<dive><divelog></divelog></dive>"), ("late.xml", b"<dive>" + b" " * 5000 + b"<diveLog>"),
        ("utf16.xml", "<dive><diveLog>".encode("utf-16")), ("utf16be.xml", b"\xfe\xff" + "<dive><diveLog>".encode("utf-16-be")),
        ("shearwater.csv", b"Dive Number,GF Minimum\n7,40\n"), ("bom.csv", b"\xef\xbb\xbfDive Number,GF Minimum\n"),
        ("spaced.csv", b" Dive Number,GF Minimum\n"), ("second_line.csv", b"x\nDive Number,\n"),
        ("subsurface.csv", HEADER.encode()), ("upper.CSV", b'"Sample Time (min)","Sample Depth (ft)"\r\n1,2'),
        ("half.csv", b'"sample time (min)","depth"\n'), ("empty.csv", b""), ("empty.xml", b""),
        ("form_feed.csv", b"sample time\x0csample depth\n"), ("bad_bytes.csv", b"sample\xff time,sample depth\n"),
        ("archive.ssrf.xml", b"<divelog/>"), (".csv", b"Dive Number,"), ("trailing.csv.", b"Dive Number,"), ("noext", b"Dive Number,"),
    ]:
        path = folder / file_name
        path.write_bytes(raw)
        cases.append({"file_name": file_name, "bytes_base64": base64.b64encode(raw).decode("ascii"), "format": detect_log_format(path)})
    return cases


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        out = {
            "parse": parse_cases(folder),
            "detect": detect_cases(folder),
            "parse_time_str": [
                {"text": text, "expected": parse_time_str(text)}
                for text in ["0:00", "1:30", "01:02:03", " 2:05 ", "90", "90s", "90 s", "1.5min", "2 min", "12.9", "", "abc", "1:xx",
                             "1:2:3:4", "-1:30", "1:-30", "+5", "1_0", "nan", "1e2", "0x10", "7 ", "min", "s", ":", "5:", ":5"]
            ],
            "is_subsurface_profile_header": [
                {"line": line, "expected": is_subsurface_profile_header(line)}
                for line in [HEADER, '"Sample Time (min)","Sample Depth (ft)"', '"sample time (min)","depth"', "Dive Number,Start Date", ""]
            ],
        }
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
