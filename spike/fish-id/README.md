# Fish identification spike

A throwaway check for roadmap v0.3.0 (`docs/roadmap_v0.3.0.md`,
`docs/design/fish-identification.md`): can the species model be shipped
as its image half alone, with the species' texts turned into numbers
ahead of time, and what do its ONNX and Core ML exports weigh and cost.
Python, in an environment of its own; nothing here is part of the app,
and no project file (`pubspec.yaml`, the runners) was changed for it.

## What is here

| File | What |
|---|---|
| `fish_id_spike.py` | Seven steps on the real weights: the towers' sizes, the text matrix made ahead, the ONNX export (FP32, FP16), the times, the Core ML package, the prompt's wording, the memory. |
| `published_embeddings.py` | What the text embeddings Imageomics publishes hold of the animals a diver photographs (almost no bony fishes: the app's own list has to be embedded). |
| `species_sample.tsv` | 64 Indo-Pacific reef animals with their seven ranks, written by hand: for shapes and timings only. |
| `results/` | The numbers of the runs of 2026-11-25 on the owner's Mac (M2, 16 GB), as JSON. |

Not in git (`.gitignore`): `.venv/` (0.9 GB), `weights/` (the models,
3.9 GB and 1.7 GB) and `out/` (the exports, several GB).

## Running it again

```bash
cd spike/fish-id
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python torch torchvision open_clip_torch \
    onnx onnxruntime onnxscript onnxconverter-common coremltools \
    huggingface_hub safetensors pillow numpy
.venv/bin/python -c "
from huggingface_hub import snapshot_download
snapshot_download('imageomics/bioclip-2.5-vith14',
    local_dir='weights/bioclip-2.5-vith14',
    allow_patterns=['open_clip_model.safetensors', '*.json', 'merges.txt'])"
.venv/bin/python fish_id_spike.py all                         # BioCLIP 2.5, ViT-H/14
FISH_ID_MODEL=bioclip-2 .venv/bin/python fish_id_spike.py all  # after fetching imageomics/bioclip-2
.venv/bin/python published_embeddings.py
```

Versions of 2026-11-25: Python 3.12, torch 2.15.0, open_clip 4.2.2, onnx
1.23.2, onnxruntime 1.32.0, coremltools 9.0 (which warns that it is
tested up to torch 2.7; the conversion worked).

## The models, kept

A model can leave its source or change its licence, so the two species
models are kept as they were fetched on 2026-11-25 (the model card with
its MIT line, the files, a `SOURCE.txt` with the revision and the
SHA-256) in the owner's Gitea, in the package registry, as generic
packages of the account:

| Package | Version | What |
|---|---|---|
| `bioclip-2.5-vith14` | `2026-11-25-6e3d04e` | BioCLIP 2.5, ViT-H/14. The model file is in three parts (the server takes no 3.9 GB file); `JOIN.txt` there says how to join them. |
| `bioclip-2` | `2026-11-25-2957b32` | BioCLIP 2, ViT-L/14. |

Put a package's files in `weights/<package>/` and the script runs
without the fetch from Hugging Face.

## What it does not show

How well the model names fish. The three pictures it runs are the repo's
own (two frames of a clown anemonefish from the README, one test photo
of sea squirts, which are not in the sample's list)
and only show that every way of running the model gives the same
numbers. The accuracy test is roadmap v0.3.0 A1, on the owner's footage.

## Removing it

`rm -rf spike/fish-id/.venv spike/fish-id/weights spike/fish-id/out`
frees the disk; the scripts and the results stay. Done on the owner's Mac
on 2026-11-26: for the next run, set it up again as above, with the
models from Gitea (above) or from Hugging Face.
