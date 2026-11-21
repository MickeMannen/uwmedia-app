"""Parity fixture for the UDDF parser (spec §4.1): parsers/uddf.py of the
Python app, on invented files: the texts of its own tests
(tests/test_uddf_parsing.py, tests/test_uddf.py), odd ones, and two dives
written by the app's own UDDF writer from invented plans. The file texts
are part of the fixture, so the Dart test parses exactly what Python
parsed; every value, name and serial in them is made up.

The dives are dumped without their `None` fields.

Run from the Python repo's root with its own interpreter and write the
output into this repo (the files are written to a temporary folder; nothing
is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/uddf_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/dives/uddf.json
"""
import base64
import contextlib
import json
import sys
import tempfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, ".")

from models.dive_plan import DiveProfilePlan, PlannedGas, PlannedWaypoint  # noqa: E402
from parsers.registry import detect_log_format  # noqa: E402
from parsers.uddf import UDDFParser  # noqa: E402
from parsers.uddf_writer import write_uddf  # noqa: E402
from utils.dive_plan_engine import plan_ascent, simulate  # noqa: E402

NS = "http://www.streit.cc/uddf/3.2/"
AIR_MIX = '<mix id="air"><name>Air</name><o2>0.21</o2><he>0.0</he></mix>'
TX_MIX = '<mix id="tx"><name>Tx 18/45</name><o2>0.18</o2><he>0.45</he></mix>'


def uddf(dives, mixes=AIR_MIX, extra="", ns=NS):
    xmlns = f' xmlns="{ns}"' if ns else ""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<uddf{xmlns} version="3.2.3">
  <generator><name>Test</name><manufacturer id="m"><name>Acme Diving</name></manufacturer></generator>
  <diver><owner id="o"><equipment><divecomputer id="dc"><name>Acme One</name><serialnumber>0000000</serialnumber></divecomputer></equipment></owner></diver>
  <gasdefinitions>{mixes}</gasdefinitions>
  {extra}
  <profiledata><repetitiongroup id="rg">{dives}</repetitiongroup></profiledata>
</uddf>
"""


def dive(waypoints, when="<datetime>2026-01-01T10:00:00</datetime>", tz=""):
    return f"""<dive id="d"><informationbeforedive>{when}</informationbeforedive>{tz}
<samples>{waypoints}</samples></dive>"""


def wp(t, depth, extra=""):
    return f"<waypoint><divetime>{t}</divetime><depth>{depth}</depth>{extra}</waypoint>"


def square(depth, minutes, extra_first='<switchmix ref="air"/>'):
    wps = [wp(0, 0, extra_first)]
    wps += [wp(60 * m, depth) for m in range(1, minutes + 1)]
    wps.append(wp(60 * minutes + 60, 0))
    return "".join(wps)


def gf(low, high):
    return (f"<decomodel><buehlmann id='b'><gradientfactorlow>{low}</gradientfactorlow>"
            f"<gradientfactorhigh>{high}</gradientfactorhigh></buehlmann></decomodel>")


def shearwater_app(text):
    return text.replace("<name>Test</name>", "<name>Shearwater Cloud Desktop</name>", 1)


SENSORS = '<rebreather id="r">' + "".join(f'<o2sensor id="c{n}"/>' for n in range(1, 7)) + "</rebreather>"


def cells_dive(tag, extra_first=""):
    readings = "".join(f'<{tag} ref="c{n}">{v}</{tag}>' for n, v in
                       zip(range(1, 7), (128000, 131000, 130000, 127000, 131000, 130000)))
    return dive(wp(0, 0, '<divemode type="closedcircuit"/><setpo2 setby="computer">130000</setpo2>' + extra_first)
                + wp(60, 20, readings) + wp(120, 20) + wp(180, 0))


MULTI_TANK = """<?xml version="1.0" encoding="utf-8"?>
<uddf xmlns="http://www.streit.cc/uddf/3.2/" version="3.2.3">
  <gasdefinitions>
    <mix id="OC1:21/00">
      <name>Air</name>
      <o2>0.21</o2>
      <he>0.0</he>
    </mix>
  </gasdefinitions>
  <profiledata>
    <repetitiongroup>
      <dive>
        <informationbeforedive>
          <datetime>2026-01-01T10:00:00Z</datetime>
        </informationbeforedive>
        <samples>
          <waypoint>
            <divetime>0</divetime>
            <depth>15.0</depth>
            <switchmix ref="OC1:21/00"/>
            <tankpressure ref="T1">15000000</tankpressure>
            <tankpressure ref="T2">14500000</tankpressure>
          </waypoint>
        </samples>
      </dive>
    </repetitiongroup>
  </profiledata>
</uddf>
"""

DECOSTOP_AND_DIVEMODE = """<?xml version="1.0" encoding="utf-8"?>
<uddf xmlns="http://www.streit.cc/uddf/3.2/" version="3.2.3">
  <gasdefinitions>
    <mix id="OC1:21/00">
      <name>Air</name>
      <o2>0.21</o2>
      <he>0.0</he>
    </mix>
  </gasdefinitions>
  <profiledata>
    <repetitiongroup>
      <dive>
        <informationbeforedive>
          <datetime>2026-01-01T10:00:00Z</datetime>
        </informationbeforedive>
        <samples>
          <waypoint>
            <divetime>0</divetime>
            <depth>18.0</depth>
            <switchmix ref="OC1:21/00"/>
            <divemode type="closedcircuit"/>
            <decostop kind="mandatory" decodepth="6" duration="120"/>
          </waypoint>
          <waypoint>
            <divetime>10</divetime>
            <depth>18.0</depth>
          </waypoint>
        </samples>
      </dive>
    </repetitiongroup>
  </profiledata>
</uddf>
"""


def written_logs(folder):
    """Two dives through the app's own UDDF writer, as its Dive Profile
    Builder would save them: open circuit with a deco gas, and a rebreather
    dive with a bailout (the plans of tests/conftest.py, with a deeper open
    circuit dive so that stops are logged)."""
    start = datetime(2026, 5, 2, 10, 0)
    oc = DiveProfilePlan(
        name="Synthetic test dive", dive_type="oc", gf_low=40, gf_high=85, sac_lpm=15, water_temp_c=28.0,
        computer="Shearwater Perdix 2", start_time=start,
        gases=[PlannedGas(id="Air", gas_type="air", o2_percent=21.0, start_pressure_bar=200),
               PlannedGas(id="EAN50", gas_type="nitrox", o2_percent=50.0, start_pressure_bar=200)],
        waypoints=[PlannedWaypoint(runtime_sec=180, depth_m=38.0, gas_id="Air"),
                   PlannedWaypoint(runtime_sec=25 * 60, depth_m=38.0, gas_id="Air")])
    ascent, _, _ = plan_ascent(oc)
    oc.waypoints.extend(ascent)
    ccr = DiveProfilePlan(
        name="Synthetic CCR dive", dive_type="ccr", gf_low=40, gf_high=85, water_temp_c=24.0,
        computer="Shearwater Petrel 3", start_time=start,
        gases=[PlannedGas(id="Dil", gas_type="trimix", o2_percent=18.0, he_percent=45.0, diluent=True, tank_ref="T1", tank_size_l=3.0),
               PlannedGas(id="EAN50", gas_type="nitrox", o2_percent=50.0, tank_ref="T2", tank_size_l=7.0)],
        waypoints=[PlannedWaypoint(runtime_sec=180, depth_m=40.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=1200, depth_m=40.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=1500, depth_m=15.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=1800, depth_m=6.0, gas_id="EAN50", gas_auto=False),
                   PlannedWaypoint(runtime_sec=2400, depth_m=6.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=2500, depth_m=1.0, gas_id="Dil", gas_auto=False),
                   PlannedWaypoint(runtime_sec=2560, depth_m=0.0, gas_id="Dil", gas_auto=False)])
    out = []
    for name, plan in [("written by the app: open circuit with a deco gas", oc), ("written by the app: rebreather with a bailout", ccr)]:
        samples, _ = simulate(plan, resolution_sec=20)
        path = folder / "written.uddf"
        write_uddf(plan, samples, path)
        out.append((name, "written.uddf", path.read_bytes()))
    return out


def cases(folder):
    legacy = "<date><year>2025</year><month>7</month><day>9</day></date><time><hour>14</hour><minute>30</minute></time>"
    logged = ("<nodecotime>1200</nodecotime><tts>90</tts><gradientfactor>42.5</gradientfactor>"
              "<batterychargecondition>87</batterychargecondition><calculatedpo2>1.234</calculatedpo2>")
    stop = '<decostop kind="mandatory" decodepth="3" duration="60"/>'
    status = (wp(0, 0, '<tankpressure ref="T1">20000000</tankpressure><tankpressure ref="T4">56450000</tankpressure>')
              + wp(60, 10, '<tankpressure ref="T1">19000000</tankpressure><tankpressure ref="T4">0</tankpressure>')
              + wp(120, 0, '<tankpressure ref="T1">18000000</tankpressure><tankpressure ref="T4">15000000</tankpressure>'))
    mixes3 = AIR_MIX + TX_MIX + '<mix id="o2"><name>O2</name><o2>1.0</o2></mix>'
    tankdata = '<tankdata id="T1"><link ref="o2"/></tankdata><tankdata id="T2"><link ref="tx"/></tankdata>'
    rebreather = (wp(0, 0, '<divemode type="closedcircuit"/><switchmix ref="tx"/><setpo2>0.7</setpo2>'
                           '<tankpressure ref="T1">200</tankpressure><tankpressure ref="T2">190</tankpressure>')
                  + wp(60, 30, "<setpo2>130000</setpo2>")
                  + wp(120, 20, '<divemode type="opencircuit"/><switchmix ref="air"/>') + wp(180, 0))
    deco_dive = square(40.0, 25)
    out = [
        ("test_header_metadata_and_basic_samples", uddf(dive(square(12.0, 3)))),
        *[(f"test_datetime_keeps_the_logged_wall_clock_time[{stamp}]", uddf(dive(square(5, 1), when=f"<datetime>{stamp}</datetime>")))
          for stamp in ["2026-03-04T05:06:07Z", "2026-03-04T05:06:07+08:00", "2026-03-04T05:06:07-05:30", "2026-03-04T05:06:07"]],
        ("test_legacy_date_fields_are_used_when_datetime_is_missing_or_bad", uddf(
            dive(square(5, 1), when=legacy) + dive(square(5, 1), when=f"<datetime>not a date</datetime>{legacy}"))),
        *[(f"test_dive_without_a_usable_start_time_is_skipped[{i}]", uddf(
            dive(square(5, 1), when=when) + dive(square(7, 1), when="<datetime>2026-02-02T08:00:00</datetime>")))
          for i, when in enumerate([
              "", "<datetime>garbage</datetime>",
              "<year>2025</year><month>13</month><day>1</day><hour>1</hour><minute>1</minute>",
              "<year>2025</year><month>1</month><day>1</day><hour>1</hour>"])],
        ("test_several_dives_per_file_and_dives_without_samples", uddf(
            dive(square(10, 2), when="<datetime>2026-01-01T09:00:00</datetime>")
            + dive("", when="<datetime>2026-01-01T11:00:00</datetime>")
            + dive(square(20, 3), when="<datetime>2026-01-01T14:00:00</datetime>", tz="<timezone>-300</timezone>"))),
        ("test_temperature_kelvin_and_celsius", uddf(dive(
            wp(0, 0, "<temperature>301.15</temperature>") + wp(60, 5, "<temperature>24.5</temperature>")
            + wp(120, 5, "<temperature>warm</temperature>") + wp(180, 0)))),
        ("test_bad_or_missing_divetime_samples_are_skipped", uddf(dive(
            wp(0, 0) + "<waypoint><depth>99</depth></waypoint>" + wp("soon", 98) + wp("60.7", 6) + wp(120, 0)))),
        ("test_logged_per_sample_values_are_read", uddf(dive(
            wp(0, 0, '<switchmix ref="air"/>') + wp(60, 15, logged) + wp(120, 15) + wp(180, 0)))),
        ("test_logged_cns_wins_over_the_recompute", uddf(dive(
            wp(0, 0, "<cns>37</cns>") + wp(60, 5, "<cns>38</cns>") + wp(120, 0, "<cns>38</cns>")))),
        ("test_po2_persists_and_a_bad_value_keeps_the_last_one", uddf(dive(
            wp(0, 0, "<calculatedpo2>1.3</calculatedpo2>") + wp(60, 10)
            + wp(120, 10, "<calculatedpo2>n/a</calculatedpo2>") + wp(180, 10, "<calculatedpo2>0.7</calculatedpo2>")))),
        ("test_divemode_as_text", uddf(dive(wp(0, 0, "<divemode>opencircuit</divemode>") + wp(60, 5) + wp(120, 0)))),
        ("test_decostop_with_bad_attributes_falls_back_to_the_recompute", uddf(dive(
            wp(0, 0, '<switchmix ref="air"/>') + wp(60, 18, '<decostop kind="mandatory" decodepth="deep" duration="long"/>')
            + wp(120, 18) + wp(180, 0)))),
        ("test_a_file_that_logs_stops_gets_direct_ascent_tts_where_it_logs_none", uddf(dive(
            wp(0, 0, '<switchmix ref="air"/>') + wp(60, 9, stop) + wp(120, 9) + wp(180, 0)))),
        ("test_tank_pressures_pascal_bar_bad_and_unreferenced", uddf(dive(
            wp(0, 0, '<switchmix ref="tx"/><tankpressure ref="T1">20000000</tankpressure>'
                     '<tankpressure ref="T2">199.5</tankpressure><tankpressure ref="T3">AI off</tankpressure>')
            + wp(60, 30, "<tankpressure>18000000</tankpressure>") + wp(120, 0)), mixes=AIR_MIX + TX_MIX)),
        ("test_tank_gas_defaults_to_air_before_any_switch", uddf(dive(
            wp(0, 0, '<tankpressure ref="T1">200</tankpressure>') + wp(60, 5) + wp(120, 0)))),
        ("test_mix_defaults_name_and_fractions", uddf(dive(
            wp(0, 0, '<switchmix ref="m1"/><tankpressure ref="T1">200</tankpressure>')
            + wp(60, 5, '<switchmix ref="m2"/><tankpressure ref="T1">190</tankpressure>') + wp(120, 0)),
            mixes='<mix id="m1"></mix><mix id="m2"><o2>0.32</o2></mix>')),
        ("test_no_gas_definitions_recomputes_on_air", uddf(dive(square(20, 3, extra_first="")), mixes="")),
        ("test_a_failed_recompute_still_returns_the_dive", uddf(
            dive(square(10, 2, extra_first='<switchmix ref="bad"/>')), mixes='<mix id="bad"><name>Bad</name><o2>0</o2></mix>')),
        ("gradient factors: none", uddf(dive(deco_dive))),
        *[(f"gradient factors: {low}/{high}", uddf(dive(deco_dive), extra=gf(low, high)))
          for low, high in [(30, 70), (100, 100), (20, 50), ("abc", "70"), ("80", "40"), ("0", "70"), ("30", "120"), ("39.5", "84.5")]],
        ("test_not_xml_returns_no_dives", "<uddf><unclosed>"),
        ("test_an_unreadable_number_is_skipped_not_fatal", uddf(dive(
            wp(0, 0, '<switchmix ref="air"/>') + wp(60, 10, "<nodecotime>x</nodecotime><cns>x</cns>")
            + wp(120, "deep") + wp(180, 10, "<tts>?</tts><gradientfactor>n/a</gradientfactor>"
                                            "<batterychargecondition>low</batterychargecondition>")
            + wp(240, 0)))),
        ("test_shearwater_app_status_and_zero_pressures_are_no_reading", shearwater_app(uddf(dive(status)))),
        ("another program's zero pressure is kept", uddf(dive(status))),
        ("test_po2_in_pascal_or_bar", uddf(dive(
            wp(0, 0, "<calculatedpo2>70000.0</calculatedpo2>") + wp(60, 10, "<calculatedpo2>1.2</calculatedpo2>") + wp(120, 0)))),
        ("test_measured_cells_and_the_loop_po2", uddf(cells_dive("measuredpo2"), extra=SENSORS)),
        ("test_apd_ppo2_refs_are_the_first_controllers_cells", uddf(cells_dive("ppo2"), extra=SENSORS)),
        ("test_rebreather_setpoint_diluent_and_a_tanks_own_mix", uddf(
            f'<dive id="d"><informationbeforedive><datetime>2026-01-01T10:00:00</datetime></informationbeforedive>'
            f'{tankdata}<samples>{rebreather}</samples></dive>', mixes=mixes3)),
        ("tests/test_uddf.py multi tank", MULTI_TANK),
        ("tests/test_uddf.py decostop and divemode", DECOSTOP_AND_DIVEMODE),
        ("no namespace, CDATA, comments, a mix without an id, cells without sensors, no depth", uddf(
            dive(
                wp(0, "<![CDATA[1.5]]>", "<tankpressure>210</tankpressure><temperature> 280.5 </temperature>")
                + "<waypoint><divetime>30.9</divetime><measuredpo2 ref='x'>0.71</measuredpo2><measuredpo2>0.72</measuredpo2>"
                  "<ppo2>9</ppo2><ppo2 ref='y'>73000</ppo2><ppo2 ref='z'>0.99</ppo2><divemode type='semiclosedcircuit'>ignored</divemode>"
                  "<tankpressure ref=''>5000</tankpressure><tankpressure ref='T9'>5000.5</tankpressure></waypoint>"
                + wp(60, "1<!-- c -->2", "<setpo2>1.005</setpo2><nodecotime>-0.9</nodecotime><cns>12.9</cns><tts>1e2</tts>")
                + wp(90, 3, "<divemode><x>open</x>circuit</divemode><calculatedpo2>10</calculatedpo2>")
                + wp(-5, 4) + wp(150, 2, "<decostop duration='90.9'/>") + wp(151, 2, "<decostop decodepth=' 4.5 '/>"),
                when="<datetime>2026-12-31T23:59:59.123456789+02</datetime>"),
            mixes="<mix><name></name><o2>0.5</o2></mix><mix id='late'><name>Late</name><he> 0.1 </he></mix>", ns=None)),
        ("dates: date only, basic format, space separator, fraction, whitespace around, month 0", uddf(
            dive(square(3, 1), when="<datetime>2026-07-08</datetime>")
            + dive(square(4, 1), when="<datetime>20260708T091011</datetime>")
            + dive(square(5, 1), when="<datetime>2026-07-08 09:10</datetime>")
            + dive(square(6, 1), when="<datetime>2026-07-08T09:10:11,5Z</datetime>")
            + dive(square(7, 1), when="<datetime> 2026-07-08T09:10:11 </datetime><year> 2024 </year><month>02</month><day>29</day><hour>0</hour><minute>5</minute>")
            + dive(square(8, 1), when="<year>2025</year><month>0</month><day>1</day><hour>1</hour><minute>1</minute>")
            + dive(square(9, 1), when="<year>2025</year><month>2</month><day>29</day><hour>1</hour><minute>1</minute>")
            + dive(square(10, 1), when="<year>2025</year><month>2</month><day>2.0</day><hour>1</hour><minute>1</minute>")
            + dive(square(11, 1), when="<datetime>2026-07-08T25:00:00</datetime>"))),
        ("names in document order, a nested dive, the first generator without a name", (
            "<uddf><generator><manufacturer><name>Outer maker</name></manufacturer></generator>"
            "<generator><name> Shearwater CLOUD mobile </name></generator>"
            "<a><divecomputer><b><divecomputer><name>Inner</name></divecomputer></b><name>Outer</name></divecomputer></a>"
            "<decomodel><x><gradientfactorlow>35</gradientfactorlow></x></decomodel><gradientfactorhigh>99</gradientfactorhigh>"
            "<decomodel><gradientfactorhigh>75</gradientfactorhigh></decomodel>"
            "<dive><datetime>2026-01-01T10:00:00</datetime><waypoint><divetime>0</divetime><depth>5</depth>"
            "<tankpressure>0</tankpressure><tankpressure>56260000</tankpressure><tankpressure>56250000</tankpressure></waypoint>"
            "<dive><datetime>2027-01-01T10:00:00</datetime><waypoint><divetime>7</divetime><depth>6</depth></waypoint></dive></dive>"
            "</uddf>")),
    ]
    out += [
        ("a mix with neither a name nor an id that is listed but never breathed",
         uddf(dive(square(30, 20)), mixes=AIR_MIX + "<mix><o2>0.5</o2></mix>")),
    ]
    out = [(name, "dive.uddf", text.encode("utf-8")) for name, text in out]
    out += [
        ("Windows-1252 with a euro sign and CRLF line ends", "dive.uddf",
         uddf(dive(square(5, 1))).replace('encoding="utf-8"', 'encoding="windows-1252"')
         .replace("Acme One", "P\u00e9rdix \u20ac\u201cq\u201d\nline two").replace("\n", "\r\n").encode("cp1252")),
        ("UTF-16 with a byte order mark", "dive.uddf", uddf(dive(square(5, 1))).replace('encoding="utf-8"', 'encoding="utf-16"').encode("utf-16")),
        ("Latin-1 with a name outside ASCII", "dive.uddf", uddf(dive(square(5, 1))).replace('encoding="utf-8"', 'encoding="iso-8859-1"').replace("Acme One", "Dykdator åäö").encode("latin-1")),
        ("UTF-8 byte order mark", "dive.uddf", b"\xef\xbb\xbf" + uddf(dive(square(5, 1))).encode()),
        ("bytes that are not UTF-8", "dive.uddf", uddf(dive(square(5, 1))).encode().replace(b"Acme One", b"Acme \xff")),
        ("empty file", "dive.uddf", b""),
    ]
    out += written_logs(folder)
    return out


if __name__ == "__main__":
    parsed = []
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        for name, file_name, raw in cases(folder):
            path = folder / file_name
            path.write_bytes(raw)
            with contextlib.redirect_stdout(sys.stderr):
                dives = UDDFParser().parse(path)
            parsed.append({
                "name": name,
                "file_name": file_name,
                "bytes_base64": base64.b64encode(raw).decode("ascii"),
                "format": detect_log_format(path),
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
            })
    json.dump({"parse": parsed}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
