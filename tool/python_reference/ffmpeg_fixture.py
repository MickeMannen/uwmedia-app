"""Parity fixture for the ffmpeg command lines and the HUD layer logic of
the desktop engine (spec §2): ffmpeg/ffmpeg_class.py (encoder choice,
quality flags, the convert and passthrough commands, how ffprobe's answers
are read), ffmpeg/color.py (which frames are sampled, the lut3d and
sendcmd filter, input and output arguments, the two colour commands),
ffmpeg/hud_layers.py (segments, the alpha matte, the layer canvas, the
concat list, the overlay filter graph), ffmpeg/overlay_output.py (the
frame sink's commands) and utils/progress_lines.py.

No ffmpeg, ffprobe or OpenCV capture runs: the probes answer with canned
values and the command that would be run is recorded. Temporary files (the
sendcmd file, layer PNGs) go to a temporary folder that is removed again;
paths in the output have it as /WORK.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/ffmpeg_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/engine/ffmpeg_cases.json.gz
"""
import base64
import contextlib
import io
import json
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, ".")

import ffmpeg.color as color  # noqa: E402
import ffmpeg.ffmpeg_class as ffc  # noqa: E402
import ffmpeg.hud_layers as layers  # noqa: E402
from ffmpeg.overlay_output import FORMATS, FrameSink  # noqa: E402
from utils import progress_lines  # noqa: E402
from utils.dummy_telemetry import build_dummy_dive  # noqa: E402

FFMPEG = Path("/opt/tools/ffmpeg")


def quiet(fn, *a, **kw):
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*a, **kw)


def tool(os_type="Darwin", hw_accel=True, debug=False, nvenc=False, probe=None):
    """An FfmpegClass that runs nothing: probes answer from `probe`, the
    command handed to run_command is kept in .ran."""
    t = ffc.FfmpegClass.__new__(ffc.FfmpegClass)
    t.hw_accel, t.debug, t.os_type = hw_accel, debug, os_type
    t.executable_path, t.ffprobe_path = FFMPEG, Path("/opt/tools/ffprobe")
    probe = {"duration": 12.5, "dimensions": (3840, 2160), "bitrate": 45000000, "frames": 375, "pix_fmt": "yuv420p",
             "hw_decodable": True, **(probe or {})}
    t.nvenc_available = lambda: nvenc
    t.get_video_duration = lambda p: probe["duration"]
    t.get_video_dimensions = lambda p: probe["dimensions"]

    def bitrate(p):
        if probe["bitrate"] is None:
            raise RuntimeError("no bitrate")
        return probe["bitrate"]
    t.get_video_bitrate = bitrate
    t.get_video_frame_count = lambda p: probe["frames"]
    t.get_video_pix_fmt = lambda p: probe["pix_fmt"]
    t.hw_decodable = lambda p: probe["hw_decodable"]
    t.ran = []
    t.run_command = lambda args, duration=None, progress_label=None, progress_range=(0.0, 100.0): t.ran.append(
        {"args": list(args), "duration": duration, "label": progress_label, "range": list(progress_range)})
    return t


SYSTEMS = [("Darwin", True, False), ("Darwin", False, False), ("Windows", True, True), ("Windows", True, False),
           ("Windows", False, True), ("Linux", True, False), ("Linux", False, False)]


def encoder_cases():
    out = []
    for os_type, hw, nvenc in SYSTEMS:
        t = tool(os_type, hw, nvenc=nvenc)
        out.append({"os": os_type, "hw_accel": hw, "nvenc": nvenc, "encoder": t.get_encoder(), "quality_args": t.quality_args()})
    return out


def process_video_cases():
    out = []
    taken = datetime(2026, 5, 2, 10, 6, 59, 123456)
    variants = [
        {}, {"tz_offset_mins": 480}, {"tz_offset_mins": -210}, {"tz_offset_mins": 0}, {"tz_offset_mins": 345},
        {"target_resolution": (1920, 1080), "bitrate": "24M"}, {"target_resolution": (854, 480), "bitrate": "7M", "tz_offset_mins": 60},
        {"bitrate": "12M"}, {"color_correct": True}, {"color_correct": True, "tz_offset_mins": -5}, {"target_resolution": (640, 360)},
    ]
    for os_type, hw, nvenc in SYSTEMS[:4]:
        for kwargs in variants:
            for bitrate in (45000000, None):
                t = tool(os_type, hw, nvenc=nvenc, probe={"bitrate": bitrate})
                quiet(t.process_video, Path("/media/in put/C0012.MP4"), Path("/media/out/C0012 1080p.mp4"), taken, **kwargs)
                out.append({"os": os_type, "hw_accel": hw, "nvenc": nvenc, "source_bitrate": bitrate,
                            "kwargs": {k: list(v) if isinstance(v, tuple) else v for k, v in kwargs.items()}, "ran": t.ran})
    return out


def probe_reading_cases():
    """What each probe makes of ffprobe's answer: the command it runs and
    its result for canned outputs."""
    real = subprocess.run, subprocess.check_output
    out = []

    def probing(method, outputs):
        """`outputs`: stdout per ffprobe call, in order; an Exception raises."""
        calls = []
        queue = list(outputs)

        def answer(cmd):
            calls.append([str(c) for c in cmd])
            value = queue.pop(0)
            if isinstance(value, Exception):
                raise value
            return value

        subprocess.run = lambda cmd, **kw: SimpleNamespace(stdout=answer(cmd), returncode=0)
        subprocess.check_output = lambda cmd, **kw: answer(cmd).encode()
        t = ffc.FfmpegClass.__new__(ffc.FfmpegClass)
        t.hw_accel, t.debug, t.os_type = True, False, "Darwin"
        t.executable_path, t.ffprobe_path = FFMPEG, Path("/opt/tools/ffprobe")
        try:
            result = getattr(t, method)(Path("/media/a b.mp4"))
            result = list(result) if method == "get_video_dimensions" else result
            result = ["ok", result]
        except Exception as e:  # noqa: BLE001
            result = ["raise", type(e).__name__]
        finally:
            subprocess.run, subprocess.check_output = real
        out.append({"method": method, "outputs": [None if isinstance(o, Exception) else o for o in outputs], "calls": calls, "result": result})

    fail = subprocess.CalledProcessError(1, "ffprobe")
    for text in ("12.480000\n", "0.04\n", "N/A\n", "", "abc"):
        probing("get_video_duration", [text])
    for outputs in (["45000000\n"], ["N/A\n", "38000000\n"], ["\n", "N/A\n"], ["", ""], ["1.5e6\n", "x"], [" 800 \n"]):
        probing("get_video_bitrate", outputs)
    for text in ("3840x2160\n", "1920x1080", "", "1920", "ax b", "1920x1080x3\n"):
        probing("get_video_dimensions", [text])
    for outputs in (["375\n"], ["N/A\n", "12.5\n"], ["", "0.99"], [fail, "2.0"], ["N/A", "N/A"], ["N/A", fail], ["12.0\n", "3.21"]):
        probing("get_video_frame_count", outputs)
    for text in ("yuv420p\n", "yuv422p10le\n", ""):
        probing("get_video_pix_fmt", [text])
    for text in ("codec_name=h264\npix_fmt=yuv420p\n", "codec_name=h264\npix_fmt=yuv422p10le\n", "codec_name=hevc\npix_fmt=yuv420p10le\n",
                 "codec_name=h264\npix_fmt=yuvj420p\n", "codec_name=h264\npix_fmt=nv12\n", "codec_name=h264\n", "pix_fmt=yuv444p\n", "",
                 "garbage", fail):
        probing("hw_decodable", [text])
    return out


def pix_fmt_10bit_cases():
    out = []
    for pix_fmt in ("yuv420p", "yuv420p10le", "yuv422p10le", "p010le", "yuv444p12le", "gbrp", "yuvj420p", "", "nv12", "yuv420p16le", "gray10le"):
        engine = color.ColorCorrectionEngine.__new__(color.ColorCorrectionEngine)
        engine.ffmpeg_tool = tool(probe={"pix_fmt": pix_fmt})
        cap = SimpleNamespace(get=lambda prop: 0, release=lambda: None)
        engine._open_video_capture = lambda p: cap
        out.append([pix_fmt, quiet(engine._probe, Path("x.mp4"))[4]])
    return out


def engine_for(t):
    engine = color.ColorCorrectionEngine.__new__(color.ColorCorrectionEngine)
    engine.ffmpeg_tool = t
    engine.generate_3d_lut = lambda filt: None
    engine.write_cube_file = lambda lut, path: None
    return engine


def sample_frame_cases():
    out = []
    for fps, total in [(30.0, 375), (25.0, 251), (59.94, 600), (0.4, 50), (30.0, 0), (30.0, 1), (30.0, 60), (30.0, 61), (23.976, 1000),
                       (120.0, 239), (1.0, 5), (0.0, 10)]:
        asked = []
        cap = SimpleNamespace(set=lambda prop, idx: asked.append(int(idx)), read=lambda: (False, None), release=lambda: None)
        engine = engine_for(tool())
        engine._open_video_capture = lambda p: cap
        _, _, n = quiet(engine._analyze, Path("x.mp4"), fps, total, color._FileProgress(None))
        out.append({"fps": fps, "total_frames": total, "frames": asked, "n": n})
    return out


def lut_filter_cases(work):
    """Which filters count as distinct, and the -vf value and sendcmd text."""
    out = []
    base = np.linspace(0.1, 1.1, 11)
    runs = {
        "one": [base], "same": [base, base + 0.005, base + 0.0099], "two": [base, base + 0.02, base + 0.021],
        "back_and_forth": [base, base + 0.02, base, base + 0.02], "drift": [base + 0.004 * i for i in range(8)],
        "one_value": [base, base + np.eye(11)[3] * 0.0101, base + np.eye(11)[3] * 0.0100],
    }
    for name, filters in runs.items():
        for fps in (30.0, 59.94):
            lut_dir = work / f"lut_{name}_{fps}"
            lut_dir.mkdir()
            indices = [int(i * fps * 2) for i in range(len(filters))]
            # float32, as get_filter_matrix gives them
            matrices = np.array(filters, dtype=np.float32)
            vf = quiet(engine_for(tool())._build_lut3d_filter, indices, matrices, fps, lut_dir)
            sendcmd = lut_dir / "sendcmd.txt"
            out.append({"name": name, "fps": fps, "indices": indices, "filters": matrices.tolist(),
                        "vf": vf.replace(str(work), "/WORK"), "lut_dir": "/WORK/" + lut_dir.name,
                        "sendcmd": sendcmd.read_text().replace(str(work), "/WORK") if sendcmd.exists() else None})
    return out


def color_arg_cases():
    out = []
    taken = datetime(2026, 5, 2, 10, 6, 59)
    for os_type, hw, nvenc in SYSTEMS:
        for debug in (False, True):
            for decodable in (True, False):
                t = tool(os_type, hw, debug=debug, nvenc=nvenc, probe={"hw_decodable": decodable})
                out.append({"what": "input", "os": os_type, "hw_accel": hw, "nvenc": nvenc, "debug": debug, "hw_decodable": decodable,
                            "args": engine_for(t)._input_args(Path("/media/a.mp4"))})
        for tz in (None, 480, -210):
            for ten_bit in (False, True):
                for bitrate in (45000000, None):
                    t = tool(os_type, hw, nvenc=nvenc, probe={"bitrate": bitrate})
                    out.append({"what": "output", "os": os_type, "hw_accel": hw, "nvenc": nvenc, "tz": tz, "ten_bit": ten_bit,
                                "source_bitrate": bitrate,
                                "args": engine_for(t)._output_args(Path("/media/a.mp4"), Path("/out/a color.mp4"), taken, tz, ten_bit)})
    return out


def overlay_graph_cases():
    out = []
    for color_vf in (None, "lut3d=file='/WORK/lut_0000.cube':interp=trilinear", ""):
        for positions in ([], [(16, 603)], [(0, 0), (1200, 40), (3000, 1900)]):
            for ten_bit in (False, True):
                graph, label = layers.overlay_filter_complex(color_vf, positions, ten_bit)
                out.append({"color_vf": color_vf, "positions": [list(p) for p in positions], "ten_bit": ten_bit, "graph": graph, "label": label})
    return out


def segment_cases():
    out = []
    dive = build_dummy_dive("single_tank")
    for start, fps, frames in [(datetime(2026, 1, 1, 10, 0, 0), 30.0, 900), (datetime(2026, 1, 1, 10, 5, 3, 500000), 25.0, 500),
                               (datetime(2026, 1, 1, 9, 59, 50), 59.94, 1500), (datetime(2026, 1, 1, 10, 31, 55), 30.0, 600),
                               (datetime(2026, 1, 1, 10, 10, 4, 999000), 23.976, 480), (datetime(2026, 1, 1, 10, 0, 0), 30.0, 0)]:
        segments = layers.hud_segments(dive, start, fps, frames)
        out.append({"start": start.isoformat(), "fps": fps, "frames": frames,
                    "segments": [[wp.time_since_start, first, n] for wp, first, n in segments]})
    return out


def matte_cases():
    rng = np.random.default_rng(7)
    out = []
    for shape in ((3, 4), (16, 9)):
        black = rng.integers(0, 256, shape + (3,), dtype=np.uint8)
        white = np.maximum(black, rng.integers(0, 256, shape + (3,), dtype=np.uint8))
        black[0, 0], white[0, 0] = (0, 0, 0), (255, 255, 255)   # nothing drawn
        black[0, 1], white[0, 1] = (10, 200, 30), (10, 200, 30)  # opaque
        black[0, 2], white[0, 2] = (0, 0, 0), (0, 0, 0)          # opaque black
        black[1, 0], white[1, 0] = (255, 255, 255), (255, 255, 255)
        black[1, 1], white[1, 1] = (100, 50, 25), (228, 178, 153)  # about half
        black[1, 2], white[1, 2] = (200, 10, 10), (190, 10, 10)    # white darker than black: clipped
        out.append({"shape": list(shape), "black": base64.b64encode(black.tobytes()).decode(),
                    "white": base64.b64encode(white.tobytes()).decode(),
                    "bgra": base64.b64encode(layers.matte(black, white).tobytes()).decode()})
    return out


def canvas_cases():
    """HudLayer's cropped canvas per layout, frame and pad."""
    out = []
    layouts = [
        ({"design_width": 1920, "hud_skin": {"type": "image", "ref_offset_x": 16.0, "ref_offset_y": 603.0}}, (461, 346)),
        ({"design_width": 1920, "hud_skin": {"type": "image", "ref_offset_x": 1500.5, "ref_offset_y": 12.25}}, (300, 400)),
        ({"hud_skin": {"type": "shape", "width": 230, "height": 150, "ref_offset_x": 1676.4, "ref_offset_y": 918.1}}, None),
        ({"design_width": 1280, "hud_skin": {"type": "shape", "ref_offset_x": -40, "ref_offset_y": -500}}, None),
        ({"design_width": 1920, "hud_skin": {"ref_offset_x": 5000.0, "ref_offset_y": 0.0}}, (10, 10)),
        ({"design_width": 1920, "hud_skin": {"type": "image"}}, None),
        ({"design_width": 1000.5, "hud_skin": {"type": "shape", "width": 333.3, "height": 77.7, "ref_offset_x": 101.1, "ref_offset_y": 55.5}}, None),
    ]
    for layout, skin_shape in layouts:
        for frame in ((1920, 1080), (3840, 2160), (2704, 1520), (1280, 720)):
            skin = np.zeros(skin_shape + (4,), dtype=np.uint8) if skin_shape else None
            layer = layers.HudLayer(json.loads(json.dumps(layout)), skin, frame[0], frame[1], resolved=True)
            steps = []
            for _ in range(4):
                canvas = layer.canvas_layout
                steps.append({"region": list(layer.region), "design_width": canvas.get("design_width"),
                              "ref_offset_x": canvas.get("hud_skin", {}).get("ref_offset_x"),
                              "ref_offset_y": canvas.get("hud_skin", {}).get("ref_offset_y"), "pad_index": layer._pad_index})
                layer.widen()
            out.append({"layout": layout, "skin_size": list(skin_shape[::-1]) if skin_shape else None, "frame": list(frame), "steps": steps})
    plain = layers.HudLayer({"hud_skin": {"ref_offset_x": 5}}, np.zeros((10, 10, 4), dtype=np.uint8), 1920, 1080, resolved=False)
    out.append({"layout": {"hud_skin": {"ref_offset_x": 5}}, "skin_size": [10, 10], "frame": [1920, 1080], "not_resolved": True,
                "steps": [{"region": list(plain.region), "design_width": None, "ref_offset_x": 5, "ref_offset_y": None, "pad_index": 0}]})
    widths = [[d, c, r, layers._canvas_design_width(d, c, r)] for d, c, r in
              [(1920.0, 474, 1.0), (1920.0, 948, 2.0), (1920.0, 667, 1.4083333333333334), (1000.5, 401, 1.9190404797601199),
               (1920.0, 301, 0.6666666666666666), (1280.0, 1, 3.0), (1921.3, 777, 0.9993233748503617)]]
    edges = []
    for region in ((0, 0, 8, 6), (2, 0, 8, 6), (0, 1, 8, 6), (0, 0, 7, 6), (0, 0, 8, 5), (1, 1, 7, 5)):
        for where in ("none", "left", "top", "right", "bottom", "middle"):
            x0, y0, x1, y1 = region
            alpha = np.zeros((y1 - y0, x1 - x0, 4), dtype=np.uint8)
            {"none": lambda: None, "left": lambda: alpha.__setitem__((2, 0, 3), 9), "top": lambda: alpha.__setitem__((0, 3, 3), 9),
             "right": lambda: alpha.__setitem__((1, -1, 3), 9), "bottom": lambda: alpha.__setitem__((-1, 2, 3), 9),
             "middle": lambda: alpha.__setitem__((2, 2, 3), 9)}[where]()
            layer = SimpleNamespace(region=region, frame_w=8, frame_h=6)
            edges.append([list(region), where, layers.HudLayer._reaches_canvas_edge(layer, alpha)])
    return {"layers": out, "design_widths": widths, "edges": edges, "pads": list(layers.CANVAS_PADS)}


def concat_cases(work):
    """write_layer_stream with a layer that answers with given pictures:
    which PNGs are written and the concat list."""
    out = []

    def picture(value):
        img = np.zeros((4, 6, 4), dtype=np.uint8)
        if value:
            img[1, 2] = (value, value, value, 255)
        return img
    runs = {
        "changing": ([1, 1, 2, 2, 2, 3], [30, 30, 15, 45, 30, 60]),
        "nothing_drawn": ([0, 0, 0], [30, 30, 30]),
        "appears_late": ([0, 0, 5, 5, 0, 5], [10, 20, 30, 40, 50, 60]),
        "one": ([7], [375]),
        "none": ([], []),
    }
    for name, (values, frames) in runs.items():
        for fps in (30.0, 29.97, 50.0):
            folder = work / f"it's {name} {fps}"
            folder.mkdir()
            queue = [picture(v) for v in values]
            layer = SimpleNamespace(region=(16, 603, 362, 1064), render=lambda wp, wps: queue.pop(0))
            segments = [(None, sum(frames[:i]), n) for i, n in enumerate(frames)]
            seen = []
            stream = layers.write_layer_stream(layer, segments, [], fps, folder, 3, seen.append)
            case = {"name": name, "fps": fps, "values": values, "frames": frames, "folder": "/WORK/" + folder.name, "seen": seen,
                    "pngs": sorted(p.name for p in folder.glob("*.png"))}
            if stream is None:
                case["stream"] = None
            else:
                path, x, y = stream
                case["stream"] = [str(path).replace(str(work), "/WORK"), x, y]
                case["concat"] = path.read_text().replace(str(work), "/WORK")
            out.append(case)
    return out


def sink_cases():
    out = []
    for os_type, hw, nvenc in SYSTEMS:
        for fmt in FORMATS:
            if fmt == "png":
                continue
            for debug in (False, True):
                sink = FrameSink(fmt, tool(os_type, hw, nvenc=nvenc), 1920, 1080, 30.0, Path("/out/dive overlay.mov"), debug=debug)
                out.append({"os": os_type, "hw_accel": hw, "nvenc": nvenc, "format": fmt, "debug": debug, "command": sink.command()})
    sink = FrameSink("prores", tool(), 3840, 2160, 59.94, Path("/out/x.mov"))
    out.append({"os": "Darwin", "hw_accel": True, "nvenc": False, "format": "prores", "debug": False, "command": sink.command(),
                "size": [3840, 2160], "fps": 59.94, "target": "/out/x.mov"})
    return out


def progress_cases():
    buffer_runs = []
    for chunks in ([b"UWMEDIA_PROGRESS 1/3 start a.mp4\nUWMEDIA_FF", b"MPEG_PROGRESS 20.0 a.mp4\r\n", b"last line"],
                   [b"\xc3", b"\xa5 \xe2\x82", b"\xac\n", b"\xff\n"], [b"", b"\n\n", b"a\rb\r\n"], [b"no newline at all"], []):
        buf = progress_lines.LineBuffer()
        buffer_runs.append({"chunks": [base64.b64encode(c).decode() for c in chunks], "fed": [buf.feed(c) for c in chunks],
                            "flushed": buf.flush(), "flushed_again": buf.flush()})
    return {
        "analysis_end": color.ANALYSIS_PROGRESS_END, "hud_end": color.HUD_PROGRESS_END, "sample_seconds": color.SAMPLE_SECONDS,
        "buffers": buffer_runs,
        "finished": [[code, crashed, progress_lines.finished_text(code, crashed)] for code in (0, 1, 13, -9) for crashed in (False, True)],
    }


def run_command_progress_cases():
    """The UWMEDIA_FFMPEG_PROGRESS lines run_command prints for a stream of
    ffmpeg progress lines."""
    real_popen = subprocess.Popen
    out = []
    streams = {
        "steady": [f"out_time_us={int(i * 0.25e6)}\n" for i in range(1, 51)] + ["progress=end\n"],
        "coarse": ["frame=1\n", "out_time_us=4000000\n", "out_time_us=N/A\n", "out_time_us=9990000\n"],
        "past_the_end": ["out_time_us=20000000\n", "out_time_us=30000000\n"],
        "nothing": ["progress=continue\n"],
        "tiny_steps": [f"out_time_us={i * 50000}\n" for i in range(1, 60)],
    }
    for name, lines in streams.items():
        for duration, label, rng in ((12.5, None, (0.0, 100.0)), (12.5, "C0012.MP4", (10.0, 100.0)), (12.5, "a b.mp4", (14.0, 100.0)),
                                     (None, "x.mp4", (0.0, 100.0)), (0.0, "x.mp4", (0.0, 100.0))):
            queue = list(lines)
            process = SimpleNamespace(stderr=SimpleNamespace(readline=lambda: queue.pop(0) if queue else ""),
                                      poll=lambda: None if queue else 0, wait=lambda: 0, returncode=0, kill=lambda: None)
            subprocess.Popen = lambda cmd, **kw: process
            t = ffc.FfmpegClass.__new__(ffc.FfmpegClass)
            t.hw_accel, t.debug, t.os_type, t.executable_path = True, False, "Darwin", FFMPEG
            printed = io.StringIO()
            try:
                with contextlib.redirect_stdout(printed):
                    t.run_command(["-i", "x"], duration=duration, progress_label=label, progress_range=rng)
            finally:
                subprocess.Popen = real_popen
            out.append({"name": name, "lines": lines, "duration": duration, "label": label, "range": list(rng),
                        "printed": printed.getvalue().splitlines()})
    return out


def full_command_cases(work):
    """process_video_lut and process_video (no dive: no layers) with the
    analysis stood in for: the whole ffmpeg command."""
    out = []
    taken = datetime(2026, 5, 2, 10, 6, 59)
    base = np.linspace(0.1, 1.1, 11)
    for os_type, hw, nvenc in SYSTEMS[:4]:
        for pix_fmt, filters in (("yuv420p", [base]), ("yuv422p10le", [base, base + 0.5])):
            for method in ("process_video_lut", "process_video", "process_video_no_color"):
                t = tool(os_type, hw, nvenc=nvenc, probe={"pix_fmt": pix_fmt})
                engine = engine_for(t)
                cap = SimpleNamespace(get=lambda prop: {5: 25.0, 3: 1920, 4: 1080, 7: 250}.get(prop, 0), release=lambda: None)
                engine._open_video_capture = lambda p: cap
                engine._analyze = lambda p, fps, total, progress: ([0, 50][:len(filters)], np.array(filters), len(filters))
                folder = work / f"full{len(out)}"
                folder.mkdir()
                color.app_temp_dir = lambda prefix: folder
                if method == "process_video_lut":
                    quiet(engine.process_video_lut, Path("/media/C0012.MP4"), Path("/out/C0012_color.mp4"), taken, 480)
                else:
                    quiet(engine.process_video, Path("/media/C0012.MP4"), Path("/out/C0012_color.mp4"), taken, tz_offset_mins=480,
                          color_correct=method == "process_video")
                ran = json.loads(json.dumps(t.ran).replace(str(folder), "/WORK"))
                out.append({"os": os_type, "hw_accel": hw, "nvenc": nvenc, "pix_fmt": pix_fmt, "method": method, "filters": len(filters),
                            "ran": ran})
    return out


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp_name:
        work = Path(tmp_name).resolve()
        out = {
            "ffmpeg": str(FFMPEG), "encoders": encoder_cases(), "process_video": process_video_cases(), "probes": probe_reading_cases(),
            "ten_bit": pix_fmt_10bit_cases(), "sample_frames": sample_frame_cases(), "lut_filters": lut_filter_cases(work),
            "color_args": color_arg_cases(), "overlay_graphs": overlay_graph_cases(), "segments": segment_cases(), "mattes": matte_cases(),
            "canvas": canvas_cases(), "concat": concat_cases(work), "sinks": sink_cases(), "progress": progress_cases(),
            "run_progress": run_command_progress_cases(), "full_commands": full_command_cases(work),
        }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
