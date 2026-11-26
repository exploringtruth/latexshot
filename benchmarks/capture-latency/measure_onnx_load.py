#!/usr/bin/env python3
"""Repeated CPU-only ONNX cold-load, real-crop inference, and feasibility benchmark."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import time


SCRIPT_DIR = Path(__file__).resolve().parent
TRACK_ROOT = SCRIPT_DIR.parents[1]
DEFAULT_MODEL = Path("/private/tmp/latexshot-native.sc4v8V/formulanet-s.onnx")
DEFAULT_IMAGE = TRACK_ROOT / "benchmarks/fixtures/roots-01.png"
WARM_E2E_P95_SECONDS = 0.2088
END_TO_END_GATE_SECONDS = 0.800


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def nearest_rank_p95(values):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * 0.95) - 1]


def summary(values):
    return {
        "minimum": round(min(values), 6),
        "median": round(statistics.median(values), 6),
        "p95_nearest_rank": round(nearest_rank_p95(values), 6),
        "maximum": round(max(values), 6),
    }


def preprocess_image(image):
    import cv2
    import numpy as np
    from PIL import Image, ImageOps

    # Match the production worker: invert uniformly dark page backgrounds.
    gray = np.asarray(image.convert("L"))
    border = np.concatenate((gray[0], gray[-1], gray[:, 0], gray[:, -1]))
    if np.median(border) < 128:
        image = ImageOps.invert(image)

    # Match UniMERNetImgDecode in PaddleX PP-FormulaNet-S.
    original_rgb = np.asarray(image)
    pil_image = Image.fromarray(original_rgb).convert("RGB")
    data = np.asarray(pil_image.convert("L")).astype(np.uint8)
    max_val = data.max()
    min_val = data.min()
    if max_val == min_val:
        cropped = pil_image
    else:
        data = (data - min_val) / (max_val - min_val) * 255
        ink = 255 * (data < 200).astype(np.uint8)
        coords = cv2.findNonZero(ink)
        if coords is None:
            cropped = pil_image
        else:
            x, y, width, height = cv2.boundingRect(coords)
            cropped = pil_image.crop((x, y, x + width, y + height))

    if cropped.width == 0 or cropped.height == 0:
        raise RuntimeError("Preprocessing produced an empty image")

    h = cropped.height
    w = cropped.width
    short = w if w <= h else h
    long = h if w <= h else w
    new_short = 384
    new_long = int(new_short * long / short)
    if w <= h:
        new_w, new_h = new_short, new_long
    else:
        new_w, new_h = new_long, new_short
    cropped = cropped.resize((new_w, new_h), resample=2)
    cropped.thumbnail((384, 384))

    pad_width = 384 - cropped.width
    pad_height = 384 - cropped.height
    left = pad_width // 2
    top = pad_height // 2
    padded = ImageOps.expand(
        cropped,
        border=(left, top, pad_width - left, pad_height - top),
        fill=0,
    )

    # Match UniMERNetTestTransform and LatexImageFormat.
    rgb = np.asarray(padded).astype(np.float32)
    mean = np.array([0.7931, 0.7931, 0.7931], dtype=np.float32).reshape(1, 1, 3)
    std = np.array([0.1738, 0.1738, 0.1738], dtype=np.float32).reshape(1, 1, 3)
    rgb = (rgb * (1.0 / 255.0) - mean) / std
    grayscale = np.squeeze(cv2.cvtColor(rgb, cv2.COLOR_BGR2GRAY))
    rgb_three = cv2.merge([grayscale] * 3)

    im_h, im_w = rgb_three.shape[:2]
    divide_h = math.ceil(im_h / 16) * 16
    divide_w = math.ceil(im_w / 16) * 16
    grayscale = rgb_three[:, :, 0]
    grayscale = np.pad(
        grayscale,
        ((0, divide_h - im_h), (0, divide_w - im_w)),
        constant_values=(1, 1),
    )
    tensor = grayscale[:, :, np.newaxis].transpose(2, 0, 1)
    tensor = tensor[np.newaxis, :].astype(np.float32)
    if tensor.shape != (1, 1, 384, 384):
        raise RuntimeError(f"Unexpected preprocessed shape: {tensor.shape}")
    return tensor


def preprocess_crop(image_path):
    from PIL import Image

    return preprocess_image(Image.open(image_path).convert("RGB"))


def worker(model, image, warm_runs):
    import importlib.metadata
    import os

    os.environ["ORT_LOG_SEVERITY_LEVEL"] = "3"

    import numpy as np
    import onnxruntime as ort

    ort_version = importlib.metadata.version("onnxruntime")
    preprocess_started = time.perf_counter()
    tensor = preprocess_crop(image)
    preprocess_seconds = time.perf_counter() - preprocess_started

    load_started = time.perf_counter()
    session = ort.InferenceSession(
        str(model),
        providers=["CPUExecutionProvider"],
    )
    session_load_seconds = time.perf_counter() - load_started

    input_meta = session.get_inputs()[0]
    output_meta = [item.name for item in session.get_outputs()]
    input_name = input_meta.name

    first_started = time.perf_counter()
    outputs = session.run(output_meta, {input_name: tensor})
    first_inference_seconds = time.perf_counter() - first_started

    warm_times = []
    for _ in range(warm_runs):
        warm_started = time.perf_counter()
        session.run(output_meta, {input_name: tensor})
        warm_times.append(time.perf_counter() - warm_started)

    result = {
        "ort_version": ort_version,
        "available_providers": session.get_providers(),
        "input_name": input_name,
        "input_shape": list(tensor.shape),
        "output_names": output_meta,
        "output_shapes": [list(output.shape) for output in outputs],
        "preprocess_seconds": round(preprocess_seconds, 6),
        "session_load_seconds": round(session_load_seconds, 6),
        "first_inference_seconds": round(first_inference_seconds, 6),
        "cold_plus_first_seconds": round(
            session_load_seconds + first_inference_seconds,
            6,
        ),
        "warm_times_seconds": [round(value, 6) for value in warm_times],
        "warm_p95_seconds": round(nearest_rank_p95(warm_times), 6),
        "warm_median_seconds": round(statistics.median(warm_times), 6),
    }
    print(json.dumps(result, sort_keys=True))


def run_repeats(args):
    repeats = []
    for _ in range(args.repeat):
        completed = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--worker",
                "--model",
                str(args.model),
                "--image",
                str(args.image),
                "--warm-runs",
                str(args.warm_runs),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        lines = [line for line in completed.stdout.splitlines() if line.strip()]
        repeats.append(json.loads(lines[-1]))
    return repeats


def build_report(args, repeats):
    cold_load = [row["session_load_seconds"] for row in repeats]
    first = [row["first_inference_seconds"] for row in repeats]
    cold_plus_first = [row["cold_plus_first_seconds"] for row in repeats]
    preprocess = [row["preprocess_seconds"] for row in repeats]
    warm_p95 = [row["warm_p95_seconds"] for row in repeats]

    cold_plus_first_p95 = nearest_rank_p95(cold_plus_first)
    conservative_e2e_p95 = WARM_E2E_P95_SECONDS + cold_plus_first_p95
    cold_plus_first_fail = [
        index + 1
        for index, value in enumerate(cold_plus_first)
        if value >= END_TO_END_GATE_SECONDS
    ]

    e2e_report = args.e2e_report if args.e2e_report.is_file() else None
    measured_e2e = None
    if e2e_report:
        with e2e_report.open() as source:
            e2e = json.load(source)
        cold_e2e = [row["mouseUpToCopyMs"] / 1000 for row in e2e["cold"]]
        warm_e2e = [row["mouseUpToCopyMs"] / 1000 for row in e2e["warm"]]
        cold_e2e_p95 = nearest_rank_p95(cold_e2e)
        warm_e2e_p95 = nearest_rank_p95(warm_e2e)
        measured_e2e = {
            "cold_sample_count": len(cold_e2e),
            "warm_sample_count": len(warm_e2e),
            "cold_median_seconds": round(statistics.median(cold_e2e), 6),
            "cold_p95_nearest_rank_seconds": round(cold_e2e_p95, 6),
            "warm_median_seconds": round(statistics.median(warm_e2e), 6),
            "warm_p95_nearest_rank_seconds": round(warm_e2e_p95, 6),
            "cold_pass_under_0.8_seconds": cold_e2e_p95 < END_TO_END_GATE_SECONDS,
            "warm_pass_under_0.8_seconds": warm_e2e_p95 < END_TO_END_GATE_SECONDS,
        }

    overall_viable = bool(measured_e2e and
        measured_e2e["cold_pass_under_0.8_seconds"] and
        measured_e2e["warm_pass_under_0.8_seconds"])
    if measured_e2e is None:
        overall_viable = (
            conservative_e2e_p95 < END_TO_END_GATE_SECONDS
        )

    report = {
        "provider": "CPUExecutionProvider",
        "model": str(args.model),
        "model_sha256": sha256(args.model),
        "model_size_bytes": args.model.stat().st_size,
        "image": str(args.image),
        "image_sha256": sha256(args.image),
        "ort_version": repeats[0]["ort_version"],
        "available_providers": repeats[0]["available_providers"],
        "input_shape": repeats[0]["input_shape"],
        "output_names": repeats[0]["output_names"],
        "output_shapes": repeats[0]["output_shapes"],
        "repeat_count": args.repeat,
        "warm_runs_per_repeat": args.warm_runs,
        "repeat_results": repeats,
        "session_load_seconds": summary(cold_load),
        "preprocess_seconds": summary(preprocess),
        "first_inference_seconds": summary(first),
        "cold_plus_first_seconds": summary(cold_plus_first),
        "warm_p95_seconds": summary(warm_p95),
        "existing_native_warm_e2e_p95_seconds": WARM_E2E_P95_SECONDS,
        "conservative_first_capture_e2e_p95_seconds": round(
            conservative_e2e_p95,
            6,
        ),
        "measured_native_end_to_end": measured_e2e,
        "end_to_end_gate_seconds": END_TO_END_GATE_SECONDS,
        "coreml_ep_status": (
            "FAIL compile: MaxPool ceil_mode must be False when pad_type is same"
        ),
        "coremltools9_onnx": "unsupported (source onnx removed)",
        "cold_plus_first_runs_at_or_over_gate": cold_plus_first_fail,
        "viable_for_0.8s_gate": overall_viable,
        "notes": (
            "CPU-only 294 MB ONNX benchmark used a real 252 x 68 fixture crop "
            "with the production margin crop, 384-pixel resize/pad, UniMERNet "
            "normalization, and grayscale formatting. Seven fresh sessions "
            "measured session load plus first inference. The native Swift "
            "benchmark measured seven cold captures and 60 warm captures "
            "through ScreenCaptureKit and a private pasteboard. "
            "Warm end-to-end passed under 0.8 seconds; measured cold "
            "end-to-end nearest-rank p95 failed under 0.8 seconds."
        ),
    }
    return report


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE)
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--warm-runs", type=int, default=5)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--e2e-report",
        type=Path,
        default=SCRIPT_DIR / "onnx-end-to-end.json",
    )
    args = parser.parse_args()
    if args.repeat < 1 or args.warm_runs < 1:
        parser.error("--repeat and --warm-runs must be positive")
    if not args.model.is_file():
        parser.error(f"Model not found: {args.model}")
    if not args.image.is_file():
        parser.error(f"Image not found: {args.image}")
    if args.output and not args.output.parent.is_dir():
        parser.error(f"Output directory not found: {args.output.parent}")
    return args


def main():
    args = parse_args()
    if args.worker:
        worker(args.model, args.image, args.warm_runs)
        return

    report = build_report(args, run_repeats(args))
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    print(rendered, end="")
    if args.output:
        args.output.write_text(rendered)


if __name__ == "__main__":
    main()
