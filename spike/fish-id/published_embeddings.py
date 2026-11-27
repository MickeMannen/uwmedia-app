"""Are the text embeddings Imageomics publishes enough, with no text tower at all?

TreeOfLife-200M's dataset repo holds a matrix of species text embeddings
for BioCLIP 2.5 (3.3 GB) and the labels of its rows (84 MB). This reads
only the matrix's header (its shape) and the labels, and counts what the
list holds of the animals a diver photographs, and how many of the
species in species_sample.tsv are in it. Found 2026-11-25: 794,878
species, but 24 bony fishes and no sea turtles, so the app's own list has
to be embedded with the text tower (fish_id_spike.py, step "text").

    .venv/bin/python published_embeddings.py
"""

import json
import struct
import urllib.request
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
BASE = "https://huggingface.co/datasets/imageomics/TreeOfLife-200M/resolve/main/embeddings/"
MATRIX = BASE + "txt_emb_bioclip-2.5-vith14.npy"
LABELS = BASE + "txt_emb_bioclip-2.5-vith14.json"
OUT = HERE / "out" / "tol"
MINE = HERE / "out" / "bioclip-2.5-vith14"


def fetch(url, start=None, end=None):
    request = urllib.request.Request(url)
    if start is not None:
        request.add_header("Range", f"bytes={start}-{end}")
    with urllib.request.urlopen(request, timeout=120) as answer:
        return answer.read()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    head = fetch(MATRIX, 0, 1023)
    assert head[:6] == b"\x93NUMPY", head[:8]
    major = head[6]
    size = struct.unpack("<H", head[8:10])[0] if major == 1 else struct.unpack("<I", head[8:12])[0]
    offset = (10 if major == 1 else 12) + size
    header = eval(head[offset - size : offset].decode())  # the .npy header is a dict literal
    print("matrix header:", header, "data starts at byte", offset)
    shape, dtype = header["shape"], np.dtype(header["descr"])

    labels_file = OUT / "labels.json"
    if not labels_file.exists():
        labels_file.write_bytes(fetch(LABELS))
    labels = json.loads(labels_file.read_text())
    print("labels:", len(labels), "first:", labels[0])
    index = {}
    for i, entry in enumerate(labels):
        ranks = entry[0]
        index.setdefault(f"{ranks[5]} {ranks[6]}", i)

    # Which way the matrix lies: species by dim, or dim by species.
    species_first = shape[0] == len(labels)
    dim = shape[1] if species_first else shape[0]
    count = shape[0] if species_first else shape[1]
    print("species:", count, "dim:", dim, "species are", "rows" if species_first else "columns",
          "fortran order" if header["fortran_order"] else "C order")

    # What the list holds of the animals a diver photographs. The seven
    # ranks are all filled in every entry, so a species whose source
    # taxonomy has a rank missing is not there at all.
    import collections

    by_class = collections.Counter(entry[0][2] for entry in labels)
    marine = {
        name: by_class.get(name, 0)
        for name in (
            "Actinopterygii", "Elasmobranchii", "Holocephali", "Reptilia",
            "Testudines", "Mammalia", "Cephalopoda", "Gastropoda",
            "Malacostraca", "Anthozoa", "Asteroidea", "Echinoidea",
            "Holothuroidea", "Ascidiacea",
        )
    }
    print("entries per class:", marine)
    print("the bony fishes it has:", [e for e in labels if e[0][2] == "Actinopterygii"][:3])

    names = json.loads((MINE / "species_names.json").read_text())
    missing = [name for name in names if name not in index]
    result = {
        "matrix_shape": list(shape),
        "matrix_dtype": str(dtype),
        "matrix_gb": round(count * dim * dtype.itemsize / 1e9, 2),
        "labels": len(labels),
        "labels_with_common_name": sum(1 for e in labels if e[1]),
        "species_are": "rows" if species_first else "columns",
        "entries_per_class": marine,
        "sample_species_found": len(names) - len(missing),
        "sample_species_missing": len(missing),
        "sample_species_missing_examples": missing[:8],
    }
    print(json.dumps(result, indent=2))
    (OUT / "result.json").write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
