# Image writing reference

What Pillow (with libjpeg-turbo) writes for the two JPEG saves of the
Python app's photo path (`cli_main.py`: `save(qtables=…, subsampling=…,
optimize=True)` with a source JPEG's own tables, and `quality=100` without
any), and what it reads from a JPEG (`img.quantization`,
`JpegImagePlugin.get_sampling`). Needs the Python repo and its venv at
`$PYTHON_REPO`.

| File | Made with | Made | Command |
|---|---|---|---|
| `jpeg_cases.json.gz` | Pillow 13.0.0, libjpeg-turbo (API 6.2) | 2026-11-13 | see the docstring of `tool/python_reference/jpeg_fixture.py` |

Gzip-compressed JSON:

- `cases`: 30 pictures computed in the generator (ramps, noise, flat
  colour, hard edges, a blue-green scene; sizes from 1x1 to 160x106,
  most of them not whole blocks) with the tables and subsampling they
  were saved with and the file Pillow wrote (`rgb`, `jpeg`: base64).
  Tables are as Pillow hands them out, row by row; a file has them in
  zigzag order. Also what Pillow reads back from each file.
- `sources`: four files that are not plain three-component JPEGs (grey,
  CMYK, progressive, 4:1:1) and what Pillow reads from them.

No photo is in here: every picture is made of numbers.
