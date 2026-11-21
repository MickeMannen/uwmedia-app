"""The hinted ink heights of the bundled fonts, as Pillow (FreeType with the
fonts' own hinting) gives them: for every font file, every size from 1 to
MAX_SIZE px and every character of CHARS, how far the ink of that one
character reaches above and below the baseline, in whole pixels.

The port measures text from the font files in pure Dart
(lib/core/hud/ttf_font.dart). Advances, kerning and the left and right of the
ink follow from the font's tables; the top and the bottom depend on the
hinting program inside the font, which the port does not run. This table is
its result, so a text's ink box in the port is the one Pillow gives.

Format of ink_tables.bin (big endian):

    "UWHI2"
    u16 font count, then per font:
        u8 name length, the file name (ASCII)
        u16 max size, u16 character count, u16 row count
        per character: u32 code point, u16 row of its "above", u16 row of
            its "below"
        u32 length of the packed rows, the packed rows
    packed rows: pairs (u8 count, u8 value) run-length coding the rows one
        after the other, each row one byte per size (size 1 first): the
        value's difference from the unhinted estimate, plus 128:
        above - max(0, round(yMax scaled)), below - max(0, round(-yMin scaled))
        (the scaled values as FreeType's FT_MulFix gives them, in 26.6,
        rounded to whole pixels half up; a character without an outline: 0).
        Characters that line up alike share a row.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/font_ink_tables.py \
        $APP_REPO/assets/fonts \
        $APP_REPO/test/fixtures/python_reference/renderer

The second folder gets font_measures.json: Pillow's `getbbox` and `getlength`
of some sixty texts in every font at seventeen sizes, which the port's
reader is tested against (the texts of the renderer fixture only cover two
of the fonts).
"""
import json
import struct
import sys
from pathlib import Path

from PIL import ImageFont, features

MAX_SIZE = 320
# Without the soft hyphen (U+00AD), which HarfBuzz does not draw.
CHARS = [chr(c) for c in range(32, 127)] + [chr(c) for c in range(0xA0, 0x100) if c != 0xAD] + list("–—‘’“”•…↑↓✓")


MEASURE_SIZES = [7, 9, 11, 12, 13, 16, 17, 22, 30, 43, 51, 86, 102, 150, 204, 320, 330]
MEASURE_TEXTS = [
    "0", "1", "8", "00", "12:34", ":34", ".0", "99", "+", "99+", "24.5", "207", "3002", "-- ", "--", "wait", "deco",
    "Nx32", "AIR", "Air", "18/45", "21%", "O2", "CC", "BO", "m", "ft", "BAR", "PSI", "psi/min", "L/min", "\u00b0C", "\u00b0F",
    "NDL", "TTS", "DEPTH", "MAX. DEPTH", "TIME OF DAY", "SAFETY STOP", "DECO STOP", "Complete", "CLEAR", "\u21916m", "6m\u2193 2min",
    "STOP 20ft 3:00", "AV", "To", "Ty", "LT", "P.", "fi", "ff", "ffi", "Confirm", "Warning", "HIGH PPO2", "Low NDL Alert",
    "DESCEND TO 6 m", "You are above your deco ceiling.", "Breathe from Left Tank (Micke01).", "On-Gassing", "03-Mar-20",
    "V\u00e4nster", "H\u00f6ger \u00c5\u00c4\u00d6", "g", "gjpqy", "(Tank_1)", "a b  c", "", " ", "\u00a0x", "\u2713 2:59", "z\u017c",
]


class Face:
    """The few tables of a font file the estimate needs."""

    def __init__(self, data):
        self.data = data
        count = struct.unpack(">H", data[4:6])[0]
        self.tables = {}
        for i in range(count):
            tag, _, offset, _ = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
            self.tables[tag.decode()] = offset
        head = self.tables["head"]
        self.upm = struct.unpack(">H", data[head + 18:head + 20])[0]
        self.long_loca = struct.unpack(">h", data[head + 50:head + 52])[0] != 0
        self.ascender = struct.unpack(">h", data[self.tables["hhea"] + 4:self.tables["hhea"] + 6])[0]
        self.glyphs = struct.unpack(">H", data[self.tables["maxp"] + 4:self.tables["maxp"] + 6])[0]

    def box(self, glyph):
        loca, glyf = self.tables.get("loca"), self.tables.get("glyf")
        if loca is None or glyf is None or glyph >= self.glyphs:
            return None
        if self.long_loca:
            start, end = struct.unpack(">II", self.data[loca + 4 * glyph:loca + 4 * glyph + 8])
        else:
            start, end = (2 * v for v in struct.unpack(">HH", self.data[loca + 2 * glyph:loca + 2 * glyph + 4]))
        if end <= start:
            return None
        return struct.unpack(">hhhh", self.data[glyf + start + 2:glyf + start + 10])


def mul_fix(a, b):
    value = (abs(a) * b + 0x8000) >> 16
    return -value if a < 0 else value


def pack(values):
    out = bytearray()
    i = 0
    while i < len(values):
        j = i
        while j < len(values) and values[j] == values[i] and j - i < 255:
            j += 1
        out += bytes([j - i, values[i]])
        i = j
    return bytes(out)


def table(path):
    data = path.read_bytes()
    face = Face(data)
    above_rows = {ch: bytearray() for ch in CHARS}
    below_rows = {ch: bytearray() for ch in CHARS}
    worst = 0
    for size in range(1, MAX_SIZE + 1):
        font = ImageFont.truetype(str(path), size)
        scale = ((size * 64 << 16) + face.upm // 2) // face.upm
        ascent = (mul_fix(face.ascender, scale) + 63) >> 6
        # Pillow's own ascent must be the estimate's, or the table means nothing.
        assert font.getmetrics()[0] == ascent, (path.name, size, font.getmetrics(), ascent)
        for ch in CHARS:
            _, top, _, bottom = font.getbbox(ch)
            above, below = ascent - top, bottom - ascent
            box = BOXES[path.name].get(ch)
            est_above = max(0, (mul_fix(box[3], scale) + 32) >> 6) if box else 0
            est_below = max(0, (mul_fix(-box[1], scale) + 32) >> 6) if box else 0
            d_above, d_below = above - est_above, below - est_below
            worst = max(worst, abs(d_above), abs(d_below))
            above_rows[ch].append(d_above + 128)
            below_rows[ch].append(d_below + 128)
    rows = {}
    index = []
    for ch in CHARS:
        pair = []
        for row in (bytes(above_rows[ch]), bytes(below_rows[ch])):
            pair.append(rows.setdefault(row, len(rows)))
        index.append((ord(ch), *pair))
    packed = pack(b"".join(rows))
    print(f"{path.name}: {len(CHARS)} characters, {len(rows)} rows, packed {len(packed)} bytes, largest difference {worst}", file=sys.stderr)
    name = path.name.encode("ascii")
    return (bytes([len(name)]) + name + struct.pack(">HHH", MAX_SIZE, len(CHARS), len(rows))
            + b"".join(struct.pack(">IHH", *entry) for entry in index) + struct.pack(">I", len(packed)) + packed)


def cmap(face):
    """{character: glyph} from the font's format 4 or 12 cmap."""
    data = face.data
    start = face.tables["cmap"]
    count = struct.unpack(">H", data[start + 2:start + 4])[0]
    out = {}
    subtables = []
    for i in range(count):
        platform, encoding, offset = struct.unpack(">HHI", data[start + 4 + 8 * i:start + 12 + 8 * i])
        subtables.append((struct.unpack(">H", data[start + offset:start + offset + 2])[0], platform, encoding, start + offset))
    for fmt, platform, encoding, sub in subtables:
        if fmt == 4 and ((platform == 3 and encoding == 1) or platform == 0) and not out:
            seg = struct.unpack(">H", data[sub + 6:sub + 8])[0] // 2
            ends = sub + 14
            starts = ends + 2 * seg + 2
            deltas = starts + 2 * seg
            ranges = deltas + 2 * seg
            for s in range(seg):
                end = struct.unpack(">H", data[ends + 2 * s:ends + 2 * s + 2])[0]
                first = struct.unpack(">H", data[starts + 2 * s:starts + 2 * s + 2])[0]
                delta = struct.unpack(">h", data[deltas + 2 * s:deltas + 2 * s + 2])[0]
                rng = struct.unpack(">H", data[ranges + 2 * s:ranges + 2 * s + 2])[0]
                for c in range(first, min(end, 0xFFFE) + 1):
                    if rng == 0:
                        glyph = (c + delta) & 0xFFFF
                    else:
                        at = ranges + 2 * s + rng + 2 * (c - first)
                        glyph = struct.unpack(">H", data[at:at + 2])[0]
                        glyph = (glyph + delta) & 0xFFFF if glyph else 0
                    if glyph:
                        out[chr(c)] = glyph
    return out


BOXES = {}

if __name__ == "__main__":
    assert features.check("raqm"), "the measurements in the renderer fixture were made with Raqm layout"
    folder = Path(sys.argv[1])
    files = sorted(Path("resources/fonts").glob("*.ttf"))
    for path in files:
        face = Face(path.read_bytes())
        glyphs = cmap(face)
        # HarfBuzz draws a no-break space the font lacks as a space.
        glyphs.setdefault("\u00a0", glyphs.get(" ", 0))
        BOXES[path.name] = {ch: face.box(glyphs.get(ch, 0)) for ch in CHARS}
    out = b"UWHI2" + struct.pack(">H", len(files)) + b"".join(table(path) for path in files)
    (folder / "ink_tables.bin").write_bytes(out)
    print(len(out), "bytes", file=sys.stderr)

    measures = {}
    for path in files:
        for size in MEASURE_SIZES:
            font = ImageFont.truetype(str(path), size)
            measures[f"{path.name}@{size}"] = {text: [list(font.getbbox(text)), font.getlength(text)] for text in MEASURE_TEXTS}
    with open(Path(sys.argv[2]) / "font_measures.json", "w") as f:
        json.dump({"texts": MEASURE_TEXTS, "sizes": MEASURE_SIZES, "measures": measures}, f, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")
