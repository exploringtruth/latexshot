"""Trace official plus-S token IDs and screen pixel-only preprocessing changes."""

import argparse
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import sys
import time

import numpy as np
from PIL import Image, ImageOps


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_crop(path):
    image = Image.open(path).convert("RGB")
    gray = np.asarray(image.convert("L"))
    border = np.concatenate((gray[0], gray[-1], gray[:, 0], gray[:, -1]))
    return ImageOps.invert(image) if np.median(border) < 128 else image


def alternative_canvas(cropper, image, variant):
    # Maintain the exported graph's 384x384 input and the training pipeline's
    # black padding. Only change ink rasterization, scale or canvas placement.
    if variant == "autocontrast":
        image = ImageOps.autocontrast(image.convert("L")).convert("RGB")
        return cropper.img_decode(np.asarray(image))
    ink = cropper.crop_margin(image)
    if variant == "bitmap":
        ink = ink.point(lambda intensity: 0 if intensity < 160 else 255)
    limit = 256 if variant == "inset" else 384
    scale = limit / max(ink.size)
    size = tuple(max(1, round(edge * scale)) for edge in ink.size)
    ink = ink.resize(size, Image.Resampling.LANCZOS)
    width_left, height_left = (384 - edge for edge in size)
    divisor = 4 if variant == "offset" else 2
    canvas = Image.new("RGB", (384, 384))
    canvas.paste(ink, (width_left // divisor, height_left // divisor))
    return np.asarray(canvas)


def trace(model, image, variant, checkpoint=None):
    started = time.perf_counter()
    transforms = model.pre_tfs
    bgr = np.asarray(image)[:, :, ::-1].copy()
    rgb = transforms["Read"](imgs=[bgr])
    if variant == "official":
        canvas = transforms["UniMERNetImgDecode"](imgs=rgb)
    else:
        canvas = [alternative_canvas(transforms["UniMERNetImgDecode"],
                                     Image.fromarray(rgb[0]), variant)]
    batch = transforms["UniMERNetTestTransform"](imgs=canvas)
    batch = transforms["LatexImageFormat"](imgs=batch)
    x = transforms["ToBatch"](imgs=batch)
    if checkpoint is None:
        (ids,) = model.runner(x=x)[0]
    else:
        import paddle

        with paddle.no_grad():
            (ids,) = checkpoint(paddle.to_tensor(x[0])).numpy()
    ids = ids.reshape(-1)
    (latex,) = model.post_op([ids])
    elapsed = time.perf_counter() - started
    raw_ids = [int(token) for token in ids]
    through_eos = raw_ids[:raw_ids.index(2) + 1] if 2 in raw_ids else raw_ids
    tokenizer = model.post_op.tokenizer
    return {
        "variant": variant,
        "input_tensor_sha256": hashlib.sha256(x[0].tobytes()).hexdigest(),
        "raw_ids_through_eos": through_eos,
        "tokenizer_output_before_postprocess": tokenizer.decode(
            through_eos, skip_special_tokens=True),
        "latex": latex,
        "seconds": elapsed,
    }


def load_checkpoint(source, weights):
    """Load the official training checkpoint with exact state-dict coverage."""
    import paddle
    import yaml

    sys.path.insert(0, str(source))
    from ppocr.modeling.architectures import build_model

    config_path = source / "configs/rec/PP-FormuaNet/PP-FormulaNet_plus-S.yaml"
    config = yaml.safe_load(config_path.read_text())
    paddle.set_device("cpu")
    model = build_model(config["Architecture"])
    state = paddle.load(str(weights))
    expected = model.state_dict()
    metadata = {
        "checkpoint_sha256": sha256(weights),
        "expected_parameters": len(expected),
        "missing_parameters": sorted(expected.keys() - state.keys()),
        "unexpected_parameters": sorted(state.keys() - expected.keys()),
        "shape_mismatches": sorted(key for key in expected.keys() & state.keys()
                                  if list(expected[key].shape) != list(state[key].shape)),
    }
    if any(metadata[key] for key in (
        "missing_parameters", "unexpected_parameters", "shape_mismatches",
    )):
        return None, metadata
    model.set_state_dict(state)
    model.eval()
    return model, metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--card-sample", type=Path, required=True)
    parser.add_argument("--upstream-tokenizer", type=Path, required=True)
    parser.add_argument("--upstream-source", type=Path)
    parser.add_argument("--training-checkpoint", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if bool(args.upstream_source) != bool(args.training_checkpoint):
        parser.error("--upstream-source and --training-checkpoint must be supplied together")

    os.environ.update(PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK="True",
                      DISABLE_MODEL_SOURCE_CHECK="True", HF_HUB_OFFLINE="1")
    import yaml
    from paddlex import create_model

    here = Path(__file__).resolve().parent
    lock_path = here / "model-lock.json"
    lock = json.loads(lock_path.read_text())
    for entry in lock["files"]:
        path = args.model / entry["name"]
        if path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise SystemExit("Model artifact changed: " + entry["name"])

    config = yaml.safe_load((args.model / "inference.yml").read_text())
    tokenizer = config["PostProcess"]["character_dict"]["fast_tokenizer_file"]
    training_tokenizer = json.loads(args.upstream_tokenizer.read_text())
    json_config = json.loads((args.model / "config.json").read_text())
    json_tokenizer = json_config["PostProcess"]["character_dict"]["fast_tokenizer_file"]
    vocab = tokenizer["model"]["vocab"]
    started = time.perf_counter()
    model = create_model(model_name=lock["model"], model_dir=str(args.model), device="cpu")
    startup = time.perf_counter() - started
    evidence = {
        "revision": lock["revision"],
        "model_lock_sha256": sha256(lock_path),
        "runtime": {package: version(package) for package in (
            "paddlepaddle", "paddlex", "paddleocr", "tokenizers", "ftfy", "pillow",
        )},
        "model_create_seconds": startup,
        "upstream_training_tokenizer_sha256": sha256(args.upstream_tokenizer),
        "training_tokenizer_equals_export_yaml": training_tokenizer == tokenizer,
        "export_json_tokenizer_equals_export_yaml": json_tokenizer == tokenizer,
        "tokenizer_ids": {key: vocab[key] for key in ("3", "object", "ĠObject")},
        "cases": [],
    }
    card_sha256 = "7885d4a349edcdfbfbc439305b8b554c2500f095949bc53d14835656b902dbcc"
    card_latex = (r"\zeta_{0}(\nu)=-\frac{\nu\varrho^{-2\nu}}{\pi}\int_{\mu}^{\infty}"
                  r"d\omega\int_{C_{+}}d z\frac{2z^{2}}{(z^{2}+\omega^{2})^{\nu+1}}"
                  r"\breve{\Psi}(\omega;z)e^{i\epsilon z}\quad,")
    checkpoint = None
    if args.training_checkpoint:
        checkpoint, metadata = load_checkpoint(args.upstream_source, args.training_checkpoint)
        evidence["training_checkpoint"] = metadata
        args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
        if checkpoint is None:
            raise SystemExit("Training checkpoint does not match the official architecture")
    variants = ("official", "autocontrast", "direct-lanczos", "bitmap", "inset", "offset")
    cases = [("model-card", args.card_sample, card_sha256, card_latex)]
    repeat = here.parent / "preprocessing-study/recaptures/manifest.json"
    repeat_cases = json.loads(repeat.read_text())
    selected = [case for case in repeat_cases if case["id"] in {
        "root-1x-24px-light-2", "root-1x-24px-dark-30",
        "root-2x-48px-light-16", "root-2x-48px-dark-6",
    }]
    for case in selected:
        cases.append((case["id"], repeat.parent / case["image"], case["sha256"], case["latex"]))
    for case_id, path, expected_sha, expected in cases:
        if sha256(path) != expected_sha:
            raise SystemExit("Crop changed: " + case_id)
        image = read_crop(path)
        outcomes = [trace(model, image, variant) for variant in variants]
        if checkpoint is not None:
            dynamic = trace(model, image, "official", checkpoint)
            dynamic["variant"] = "training-checkpoint"
            outcomes.append(dynamic)
        for row in outcomes:
            row["exact"] = row["latex"] == expected
        evidence["cases"].append({"id": case_id, "sha256": expected_sha,
                                  "expected_latex": expected, "outcomes": outcomes})
        print(case_id, [(row["variant"], row["latex"]) for row in outcomes], flush=True)
        args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
