"""Fish identification spike (roadmap v0.3.0, docs/design/fish-identification.md).

What it checks, on this machine, with the real weights:

  1. params   BioCLIP 2.5 loads in open_clip; the size of each tower.
  2. text     Species text embeddings computed ahead of time: the matrix's
              shape, its size, and that the image tower alone then gives
              the same scores as the whole model.
  3. onnx     The image tower exported to ONNX, FP32 and FP16: file sizes,
              the input and output shapes, agreement with PyTorch.
  4. time     Seconds per crop: PyTorch (CPU, MPS), ONNX Runtime (CPU,
              Core ML provider).
  5. coreml   The image tower as a Core ML .mlpackage (FP16): size, time,
              agreement with PyTorch.
  6. prompts  How much the wording of a species' text changes the answer.
  7. memory   The most memory a process holds while it embeds crops.

Nothing here touches the app. Run from this folder:

    .venv/bin/python fish_id_spike.py all
    .venv/bin/python fish_id_spike.py params text      # only some steps

The weights are read from weights/<model> (fetched with huggingface_hub,
see README.md); what is exported goes to out/. Both are git-ignored. The
numbers are printed and written to out/results.json.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
MODEL = os.environ.get("FISH_ID_MODEL", "bioclip-2.5-vith14")
WEIGHTS = HERE / "weights" / MODEL
OUT = HERE / "out" / MODEL
RESULTS = OUT / "results.json"

RANKS = ["kingdom", "phylum", "class", "order", "family", "genus", "species"]


def log(*parts):
    print(*parts, flush=True)


def load_results() -> dict:
    return json.loads(RESULTS.read_text()) if RESULTS.exists() else {}


def save_results(key: str, value) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    results = load_results()
    results[key] = value
    RESULTS.write_text(json.dumps(results, indent=2))


def load_model():
    import open_clip

    model, _, preprocess = open_clip.create_model_and_transforms(
        f"local-dir:{WEIGHTS}"
    )
    tokenizer = open_clip.get_tokenizer(f"local-dir:{WEIGHTS}")
    model.eval()
    return model, preprocess, tokenizer


def species_rows() -> list[dict]:
    lines = [
        line
        for line in (HERE / "species_sample.tsv").read_text().splitlines()
        if line and not line.startswith("#")
    ]
    header = lines[0].split("\t")
    return [dict(zip(header, line.split("\t"))) for line in lines[1:]]


def prompt(row: dict) -> str:
    """The text BioCLIP is trained on: the seven ranks, then the common name."""
    taxon = " ".join(row[rank] for rank in RANKS)
    return f"a photo of {taxon} with common name {row['common']}."


def sample_images(preprocess) -> tuple[torch.Tensor, list[str]]:
    """A few pictures to run through: the repo's own (an underwater frame of
    the README and test fixtures). They only show that the numbers agree
    between the ways of running the model; they are no test of accuracy."""
    from PIL import Image

    repo = HERE.parent.parent
    candidates = [
        repo / "docs/images/frame-corrected.jpg",
        repo / "docs/images/frame-original.jpg",
        repo / "test/fixtures/media/photo/jpeg_3x2_2mp.jpg",
    ]
    found = [p for p in candidates if p.exists()]
    if not found:
        log("  no sample picture found; random input used")
        return torch.rand(2, 3, 224, 224), ["random", "random"]
    batch = torch.stack([preprocess(Image.open(p).convert("RGB")) for p in found])
    return batch, [p.name for p in found]


def megabytes(path: Path) -> float:
    if path.is_dir():
        return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1e6
    return path.stat().st_size / 1e6


def onnx_megabytes(path: Path) -> float:
    """An ONNX file with its weights beside it (above 2 GB they must be)."""
    total = path.stat().st_size
    data = path.with_suffix(path.suffix + ".data")
    if data.exists():
        total += data.stat().st_size
    return total / 1e6


# 1 ------------------------------------------------------------------ params


def step_params():
    model, preprocess, _ = load_model()
    visual = sum(p.numel() for p in model.visual.parameters())
    total = sum(p.numel() for p in model.parameters())
    text = total - visual
    size = preprocess.transforms[0].size
    with torch.no_grad():
        dim = model.encode_image(torch.zeros(1, 3, 224, 224)).shape[-1]
    result = {
        "model": MODEL,
        "weights_file_mb": round(megabytes(WEIGHTS / "open_clip_model.safetensors"), 1),
        "params_visual_m": round(visual / 1e6, 1),
        "params_text_and_rest_m": round(text / 1e6, 1),
        "visual_fp32_mb": round(visual * 4 / 1e6, 1),
        "visual_fp16_mb": round(visual * 2 / 1e6, 1),
        "text_fp32_mb": round(text * 4 / 1e6, 1),
        "embedding_dim": dim,
        "input": f"1x3x{size}x{size}" if isinstance(size, int) else str(size),
        "preprocess": str(preprocess),
    }
    log(json.dumps(result, indent=2))
    save_results("params", result)


# 2 -------------------------------------------------------------------- text


def step_text():
    model, preprocess, tokenizer = load_model()
    rows = species_rows()
    prompts = [prompt(row) for row in rows]
    log("  example prompt:", prompts[0])

    started = time.perf_counter()
    with torch.no_grad():
        text = model.encode_text(tokenizer(prompts))
        text = text / text.norm(dim=-1, keepdim=True)
    seconds = time.perf_counter() - started
    matrix = text.numpy().astype(np.float16)
    OUT.mkdir(parents=True, exist_ok=True)
    np.save(OUT / "species_text_fp16.npy", matrix)
    (OUT / "species_names.json").write_text(
        json.dumps([f"{r['genus']} {r['species']}" for r in rows])
    )

    # The image tower alone with the stored matrix against the whole model.
    images, names = sample_images(preprocess)
    with torch.no_grad():
        image = model.encode_image(images)
        image = image / image.norm(dim=-1, keepdim=True)
        scale = model.logit_scale.exp().item()
        whole = (scale * image @ text.T).softmax(dim=-1)
    stored = torch.from_numpy(matrix.astype(np.float32))
    alone = (scale * image @ stored.T).softmax(dim=-1)
    worst = (whole - alone).abs().max().item()
    same_top = bool((whole.argmax(-1) == alone.argmax(-1)).all())

    tops = []
    for i, name in enumerate(names):
        best = alone[i].topk(3)
        tops.append(
            {
                "picture": name,
                "top3": [
                    [f"{rows[j]['genus']} {rows[j]['species']}", round(p, 3)]
                    for p, j in zip(best.values.tolist(), best.indices.tolist())
                ],
            }
        )

    dim = matrix.shape[1]
    per_species_kb = dim * 2 / 1e3
    result = {
        "species": len(rows),
        "matrix_shape": list(matrix.shape),
        "matrix_dtype": "float16",
        "matrix_kb": round(matrix.nbytes / 1e3, 1),
        "seconds_for_all_cpu": round(seconds, 2),
        "seconds_per_species_cpu": round(seconds / len(rows), 3),
        "logit_scale": round(scale, 3),
        "fp16_matrix_vs_whole_model_max_probability_difference": worst,
        "same_top_species": same_top,
        "sample_top3_no_accuracy_claim": tops,
        "extrapolated_mb": {
            f"{n} species": round(n * per_species_kb / 1e3, 1)
            for n in (500, 3000, 20000, 250000, 1000000)
        },
    }
    log(json.dumps(result, indent=2))
    save_results("text", result)


# 3 -------------------------------------------------------------------- onnx


class ImageTower(torch.nn.Module):
    """The image tower with the normalising in it: a crop in, a unit vector out."""

    def __init__(self, visual):
        super().__init__()
        self.visual = visual

    def forward(self, image):
        features = self.visual(image)
        return features / features.norm(dim=-1, keepdim=True)


class HalfImageTower(torch.nn.Module):
    """The same in half precision inside, float32 in and out."""

    def __init__(self, visual):
        super().__init__()
        self.visual = visual.half()

    def forward(self, image):
        features = self.visual(image.half()).float()
        return features / features.norm(dim=-1, keepdim=True)


def step_onnx():
    import onnx
    import onnxruntime as ort

    model, preprocess, _ = load_model()
    tower = ImageTower(model.visual).eval()
    images, _ = sample_images(preprocess)
    with torch.no_grad():
        want = tower(images).numpy()

    OUT.mkdir(parents=True, exist_ok=True)
    fp32 = OUT / "image_tower_fp32.onnx"
    # Above 2 GB an ONNX file cannot hold its own weights (protobuf's
    # limit), and the exporter then writes one file per tensor: exported
    # into a folder of its own and saved again with one weights file.
    import shutil
    import tempfile

    raw_dir = Path(tempfile.mkdtemp(prefix="export_", dir=OUT))
    started = time.perf_counter()
    torch.onnx.export(
        tower,
        (images[:1],),
        str(raw_dir / "raw.onnx"),
        input_names=["image"],
        output_names=["embedding"],
        dynamic_axes={"image": {0: "batch"}, "embedding": {0: "batch"}},
        opset_version=17,
        dynamo=False,
    )
    export_seconds = time.perf_counter() - started
    raw_files = len(list(raw_dir.iterdir()))
    full = onnx.load(str(raw_dir / "raw.onnx"))
    for old in (fp32, fp32.with_suffix(".onnx.data")):
        old.unlink(missing_ok=True)
    onnx.save(
        full,
        str(fp32),
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location=fp32.name + ".data",
    )
    shutil.rmtree(raw_dir)

    session = ort.InferenceSession(str(fp32), providers=["CPUExecutionProvider"])
    got = session.run(None, {"image": images.numpy()})[0]
    inputs = [(i.name, i.shape, i.type) for i in session.get_inputs()]
    outputs = [(o.name, o.shape, o.type) for o in session.get_outputs()]
    cos32 = float((want * got).sum(-1).min())
    ops = sorted({node.op_type for node in full.graph.node})

    # FP16: half the size, the input and the output kept float32 so that
    # the caller does not change. Exported from the model in half
    # precision: converting the FP32 file (onnxconverter-common) needs
    # shape inference, which fails above 2 GB, and without it leaves a
    # graph ONNX Runtime refuses (mixed types into Concat; 2026-11-25).
    del full
    fp16 = OUT / "image_tower_fp16.onnx"
    fp16_error = None
    cos16 = None
    try:
        half_tower = HalfImageTower(model.visual).eval()
        torch.onnx.export(
            half_tower,
            (images[:1],),
            str(fp16),  # under 2 GB, so one file
            input_names=["image"],
            output_names=["embedding"],
            dynamic_axes={"image": {0: "batch"}, "embedding": {0: "batch"}},
            opset_version=17,
            dynamo=False,
        )
        session16 = ort.InferenceSession(str(fp16), providers=["CPUExecutionProvider"])
        got16 = session16.run(None, {"image": images.numpy()})[0]
        cos16 = float((want * got16).sum(-1).min())
    except Exception as error:
        fp16_error = str(error)[:400]
    finally:
        model.visual.float()

    result = {
        "opset": 17,
        "export_seconds": round(export_seconds, 1),
        "files_the_exporter_wrote_above_2gb": raw_files,
        "inputs": inputs,
        "outputs": outputs,
        "operators": ops,
        "fp32_mb": round(onnx_megabytes(fp32), 1),
        "fp16_mb": round(onnx_megabytes(fp16), 1) if fp16.exists() else None,
        "fp16_error": fp16_error,
        "fp32_cosine_to_pytorch_min": cos32,
        "fp16_cosine_to_pytorch_min": cos16,
    }
    log(json.dumps(result, indent=2, default=str))
    save_results("onnx", json.loads(json.dumps(result, default=str)))


# 4 -------------------------------------------------------------------- time


def timed(run, repeats=5):
    run()  # the first call loads and compiles
    times = []
    for _ in range(repeats):
        started = time.perf_counter()
        run()
        times.append(time.perf_counter() - started)
    return round(float(np.median(times)), 3)


def step_time():
    import onnxruntime as ort

    model, preprocess, _ = load_model()
    tower = ImageTower(model.visual).eval()
    images, _ = sample_images(preprocess)
    one = images[:1]
    eight = one.repeat(8, 1, 1, 1)
    result = {"machine": os.uname().machine, "threads": torch.get_num_threads()}

    with torch.no_grad():
        result["pytorch_cpu_1"] = timed(lambda: tower(one))
        result["pytorch_cpu_8"] = timed(lambda: tower(eight), repeats=3)
        if torch.backends.mps.is_available():
            on_gpu = tower.to("mps")
            a, b = one.to("mps"), eight.to("mps")

            def gpu(x):
                on_gpu(x)
                torch.mps.synchronize()

            result["pytorch_mps_1"] = timed(lambda: gpu(a))
            result["pytorch_mps_8"] = timed(lambda: gpu(b), repeats=3)
            half = on_gpu.half()
            ah, bh = a.half(), b.half()

            def gpu16(x):
                half(x)
                torch.mps.synchronize()

            result["pytorch_mps_fp16_1"] = timed(lambda: gpu16(ah))
            result["pytorch_mps_fp16_8"] = timed(lambda: gpu16(bh), repeats=3)
            tower.to("cpu").float()
    log(json.dumps(result, indent=2))
    save_results("time", result)

    for name in ("image_tower_fp32.onnx", "image_tower_fp16.onnx"):
        path = OUT / name
        if not path.exists():
            continue
        for label, providers in (
            ("cpu", ["CPUExecutionProvider"]),
            ("coreml", ["CoreMLExecutionProvider", "CPUExecutionProvider"]),
        ):
            key = f"onnx_{name.split('_')[-1].split('.')[0]}_{label}"
            try:
                session = ort.InferenceSession(str(path), providers=providers)
                feed = {"image": one.numpy()}
                result[f"{key}_1"] = timed(lambda: session.run(None, feed))
                if label == "cpu":
                    feed8 = {"image": eight.numpy()}
                    result[f"{key}_8"] = timed(lambda: session.run(None, feed8), 3)
                result[f"{key}_providers"] = session.get_providers()
            except Exception as error:  # a provider that cannot take the model
                result[f"{key}_error"] = str(error)[:300]
            log(json.dumps({k: v for k, v in result.items() if k.startswith(key)}))
            save_results("time", result)


# 5 ------------------------------------------------------------------ coreml


def step_coreml():
    import coremltools as ct

    model, preprocess, _ = load_model()
    tower = ImageTower(model.visual).eval()
    images, _ = sample_images(preprocess)
    one = images[:1]
    with torch.no_grad():
        want = tower(one).numpy()
        traced = torch.jit.trace(tower, one)

    started = time.perf_counter()
    package = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=one.shape)],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
    )
    convert_seconds = time.perf_counter() - started
    path = OUT / "image_tower_fp16.mlpackage"
    if path.exists():
        import shutil

        shutil.rmtree(path)
    package.save(str(path))

    result = {
        "convert_seconds": round(convert_seconds, 1),
        "mlpackage_fp16_mb": round(megabytes(path), 1),
    }
    for label, units in (
        ("all", ct.ComputeUnit.ALL),
        ("cpu_and_gpu", ct.ComputeUnit.CPU_AND_GPU),
        ("cpu_and_ne", ct.ComputeUnit.CPU_AND_NE),
        ("cpu_only", ct.ComputeUnit.CPU_ONLY),
    ):
        try:
            started = time.perf_counter()
            loaded = ct.models.MLModel(str(path), compute_units=units)
            feed = {"image": one.numpy()}
            got = loaded.predict(feed)["embedding"]
            result[f"{label}_load_and_first_seconds"] = round(
                time.perf_counter() - started, 1
            )
            result[f"{label}_seconds_1"] = timed(lambda: loaded.predict(feed))
            result[f"{label}_cosine_to_pytorch"] = float((want * got).sum())
        except Exception as error:
            result[f"{label}_error"] = str(error)[:300]
        log(json.dumps({k: v for k, v in result.items() if k.startswith(label)}))
        save_results("coreml", result)
    log(json.dumps(result, indent=2))
    save_results("coreml", result)


# 6 ----------------------------------------------------------------- prompts


def step_prompts():
    """How much the wording of a species' text matters. GBIF's taxonomy has
    no class for the bony fishes, and the list of species Imageomics
    publishes embeddings for holds almost none of them (see
    published_embeddings.py), so it is not known which wording the model
    saw for a fish in training."""
    model, preprocess, tokenizer = load_model()
    rows = species_rows()
    wordings = {
        "seven ranks and common name": lambda r: prompt(r),
        "seven ranks": lambda r: "a photo of " + " ".join(r[k] for k in RANKS) + ".",
        "no class, common name": lambda r: "a photo of "
        + " ".join(r[k] for k in RANKS if k != "class")
        + f" with common name {r['common']}.",
        "scientific name": lambda r: f"a photo of {r['genus']} {r['species']}.",
        "common name": lambda r: f"a photo of {r['common']}.",
    }
    images, names = sample_images(preprocess)
    with torch.no_grad():
        image = model.encode_image(images)
        image = image / image.norm(dim=-1, keepdim=True)
        scale = model.logit_scale.exp().item()
        first = None
        result = {}
        for label, wording in wordings.items():
            text = model.encode_text(tokenizer([wording(r) for r in rows]))
            text = text / text.norm(dim=-1, keepdim=True)
            if first is None:
                first = text
            probabilities = (scale * image @ text.T).softmax(dim=-1)
            best = probabilities.argmax(-1).tolist()
            result[label] = {
                "mean_cosine_to_first_wording": round(float((text * first).sum(-1).mean()), 3),
                "top_per_picture": [
                    [n, f"{rows[j]['genus']} {rows[j]['species']}", round(float(probabilities[i, j]), 3)]
                    for i, (n, j) in enumerate(zip(names, best))
                ],
            }
    log(json.dumps(result, indent=2))
    save_results("prompts", result)


# 7 ------------------------------------------------------------------ memory


def step_memory():
    """The most memory the process holds while it embeds crops with the
    Core ML package, the way an app would (the image tower only)."""
    import resource
    import subprocess

    code = (
        "import sys, resource, numpy as np, coremltools as ct\n"
        "m = ct.models.MLModel(sys.argv[1], compute_units=getattr(ct.ComputeUnit, sys.argv[2]))\n"
        "x = {'image': np.zeros((1, 3, 224, 224), dtype=np.float32)}\n"
        "for _ in range(5): m.predict(x)\n"
        "print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)\n"
    )
    result = {}
    for units in ("ALL", "CPU_AND_GPU", "CPU_ONLY"):
        out = subprocess.run(
            [sys.executable, "-c", code, str(OUT / "image_tower_fp16.mlpackage"), units],
            capture_output=True,
            text=True,
        )
        last = out.stdout.strip().splitlines()[-1] if out.stdout.strip() else ""
        result[f"coreml_{units.lower()}_peak_rss_mb"] = (
            round(int(last) / 1e6, 0) if last.isdigit() else out.stderr[-200:]
        )
    code = (
        "import sys, resource, numpy as np, onnxruntime as ort\n"
        "s = ort.InferenceSession(sys.argv[1], providers=['CPUExecutionProvider'])\n"
        "x = {'image': np.zeros((1, 3, 224, 224), dtype=np.float32)}\n"
        "for _ in range(3): s.run(None, x)\n"
        "print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)\n"
    )
    for name in ("image_tower_fp16.onnx", "image_tower_fp32.onnx"):
        out = subprocess.run(
            [sys.executable, "-c", code, str(OUT / name)], capture_output=True, text=True
        )
        last = out.stdout.strip().splitlines()[-1] if out.stdout.strip() else ""
        result[f"onnx_cpu_{name.split('_')[-1].split('.')[0]}_peak_rss_mb"] = (
            round(int(last) / 1e6, 0) if last.isdigit() else out.stderr[-200:]
        )
    log(json.dumps(result, indent=2))
    save_results("memory", result)


STEPS = {
    "params": step_params,
    "text": step_text,
    "onnx": step_onnx,
    "time": step_time,
    "coreml": step_coreml,
    "prompts": step_prompts,
    "memory": step_memory,
}


def main(argv):
    wanted = argv or ["all"]
    if "all" in wanted:
        wanted = list(STEPS)
    if not WEIGHTS.exists():
        sys.exit(f"No weights in {WEIGHTS}; see README.md.")
    for name in wanted:
        log(f"\n== {name} ({MODEL})")
        STEPS[name]()


if __name__ == "__main__":
    main(sys.argv[1:])
