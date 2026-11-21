#!/usr/bin/env python3
"""Times the desktop's ffmpeg commands against the native engine (uwbench)
on the same clips and the same work, and writes the numbers as JSON.

    python3 bench.py <work folder> <results.json> <clip> [<clip> ...]

The ffmpeg commands are the app's own (lib/core/engine/ffmpeg_commands.dart)
with hardware acceleration on, as the app has it by default on a Mac. The
work folder gets the outputs (large); nothing is written beside the clips.
"""

import json
import os
import struct
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
UWBENCH = os.path.join(HERE, "build", "uwbench")
LUT = 64
STEP_SECONDS = 2

TAGGING = [
    "-map_metadata", "0", "-movflags", "+faststart+use_metadata_tags",
    "-tag:v", "hvc1", "-color_primaries", "1", "-color_trc", "1",
    "-colorspace", "1",
]
DATE = ["-metadata", "creation_time=2026-05-02T11:06:58+0200"]


def run(args, stdout=subprocess.DEVNULL):
    """Runs a command; its wall and CPU seconds and its largest memory."""
    started = time.monotonic()
    process = subprocess.Popen(args, stdout=stdout, stderr=subprocess.PIPE)
    errors = process.stderr.read()
    _, status, usage = os.wait4(process.pid, 0)
    process.returncode = os.waitstatus_to_exitcode(status)
    wall = time.monotonic() - started
    if process.returncode != 0:
        return {"failed": errors.decode(errors="replace")[-600:]}
    return {
        "wall": round(wall, 3),
        "cpu": round(usage.ru_utime + usage.ru_stime, 3),
        "rssMb": round(usage.ru_maxrss / 1048576),
    }


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=codec_name,profile,width,height,pix_fmt,bit_rate,nb_frames,"
         "r_frame_rate:format=duration,size", "-of", "json", path],
        capture_output=True, text=True, check=True).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    num, den = stream["r_frame_rate"].split("/")
    return {
        "codec": stream["codec_name"],
        "profile": stream.get("profile"),
        "width": stream["width"],
        "height": stream["height"],
        "pixFmt": stream["pix_fmt"],
        "bitrate": int(stream.get("bit_rate") or 0),
        "frames": int(stream.get("nb_frames") or 0),
        "fps": int(num) / int(den),
        "seconds": float(data["format"]["duration"]),
        "bytes": int(data["format"]["size"]),
    }


def lut_bytes(k):
    """A 64^3 LUT, red fastest: a warm correction, a little other for each k."""
    red = 1.15 + 0.02 * (k % 8)
    table = bytearray(LUT * LUT * LUT * 3)
    at = 0
    for b in range(LUT):
        for g in range(LUT):
            for r in range(LUT):
                table[at] = min(255, int(r * 255 / 63 * red + 8))
                table[at + 1] = min(255, int(g * 255 / 63 * 0.97))
                table[at + 2] = min(255, int(b * 255 / 63 * 0.88))
                at += 3
    return bytes(table)


def write_cube(path, table):
    with open(path, "w") as out:
        out.write("LUT_3D_SIZE %d\n" % LUT)
        for i in range(0, len(table), 3):
            out.write("%.6f %.6f %.6f\n" % (
                table[i] / 255, table[i + 1] / 255, table[i + 2] / 255))


def write_png(path, width, height, index):
    """A see-through panel with a bar that moves with [index]."""
    bar = 20 + (index * 37) % (width - 80)
    row_plain = bytes([0, 0, 0, 140]) * width
    row_bar = bytearray(row_plain)
    for x in range(bar, bar + 40):
        row_bar[x * 4:x * 4 + 4] = bytes([255, 255, 255, 255])
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += row_bar if height // 3 < y < 2 * height // 3 else row_plain

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(
            ">I", zlib.crc32(body))

    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n")
        out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
        out.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        out.write(chunk(b"IEND", b""))


def prepare(work, seconds, fps):
    """The LUTs and the overlay pictures of a clip of [seconds]."""
    os.makedirs(work, exist_ok=True)
    count = int(seconds / STEP_SECONDS) + 1
    tables = [lut_bytes(k) for k in range(8)]
    write_cube(os.path.join(work, "lut_0000.cube"), tables[0])
    with open(os.path.join(work, "lut_one.bin"), "wb") as out:
        out.write(tables[0])
    with open(os.path.join(work, "lut_all.bin"), "wb") as out:
        for k in range(count):
            out.write(tables[k % 8])
    # ffmpeg's colour tables: the LUT of each step, the last twice.
    with open(os.path.join(work, "lut_tables.raw"), "wb") as out:
        for k in list(range(count)) + [count - 1]:
            out.write(tables[k % 8])
    hud = os.path.join(work, "hud")
    os.makedirs(hud, exist_ok=True)
    pictures = int(seconds) + 1
    lines = ["ffconcat version 1.0"]
    for index in range(pictures):
        name = os.path.join(hud, "hud_%04d.png" % index)
        write_png(name, 800, 400, index)
        lines += ["file '%s'" % name, "duration 1.000000"]
    with open(os.path.join(work, "hud0.ffconcat"), "w") as out:
        out.write("\n".join(lines) + "\n")
    return count


def fade_vf(work, fps):
    step = int(fps * STEP_SECONDS)
    side = 512
    tables = os.path.join(work, "lut_tables.raw").replace(":", "\\:")
    share = "65535*mod(N,%d)/%d" % (step, step)
    return (
        "format=rgb24|rgb48le[lm];"
        "movie=filename='%s':f=rawvideo:"
        "format_opts='video_size=%dx%d\\:pixel_format=rgb24\\:framerate=1',"
        "fps=%d,format=gbrp16le,split[la][lb];"
        "[lb]trim=start_frame=%d,setpts=PTS-STARTPTS[ld];"
        "color=s=16x16:r=%d,format=gbrp16le,"
        "geq=r='%s':g='%s':b='%s',scale=%d:%d:flags=neighbor[lw];"
        "[la][ld][lw]maskedmerge,"
        "settb=1/1000000,setpts=(N-0.5)/(%s*TB),format=rgb48le[lt];"
        "[lm][lt]haldclut=interp=trilinear:shortest=1"
    ) % (tables, side, side, step, step, step, share, share, share, side, side,
         repr(float(fps)))


def cases(clip, info, work, luts):
    """Each case: its name, the ffmpeg command, the native command, the output."""
    ten = "10" in info["pixFmt"]
    hw_decode = info["codec"] == "hevc" or info["pixFmt"] == "yuv420p"
    hw_in = ["-hwaccel", "videotoolbox"] if hw_decode else []
    quiet = ["-y", "-nostats", "-loglevel", "error"]
    rate = info["bitrate"]
    pix = "p010le" if ten else "yuv420p"
    cube = os.path.join(work, "lut_0000.cube").replace(":", "\\:")
    lut_vf = "lut3d=file='%s':interp=trilinear" % cube
    y = info["height"] - 440
    blend = ":format=yuv420p10" if ten else ""

    def out(name, kind):
        return os.path.join(work, "%s_%s.mp4" % (name, kind))

    def color_out(name):
        return ["-b:v", str(rate)] + TAGGING + DATE + [
            "-vcodec", "hevc_videotoolbox", "-pix_fmt", pix, "-acodec", "copy",
            out(name, "ffmpeg")]

    result = []
    result.append(("passthrough",
        ["ffmpeg", "-y", "-loglevel", "error", "-i", clip, "-c", "copy",
         "-map", "0:v", "-map", "0:a?", "-map", "0:s?", "-map_metadata", "0"]
        + DATE + ["-movflags", "+faststart+use_metadata_tags",
                  out("passthrough", "ffmpeg")],
        [UWBENCH, "passthrough", clip, out("passthrough", "native")]))
    result.append(("resize_1080p_hevc",
        ["ffmpeg", "-y", "-loglevel", "error", "-i", clip, "-filter_complex",
         "scale=1920:1080:force_original_aspect_ratio=decrease,"
         "pad=1920:1080:(ow-iw)/2:(oh-ih)/2",
         "-vcodec", "hevc_videotoolbox", "-b:v", "24M"] + TAGGING + DATE
        + ["-acodec", "copy", "-pix_fmt", "yuv420p",
           out("resize_1080p_hevc", "ffmpeg")],
        [UWBENCH, "encode", clip, out("resize_1080p_hevc", "native"),
         "--fit", "1920x1080", "--bitrate", "24000000"]))
    result.append(("share_720p_h264",
        ["ffmpeg", "-y", "-loglevel", "error", "-i", clip, "-filter_complex",
         "scale=1280:720,setsar=1", "-vcodec", "h264_videotoolbox",
         "-b:v", "3000000", "-map_metadata", "0", "-movflags",
         "+faststart+use_metadata_tags", "-color_primaries", "1",
         "-color_trc", "1", "-colorspace", "1"] + DATE
        + ["-acodec", "aac", "-b:a", "128k", "-pix_fmt", "yuv420p",
           out("share_720p_h264", "ffmpeg")],
        [UWBENCH, "encode", clip, out("share_720p_h264", "native"),
         "--fit", "1280x720", "--codec", "h264", "--bitrate", "3000000"]))
    result.append(("color_one_lut",
        ["ffmpeg"] + quiet + hw_in + ["-i", clip, "-vf", lut_vf,
         "-map", "0:v:0", "-map", "0:a?"] + color_out("color_one_lut"),
        [UWBENCH, "encode", clip, out("color_one_lut", "native"),
         "--luts", os.path.join(work, "lut_one.bin"), "--lutCount", "1",
         "--bitrate", str(rate)]))
    result.append(("color_fading_luts",
        ["ffmpeg"] + quiet + hw_in + ["-i", clip, "-vf",
         fade_vf(work, info["fps"]), "-map", "0:v:0", "-map", "0:a?"]
        + color_out("color_fading_luts"),
        [UWBENCH, "encode", clip, out("color_fading_luts", "native"),
         "--luts", os.path.join(work, "lut_all.bin"), "--lutCount", str(luts),
         "--lutStep", str(STEP_SECONDS), "--lutFade", str(STEP_SECONDS),
         "--bitrate", str(rate)]))
    result.append(("color_one_lut_overlay",
        ["ffmpeg"] + quiet + hw_in + ["-i", clip, "-f", "concat", "-safe", "0",
         "-i", os.path.join(work, "hud0.ffconcat"), "-filter_complex",
         "[0:v]%s[v0];[1:v]format=rgba[h1];"
         "[v0][h1]overlay=x=40:y=%d:eof_action=repeat%s[v1]" % (lut_vf, y, blend),
         "-map", "[v1]", "-map", "0:a?"] + color_out("color_one_lut_overlay"),
        [UWBENCH, "encode", clip, out("color_one_lut_overlay", "native"),
         "--luts", os.path.join(work, "lut_one.bin"), "--lutCount", "1",
         "--bitrate", str(rate), "--layer",
         "40,%d,%s,1" % (y, os.path.join(work, "hud"))]))
    return result


def small_runs(clip, info):
    hw_decode = info["codec"] == "hevc" or info["pixFmt"] == "yuv420p"
    hw_in = ["-hwaccel", "videotoolbox"] if hw_decode else []
    return [
        ("probe_one_call",
         ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
          "default=noprint_wrappers=1:nokey=1", clip],
         [UWBENCH, "probe", clip]),
        ("frame_grab_1080p_at_5s",
         ["ffmpeg", "-nostdin", "-loglevel", "error"] + hw_in
         + ["-ss", "5.000000", "-i", clip, "-frames:v", "1", "-vf",
            "scale=in_color_matrix=bt601,format=rgb24,scale=1920:1080:flags=area",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
         [UWBENCH, "frame", clip, "5", "1920", "1080"]),
    ]


def main():
    work_root, results_path = sys.argv[1], sys.argv[2]
    clips = sys.argv[3:]
    results = {"clips": {}}
    for clip in clips:
        name = os.path.basename(clip)
        info = probe(clip)
        work = os.path.join(work_root, os.path.splitext(name)[0])
        luts = prepare(work, info["seconds"], info["fps"])
        entry = {"source": info, "luts": luts, "cases": {}}
        results["clips"][name] = entry
        print("==", name, info, flush=True)
        for case, ffmpeg, native in small_runs(clip, info):
            entry["cases"][case] = {
                "ffmpeg": [run(ffmpeg) for _ in range(5)],
                "native": [run(native) for _ in range(5)],
            }
            print(case, entry["cases"][case], flush=True)
        for case, ffmpeg, native in cases(clip, info, work, luts):
            record = {}
            for kind, args in (("ffmpeg", ffmpeg), ("native", native)):
                runs = []
                for _ in range(2):
                    runs.append(run(args))
                    if "failed" in runs[-1]:
                        break
                record[kind] = runs
                target = os.path.join(work, "%s_%s.mp4" % (case, kind))
                if "failed" not in runs[-1] and os.path.exists(target):
                    try:
                        record[kind + "Output"] = probe(target)
                    except Exception as error:  # noqa: BLE001
                        record[kind + "Output"] = {"unreadable": str(error)}
            entry["cases"][case] = record
            print(case, json.dumps(record), flush=True)
            with open(results_path, "w") as out:
                json.dump(results, out, indent=1)
    with open(results_path, "w") as out:
        json.dump(results, out, indent=1)


if __name__ == "__main__":
    main()
