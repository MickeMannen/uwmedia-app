"""Parity fixture for the Subsurface XML parser (spec §4.1):
parsers/subsurface.py of the Python app, on invented files: the texts of
its own tests (tests/test_subsurface_parsing.py, tests/test_subsurface.py),
odd ones, and two dives written by the app's own Subsurface writer from
invented plans. The file texts are part of the fixture, so the Dart test
parses exactly what Python parsed; every value, name and serial in them is
made up. Also the unit helpers and the tank-name mapping of utils/config.py
(without reading or writing any config.yaml).

The dives are dumped without their `None` fields.

Run from the Python repo's root with its own interpreter and write the
output into this repo (the files are written to a temporary folder; nothing
is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/subsurface_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/dives/subsurface.json
"""
import base64
import contextlib
import json
import sys
import tempfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, ".")

import utils.config as config  # noqa: E402

# No config.yaml of the machine is read: the mapping is set per case.
config.user_config_yaml_path = lambda: Path("/nonexistent/config.yaml")
config.bundled_config_yaml_path = lambda: None
config.ConfigManager._instance = None

from models.dive_plan import DiveProfilePlan, PlannedGas, PlannedWaypoint  # noqa: E402
from parsers.registry import detect_log_format  # noqa: E402
from parsers.subsurface import (  # noqa: E402
    SubsurfaceParser,
    parse_depth_str,
    parse_gas_percent,
    parse_pressure_str,
    parse_temp_str,
    parse_time_str,
)
from parsers.subsurface_writer import write_subsurface  # noqa: E402
from utils.dive_plan_engine import plan_ascent, simulate  # noqa: E402


def ssrf(dives, sites=""):
    return f"""<divelog program='subsurface' version='3'>
<divesites>{sites}</divesites>
<dives>{dives}</dives>
</divelog>
"""


def square(depth="10.0 m", minutes=3, attrs=""):
    rows = [f"<sample time='0:00 min' depth='0.0 m' {attrs}/>"]
    rows += [f"<sample time='{m}:00 min' depth='{depth}' />" for m in range(1, minutes + 1)]
    rows.append(f"<sample time='{minutes + 1}:00 min' depth='0.0 m' />")
    return "".join(rows)


def one(body, attrs="date='2026-01-01' time='10:00:00'"):
    return ssrf(f"<dive {attrs}>{body}</dive>")


def ccr_dive(samples, events="", cylinders=None, dctype="CCR"):
    cylinders = cylinders if cylinders is not None else (
        "<cylinder description='Oxy' o2='100.0%' use='oxygen' />"
        "<cylinder description='Dil' o2='18.0%' he='45.0%' use='diluent' />"
        "<cylinder description='Stage' o2='50.0%' />")
    return ssrf(f"<dive date='2026-01-01' time='10:00:00'>{cylinders}"
                f"<divecomputer model='X' dctype='{dctype}'>{events}{samples}</divecomputer></dive>")


def deco_model(model):
    extradata = f"<extradata key='Deco model' value='{model}' />" if model is not None else ""
    return ssrf("<dive date='2026-01-01' time='10:00:00'><cylinder o2='21.0%' />"
                f"<divecomputer>{extradata}{square('40.0 m', 25)}</divecomputer></dive>")


DECO_AND_SUMMARY_PRESSURE = """<divelog program='subsurface' version='3'>
<dives>
<dive number='1' date='2026-01-01' time='10:00:00' duration='10:00 min'>
  <cylinder size='11.0 l' description='Back gas (air)' start='200.0 bar' end='120.0 bar' />
  <divecomputer model='Test Computer'>
  <sample time='0:00 min' depth='0.0 m' />
  <sample time='5:00 min' depth='30.0 m' stopdepth='6.0 m' stoptime='2:00 min' />
  <sample time='10:00 min' depth='0.0 m' />
  </divecomputer>
</dive>
</dives>
</divelog>
"""


def written_logs(folder):
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
        path = folder / "written.ssrf"
        write_subsurface(plan, samples, path)
        out.append((name, "written.ssrf", path.read_bytes(), None))
    return out


def cases(folder):
    sites = ("<site uuid='aa01' name='Test Reef' gps='12.345600 98.765400' />"
             "<site uuid='aa02' name='No GPS' />")
    units = ("<sample time='0:00 min' depth='0 ft' temp='77.0 F' po2='1.25 bar' />"
             "<sample time='1:00 min' depth='66 ft' />"
             "<sample time='2:00 min' depth='66 ft' temp='299.15 K' po2='n/a' />"
             "<sample depth='99 m' />"
             "<sample time='3:00 min' depth='0 ft' />")
    live = ("<sample time='0:00 min' depth='0.0 m' pressure0='3000 psi' pressure1='200.0 bar' />"
            "<sample time='1:00 min' depth='30.0 m' pressure0='2900 psi' />"
            "<sample time='2:00 min' depth='0.0 m' pressure1='190.0 bar' />")
    live_dive = ("<dive date='2026-01-01' time='10:00:00'>"
                 "<cylinder size='11.1 l' o2='32.0%' description='AL80' start='3000 psi' />"
                 "<cylinder size='12.0 l' o2='0.18' he='0.45' />"
                 "<cylinder o2='50.0%' start='200.0 bar' />"
                 "<divecomputer model='X'><extradata key='Sensor 1' value='0000001' />"
                 f"{live}</divecomputer></dive>")
    loop = ("<sample time='0:00 min' depth='2.0 m' po2='0.70 bar' dc_supplied_ppo2='0.68 bar' />"
            "<sample time='1:00 min' depth='30.0 m' po2='1.30 bar' />"
            "<sample time='2:00 min' depth='20.0 m' po2='1.00 bar' />"
            "<sample time='3:00 min' depth='0.0 m' />")
    al80 = "<cylinder description='AL80' o2='21.0%' /><cylinder description='AL80' o2='50.0%' />"
    out = [
        ("test_dive_metadata_site_and_duration", ssrf(
            f"<dive number='1' divesiteid='aa01' date='2026-01-01' time='09:30:00' duration='5:00 min'>"
            f"<divecomputer model='Shearwater Perdix 2' deviceid='0000000'>{square()}</divecomputer></dive>"
            f"<dive number='2' divesiteid='aa02' date='2026-01-01' time='13:00:00'>"
            f"<divecomputer model='Garmin Descent Mk3i'>{square('20.0 m', 4)}</divecomputer></dive>"
            f"<dive number='3' divesiteid='unknown' date='2026-01-02' time='08:00:00'>"
            f"<divecomputer model='Other'>{square()}</divecomputer></dive>", sites), None),
        *[(f"test_unreadable_site_gps_is_ignored[{gps}]", ssrf(
            f"<dive divesiteid='s1' date='2026-01-01' time='10:00:00'><divecomputer>{square()}</divecomputer></dive>",
            f"<site uuid='s1' name='Somewhere' gps='{gps}' />"), None) for gps in ["north east", "1.0", "1.0 2.0 3.0", "1.5 east"]],
        *[(f"test_dives_without_a_usable_start_are_skipped[{i}]", ssrf(
            f"<dive {attrs}><divecomputer>{square()}</divecomputer></dive>"
            f"<dive date='2026-01-03' time='07:00:00'><divecomputer>{square('8.0 m')}</divecomputer></dive>"), None)
          for i, attrs in enumerate(["time='10:00:00'", "date='2026-01-01'", "date='01/02/2026' time='10:00:00'",
                                     "date='2026-01-01' time='25:00:00'"])],
        ("test_dives_without_a_dive_computer_or_samples_are_skipped", ssrf(
            "<dive date='2026-01-01' time='10:00:00'><cylinder o2='32.0%' /></dive>"
            "<dive date='2026-01-01' time='11:00:00'><divecomputer model='X' /></dive>"), None),
        ("test_samples_units_temperature_and_po2", one(
            f"<divecomputer model='X'><temperature water='29.0 C' />{units}</divecomputer>"), None),
        ("test_water_temperature_from_the_dive_computer_header", one(
            f"<divecomputer><temperature water='27.5 C' />{square()}</divecomputer>"), None),
        ("test_non_monotonic_trailing_sample_is_dropped", one(
            f"<divecomputer>{square()}<sample time='0:01 min' depth='0.0 m' /></divecomputer>"), None),
        ("test_ndl_tts_gf_battery_and_no_invented_stop", one(
            "<divecomputer><sample time='0:00 min' depth='0.0 m' />"
            "<sample time='1:00 min' depth='15.0 m' ndl='20:00 min' tts='1:30 min' gf='35.5' battery='3.9' />"
            "<sample time='2:00 min' depth='0.0 m' /></divecomputer>"), None),
        ("test_cylinders_live_pressures_and_sensor_names", ssrf(live_dive), None),
        ("the same with the sensor and a cylinder named in the tank configuration", ssrf(live_dive),
         {"0000001": "Left", "2": "Right", "unused": "Left"}),
        ("test_cylinder_description_is_the_tank_key_without_a_sensor", one(
            "<cylinder description='Left' start='200 bar' end='100 bar' />"
            f"<divecomputer>{square(minutes=1)}</divecomputer>"), None),
        *[(f"deco model: {model}", deco_model(model), None)
          for model in [None, "Buhlmann ZHL-16C GF 30/70", "GF 100/100", "GF 20 / 50", "GF 85/40", "VPM-B +3", "GF 39/84 and GF 10/20"]],
        ("test_no_cylinders_recomputes_on_air", one(f"<divecomputer>{square('20.0 m')}</divecomputer>"), None),
        ("test_a_failed_recompute_still_returns_the_dive", one(
            f"<cylinder o2='0' start='200 bar' end='150 bar' /><divecomputer>{square()}</divecomputer>"), None),
        ("test_an_unreadable_gf_or_battery_is_empty_not_fatal", one(
            "<divecomputer model='X'><sample time='0:00 min' depth='0.0 m' />"
            "<sample time='1:00 min' depth='10.0 m' gf='n/a' battery='low' />"
            "<sample time='2:00 min' depth='0.0 m' /></divecomputer>"), None),
        ("test_rebreather_cells_are_held_between_samples", one(
            "<divecomputer model='X' dctype='CCR'>"
            "<sample time='0:00 min' depth='0.0 m' sensor1='0.70 bar' sensor2='0.71 bar' sensor3='0.69 bar' />"
            "<sample time='1:00 min' depth='20.0 m' sensor2='1.30 bar' />"
            "<sample time='2:00 min' depth='0.0 m' /></divecomputer>"), None),
        ("test_rebreather_loop_bailout_setpoint_and_gases", ccr_dive(
            loop, "<event time='2:00 min' type='25' name='gaschange' cylinder='2' />"), None),
        ("test_rebreather_modechange_events_set_the_circuit", ccr_dive(
            "".join(f"<sample time='{m}:00 min' depth='20.0 m' po2='1.20 bar' />" for m in range(4)),
            "<event time='1:00 min' type='8' name='modechange' divemode='OC' />"
            "<event time='2:00 min' type='8' name='modechange' divemode='CCR' />"), None),
        ("test_open_circuit_gas_changes_and_two_cylinders_with_one_name", ccr_dive(
            "".join(f"<sample time='{m}:00 min' depth='10.0 m' />" for m in range(3)),
            "<event time='1:00 min' type='25' name='gaschange' cylinder='1' />", al80, dctype="OC"), None),
        ("tests/test_subsurface.py deco and summary pressure", DECO_AND_SUMMARY_PRESSURE, None),
        ("semi-closed, events out of order and of one second, a switch to oxygen, a zero setpoint, a cylinder out of range", ssrf(
            "<dive date='2026-1-2' time='7:8:9' duration='0:00 min'>"
            "<cylinder description='Dil A' o2='21' use='diluent' start='200 bar' end='150 bar' />"
            "<cylinder description='O2' o2='1.0' use='oxygen' start='x bar' />"
            "<cylinder description='Dil B' o2='10.0%' he='0.7' use='diluent' end='90 bar' />"
            "<cylinder o2='rich' he='' />"
            "<divecomputer model='A Garmin and Shearwater thing' dctype='scr'>"
            "<extradata key='Sensor 3' value='' /><extradata key='Sensor 4' value='abc' /><extradata value='nokey' />"
            "<event time='3:00 min' name='gaschange' cylinder='3' />"
            "<event time='1:00 min' name='gaschange' cylinder='2' />"
            "<event time='1:00 min' name='gaschange' cylinder='1' />"
            "<event time='2:00 min' name='gaschange' cylinder='9' />"
            "<event time='2:30 min' name='gaschange' cylinder='-1' />"
            "<event time='' name='gaschange' cylinder='0' /><event time='0:30 min' name='heading' cylinder='0' />"
            "<sample time='0:00 min' depth='1.0 m' po2='0.00 bar' pressure3='210 bar' />"
            "<sample time='0:00 min' depth='1.5 m' po2='0.70 bar' sensor1='bar' sensor3=' 0.705 bar ' />"
            "<sample time='1:00 min' depth='12 m' dc_supplied_ppo2='1.005 bar' tts='soon' ndl='0:00 min' stopdepth='deep' stoptime='soon' />"
            "<sample time='2:00 min' temp='cold' pressure0='low' pressure2='95 bar' />"
            "<sample time='3:00 min' depth='x m' temp='41 F' ndl='5 min' stoptime='1:00 min' />"
            "<sample time='4:00' depth='0' po2='0.21' />"
            "</divecomputer><divecomputer model='second, ignored'><sample time='0:10 min' depth='99 m' /></divecomputer></dive>"
            "<trip><dive date='2026-01-02' time='12:00:00'><divecomputer><temperature water='x' />"
            "<sample time='0:00 min' depth='3 m' /></divecomputer></dive></trip>"), None),
    ]
    out += [
        ("digits beyond 64 bits in the deco model and in a cylinder index",
         ssrf("<dive date='2026-01-01' time='10:00:00'><cylinder o2='21.0%' /><cylinder o2='50.0%' />"
              "<divecomputer><extradata key='Deco model' value='GF 99999999999999999999/1' />"
              "<event time='2:00 min' name='gaschange' cylinder='99999999999999999999' />"
              f"{square('40.0 m', 25)}</divecomputer></dive>"), None),
        ("an unreadable stop time where nothing is recomputed",
         ssrf("<dive date='2026-01-01' time='10:00:00'><cylinder o2='0%' /><divecomputer>"
              "<sample time='0:00 min' depth='0.0 m' />"
              "<sample time='1:00 min' depth='20.0 m' stopdepth='3.0 m' stoptime='abc' />"
              "<sample time='2:00 min' depth='20.0 m' stopdepth='3.0 m' />"
              "<sample time='3:00 min' depth='0.0 m' /></divecomputer></dive>"), None),
        ("carriage returns in the text and tabs in attribute values",
         ssrf("<dive date='2026-01-01' time='10:00:00' divesiteid='s\t1'>\r\n<cylinder description='AL\t80' o2='21.0%' />\r"
              f"<divecomputer model='Two\r\nlines'>{square()}</divecomputer></dive>",
              "<site uuid='s 1' name='Tabbed' gps='1.0 2.0' />"), None),
    ]
    out = [(name, "dive.ssrf", text.encode("utf-8"), mapping) for name, text, mapping in out]
    out += [
        ("not XML", "dive.ssrf", b"<divelog><dives>", None),
        ("empty file", "dive.ssrf", b"", None),
        ("a namespace on the root: nothing is found", "dive.xml",
         b"<divelog xmlns='urn:x'><dives><dive date='2026-01-01' time='10:00:00'><divecomputer>"
         b"<sample time='0:00 min' depth='1 m' /></divecomputer></dive></dives></divelog>", None),
    ]
    out += written_logs(folder)
    return out


if __name__ == "__main__":
    parsed = []
    cfg = config.get_config()
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        for name, file_name, raw, mapping in cases(folder):
            path = folder / file_name
            path.write_bytes(raw)
            cfg._config = {"tanks": mapping} if mapping else {}
            with contextlib.redirect_stdout(sys.stderr):
                dives = SubsurfaceParser().parse(path)
            parsed.append({
                "name": name,
                "file_name": file_name,
                "bytes_base64": base64.b64encode(raw).decode("ascii"),
                "tank_config": mapping,
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
    cfg._config = {"tanks": {"222": "Left", "111": "Right", "333": "Left"}}
    out = {
        "parse": parsed,
        "parse_time_str": [{"text": t, "expected": parse_time_str(t)} for t in ["45:20 min", "1:02:03", "1.5 min", "30 s", "42", " 7.9 ", "soon", "1:2:3:4", "ab:cd min"]],
        "parse_depth_str": [{"text": t, "expected": parse_depth_str(t)} for t in ["12.5 m", "33 ft", "7", "deep", "abc m", "x ft", " 5 m ", "1e1m", "3 M", "m", "ft", ""]],
        "parse_temp_str": [{"text": t, "expected": parse_temp_str(t)} for t in ["28.5 C", "50 F", "300.15 K", "21", "cold", "x C", "-2 C", "C", ""]],
        "parse_pressure_str": [{"text": t, "expected": parse_pressure_str(t)} for t in ["200.0 bar", "3000 psi", "150", "full", "x bar", "bar", " 7 psi ", ""]],
        "parse_gas_percent": [
            {"text": t, "default": d, "expected": parse_gas_percent(t, d)}
            for t, d in [("32.0%", 21.0), ("0.32", 21.0), ("50", 21.0), (None, 21.0), ("", 0.0), ("rich", 21.0), ("x%", 21.0), ("1", 21.0), ("1.0", 0.0), (" 18 % ", 5.0), ("-3", 9.0), ("%", 4.0)]
        ],
        "tank_config": {
            "tanks": cfg._config["tanks"],
            "map_tank_name": {serial: cfg.map_tank_name(serial) for serial in ["222", "111", "999", ""]},
            "order_tanks": [
                {"keys": keys, "expected": cfg.order_tanks(keys)}
                for keys in [["9", "Right", "5", "Left"], [], ["Left", "Left", "x", "Right", "a"], ["b", "a"]]
            ],
        },
    }
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
