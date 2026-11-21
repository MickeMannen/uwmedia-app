"""Parity fixture for the Shearwater Cloud XML/CSV parser (spec §4.1):
parsers/shearwater.py of the Python app, on invented exports. The export
texts are part of the fixture, so the Dart test parses exactly what Python
parsed; every value, name and serial in them is made up.

The port runs one shared deco pass with the UDDF parser's rules (spec
§10.16), which fills SAC and gas time only when the log has no SAC at all.
parsers/deco_pass.py, which this parser calls, fills them on every sample
that lacks one. So that the fixture is an oracle for the port, the dives
are parsed with that one call replaced by the UDDF rule (`_uddf_rule_fill`
below, the condition copied from parsers/uddf.py); nothing else differs.
`surf_gf` and the dive's `gf_low`/`gf_high`, which Python leaves empty for
this format, are not in the oracle and are checked in the Dart test.

Run from the Python repo's root with its own interpreter and write the
output into this repo (the files are written to a temporary folder; nothing
is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/shearwater_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/dives/shearwater.json
"""
import base64
import contextlib
import json
import math
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")

import parsers.deco_pass as deco_pass  # noqa: E402
from parsers.registry import detect_log_format  # noqa: E402
from parsers.shearwater import ShearwaterParser, _divemode, read_tables  # noqa: E402
from utils.gas_consumption import fill_sac_and_gtr  # noqa: E402

NAME = "Perdix 2[00000000]#7 2026-02-03 10-20-30"


def _uddf_rule_fill(waypoints):
    if not any(getattr(wp, "pressure_sac", None) is not None for wp in waypoints):
        fill_sac_and_gtr(waypoints)


def record(ms, depth, **extra):
    fields = {"currentTime": ms, "currentDepth": depth, "fractionO2": "0.32", "fractionHe": "0", **extra}
    return "<diveLogRecord>" + "".join(f"<{k}>{v}</{k}>" for k, v in fields.items()) + "</diveLogRecord>"


def xml(records, start="2/3/2026 10:20:30 AM", imperial="false", gf=("40", "85")):
    return f"""<?xml version="1.0" encoding="utf-16"?>
<dive version="3">
  <diveLog>
    <number>7</number><gfMin>{gf[0]}</gfMin><gfMax>{gf[1]}</gfMax>
    <imperialUnits>{imperial}</imperialUnits><startDate>{start}</startDate>
    <computerSerial>00000000</computerSerial><product>11</product><emptyTag />
    <diveLogRecords>{records}</diveLogRecords>
  </diveLog>
</dive>
"""


def long_xml(logged_sac):
    """A 35-minute dive to 40 m on EAN28 with a deco gas, one transmitter,
    stops logged near the end; with or without the computer's own SAC."""
    records = []
    psi = 3100.0
    for t in range(0, 2101, 20):
        if t <= 150:
            depth = 40.0 * t / 150
        elif t <= 1200:
            depth = 40.0
        elif t <= 1700:
            depth = 40.0 - 34.0 * (t - 1200) / 500
        elif t <= 2000:
            depth = 6.0
        else:
            depth = max(0.0, 6.0 - 6.0 * (t - 2000) / 100)
        psi -= 12.0 + depth / 2.0
        on_deco_gas = t >= 1500
        extra = {
            "fractionO2": "0.5" if on_deco_gas else "0.28",
            "waterTemp": 14 if t > 300 else 19,
            "tank0pressurePSI": f"{psi:.0f}",
            "tank1pressurePSI": "8188" if t % 400 == 0 else "2950",
            "averagePPO2": f"{(1 + depth / 10) * (0.5 if on_deco_gas else 0.28):.4f}",
            "currentCircuitSetting": "OC/BO",
            "batteryVoltage": "1.48",
        }
        if 900 <= t <= 2000:
            stop = 6 if t < 1900 else 3
            extra.update(firstStopDepth=stop, firstStopTime=max(1, (2000 - t) // 120), currentNdl=0, ttsMins=max(1, (2100 - t) // 60))
        else:
            extra.update(currentNdl=max(0, 12 - t // 60) if t < 900 else 99, ttsMins=max(0, math.ceil(depth / 9)))
        if logged_sac:
            extra.update(sac="Not Diving" if t < 120 else f"{15.5 + (t % 70) / 50:.2f}", gasTime="N/A" if t < 120 else 30 + (t // 100) % 9)
        records.append(record(t * 1000, f"{depth:.1f}", **extra))
    return xml("".join(records), gf=("30", "70"))


def cases():
    values = (
        record(0, 0, currentNdl=0, waterTemp=29, tank0pressurePSI=3000, tank1pressurePSI="AI is off",
               currentCircuitSetting="OC/BO", sac="Not Diving", gasTime="N/A", averagePPO2="0.32")
        + record(60000, 18.5, currentNdl=25, ttsMins=2, waterTemp=27, tank0pressurePSI=2900,
                 sac="16.0", gasTime=40, averagePPO2="0.9123", batteryVoltage="1.52")
        + record(120000, 21, firstStopDepth=6, firstStopTime=2, currentNdl=0, ttsMins=5)
        + record(180000, 0, currentNdl=99))
    imperial = (record(0, 0, waterTemp=86) + record(10000, 66, firstStopDepth=20, firstStopTime=1, waterTemp=77)
                + record(20000, 0))
    repeated = (record(0, 0) + record(10000, 5) + record(10400, 9)
                + "<diveLogRecord><currentDepth>12</currentDepth></diveLogRecord>"
                + record(5000, 15) + record(20000, 3))
    status = (record(0, "0", tank0pressurePSI="3000", tank3pressurePSI="8188")
              + record(2000, "5", tank0pressurePSI="2990", tank3pressurePSI="2500")
              + record(4000, "5", tank0pressurePSI="8160", tank1pressurePSI="8159.9", tank2pressurePSI="-1", tank3pressurePSI="0"))
    odd = (
        "<diveLogRecord><currentTime>500</currentTime><currentDepth>1</currentDepth><currentDepth>2</currentDepth>"
        "<fractionO2>0</fractionO2><fractionHe>0.35</fractionHe><currentCircuitSetting> cc/bo </currentCircuitSetting>"
        "<waterTemp><![CDATA[11.5]]></waterTemp><averagePPO2>1.005</averagePPO2></diveLogRecord>"
        "<nested><diveLogRecord><currentTime>2500</currentTime><currentDepth>3<!-- c -->4</currentDepth>"
        "<fractionO2>0.2149</fractionO2><fractionHe>0.3551</fractionHe><averagePPO2>0.125</averagePPO2>"
        "<currentNdl>0.5</currentNdl><ttsMins>1.99</ttsMins><gasTime>2.999</gasTime><sac>0</sac></diveLogRecord></nested>"
        "<diveLogRecord><currentTime>3500</currentTime><currentDepth>&#52;.5</currentDepth>"
        "<fractionO2>0.215</fractionO2><fractionHe>0.355</fractionHe><firstStopDepth>3</firstStopDepth><currentNdl>0</currentNdl>"
        "<sac>-3</sac><currentCircuitSetting>2</currentCircuitSetting></diveLogRecord>"
        "<diveLogRecord><currentTime>5500</currentTime><currentDepth>x</currentDepth><firstStopTime>3</firstStopTime></diveLogRecord>"
    )
    csv_gas = (
        "Computer Firmware Version,Start Date,Computer Firmware Version,GF Minimum,GF Maximum\n"
        "64,2026-02-03 10:20:30,99,40,85\n"
        "Time (sec),Depth,Fraction O2,Fraction He,Current Circuit Mode,Tank 2 pressure (PSI),Average PPO2\n"
        "0,0,0.18,0.45,1,2000,0.18\n"
        "\n"
        "10,30,0.18,0.45,0,1900,1.2\n"
        "20,0,,,,0,\n"
    )
    csv_imperial = (
        "Dive Number,GF Minimum,GF Maximum,Imperial Units,Start Date,Product\n"
        "1,30,70,True,1/2/2025 10:00:00 AM,Teric\n"
        "Time (sec),Depth,First Stop Depth,Time To Surface (min),Current NDL,Water Temp,Fraction O2,Fraction He,Tank 1 pressure (PSI)\n"
        "0,0,0,0,0,68,0.32,0,3000\n"
        "10,33,0,1,50,50,0.32,0,AI is off\n"
    )

    def start_case(start, file_name):
        return (f"start date {start!r} in {file_name}.csv", f"{file_name}.csv",
                f"Dive Number,Start Date\n7,{start}\nTime (sec),Depth\n0,0\n10,5\n".encode())

    out = [
        ("XML values", f"{NAME}.xml", xml(values).encode()),
        ("XML imperial units", f"{NAME}.xml", xml(imperial, imperial="True").encode()),
        ("XML really in UTF-16", f"{NAME}.xml", xml(record(0, 0) + record(10000, 5) + record(20000, 0)).encode("utf-16")),
        ("XML in UTF-16 big endian", f"{NAME}.xml", b"\xfe\xff" + xml(record(0, 0) + record(10000, 5)).encode("utf-16-be")),
        ("XML in UTF-16 with an odd byte count", f"{NAME}.xml", xml(record(0, 0)).encode("utf-16") + b"\x00"),
        ("XML with a UTF-8 byte order mark", f"{NAME}.xml", b"\xef\xbb\xbf" + xml(record(0, 0) + record(10000, 5)).encode()),
        ("XML repeated, timeless and backwards records", f"{NAME}.xml", xml(repeated).encode()),
        ("XML without a dive log", "a.xml", b"<dive version='3'><other /></dive>"),
        ("XML with an empty root", "b.xml", b"<dive version='3'></dive>"),
        ("XML without records", f"{NAME}.xml", xml("").encode()),
        ("XML records without a time", f"{NAME}.xml", xml("<diveLogRecord><currentDepth>3</currentDepth></diveLogRecord>").encode()),
        ("XML broken", f"{NAME}.xml", b"<dive><diveLog>"),
        ("XML transmitter status words", f"{NAME}.xml", xml(status).encode()),
        ("XML repeated tags, nested records, CDATA, comments, rounding, bad GF", "Petrel 3 [0]x 2026-2-3 1-2-3.XML", xml(odd, start="", gf=("85", "40")).encode()),
        ("XML gradient factors with a half", f"{NAME}.xml", xml(record(0, 0) + record(10000, 5), gf=("30.5", "84.5")).encode()),
        ("XML long dive with the computer's SAC", f"{NAME}.xml", long_xml(True).encode()),
        ("XML long dive without SAC", f"{NAME}.xml", long_xml(False).encode()),
        ("XML no start date, none in the file name", "export.xml", xml(record(0, 0), start="").encode()),
        ("CSV repeated header column, blank row, gas", f"{NAME}.csv", csv_gas.encode()),
        ("CSV imperial units", "Teric[ABC]#1 2025-01-02 10-00-00.csv", csv_imperial.encode()),
        ("CSV day/month locale", "Perdix 2[X]#7 2025-10-03 09-15-00.csv", b"Dive Number,Start Date\n7,03/10/2025 09:15:00\nTime (sec),Depth\n0,0\n10,5\n"),
        start_case("03/02/2026 10:20:30", NAME), start_case("02/03/2026 10:20:30", NAME), start_case("03.02.2026 10:20:30", NAME),
        start_case("2026-02-03T10:20:30", NAME), start_case("03/02/2026 10:20:30", "export"), start_case("05/06/2026 10:20:30", NAME),
        start_case("", NAME), start_case("yesterday", NAME), start_case("2/3/2026 12:05:06 am", NAME), start_case("13/02/2026 1:02:03 PM", NAME),
        start_case(" 2026-2-3  7:8:9 ", "export"),
        ("CSV no start date anywhere", "export.csv", b"Dive Number,Start Date\n7,\nTime (sec),Depth\n0,0\n10,5\n"),
        ("CSV device from the Product column", "export 2026-02-03 10-20-30.csv", b"Product,Start Date\nPetrel 3,2026-02-03 10:20:30\nTime (sec),Depth\n0,0\n10,5\n"),
        ("CSV no device anywhere", "export 2026-02-03 10-20-31.csv", b"Start Date\n2026-02-03 10:20:31\nTime (sec),Depth\n0,0\n10,5\n"),
        ("CSV empty", f"{NAME}.csv", b""),
        ("CSV header line only", f"{NAME}.csv", b"Dive Number,Start Date\n"),
        ("CSV header without a sample table", f"{NAME}.csv", b"Dive Number,Start Date\n7,2026-02-03 10:20:30\n"),
        ("CSV sample header without samples", f"{NAME}.csv", b"Dive Number,Start Date\n7,2026-02-03 10:20:30\nTime (sec),Depth\n"),
        ("CSV byte order mark, CRLF, quoted cells, half seconds", f"{NAME}.csv",
         b'\xef\xbb\xbfDive Number,"Start Date",Imperial Units\r\n7,"2026-02-03 10:20:30", TRUE \r\n'
         b'"Time (sec)",Depth,"Water Temp",Time (sec)\r\n0.5,10,50,99\r\n1.5,20,"59"\r\n2.5,30\r\n\r\n3.49,40,x\r\n'),
    ]
    return out


def gf_percent(path):
    try:
        header, _ = read_tables(path)
    except Exception:  # noqa: BLE001
        return None
    gf = deco_pass.parse_gf(header.get("GF Minimum"), header.get("GF Maximum"))
    return None if gf is None else [int(round(g * 100)) for g in gf]


def dump_tables(path):
    try:
        header, rows = read_tables(path)
    except Exception as e:  # noqa: BLE001 - the parser turns any failure into "no dive"
        return {"error": type(e).__name__}
    return {"header": header, "rows": [{"seconds": r.get("Time (sec)"), "fields": {k: v for k, v in r.items() if k != "Time (sec)"}} for r in rows]}


if __name__ == "__main__":
    deco_pass.fill_sac_and_gtr = _uddf_rule_fill
    parsed = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, file_name, raw in cases():
            path = Path(tmp) / file_name
            path.write_bytes(raw)
            with contextlib.redirect_stdout(sys.stderr):
                dives = ShearwaterParser().parse(path)
            # The tables of the long dives would only repeat their records.
            tables = None if "long dive" in name else dump_tables(path)
            parsed.append({
                "name": name,
                "file_name": file_name,
                "bytes_base64": base64.b64encode(raw).decode("ascii"),
                "format": detect_log_format(path),
                "tables": tables,
                # What the port keeps on the dive and Python drops: the
                # file's gradient factors in percent, rounded as the UDDF
                # parser rounds its own.
                "gf_percent": gf_percent(path),
                # Without the fields that are None, to keep the file small.
                "dives": [
                    {**d.model_dump(mode="json", exclude={"log_path"}, exclude_none=True), "max_depth_property": d.max_depth}
                    for d in dives
                ],
            })
    out = {
        "parse": parsed,
        "divemode": [
            {"value": v, "expected": _divemode(v)}
            for v in ["OC/BO", "oc/bo", "CC/BO", "SC/BO", "1", "0", "", None, "2", "Gauge", " cc ", "BO", "10", "01", "ccoc", "x oc x"]
        ],
    }
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
