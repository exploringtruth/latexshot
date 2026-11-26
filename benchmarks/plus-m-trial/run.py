"""Run a pinned PP-FormulaNet trial worker on frozen crops with network access denied."""

import argparse
from datetime import datetime, timezone
import hashlib
from importlib.metadata import version
import io
import json
import math
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import threading
import time

from PIL import Image


DIRECTORY = Path(__file__).resolve().parent
BENCHMARKS = DIRECTORY.parent
WORKER = BENCHMARKS.parent / "Sources/EquationRecognition/Resources/recognize.py"
NETWORK_PROFILE = "(version 1)(allow default)(deny network*)"
TRIAL_FLAGS = {
    "PP-FormulaNet_plus-M": "LATEXSHOT_ALLOW_PLUS_M_TRIAL",
    "PP-FormulaNet_plus-L": "LATEXSHOT_ALLOW_PLUS_L_TRIAL",
}
SUITES = {
    "wikipedia": ("held-out/manifest.json", 60),
    "hefferon-pdf": ("held-out/pdf/manifest.json", 6),
    "repeat-root": ("preprocessing-study/recaptures/manifest.json", 48),
}


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def frozen_inputs():
    # Use the same manifest digests as the archived plus-S guarded run.
    prior = BENCHMARKS / "plus-s-screen/diagnosis/protocol.json"
    hashes = json.loads(prior.read_text())["manifest_sha256"]
    cases = []
    for suite, (manifest_name, count) in SUITES.items():
        manifest = BENCHMARKS / manifest_name
        if sha256(manifest) != hashes[suite]:
            raise ValueError(f"Frozen manifest changed: {manifest_name}")
        rows = json.loads(manifest.read_text())
        if len(rows) != count or len({row["id"] for row in rows}) != count:
            raise ValueError(f"Unexpected fixture count or duplicate IDs: {suite}")
        for row in rows:
            path = manifest.parent / row["image"]
            payload = path.read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            if digest != (row.get("image_sha256") or row["sha256"]):
                raise ValueError(f"Frozen crop changed: {path}")
            with Image.open(io.BytesIO(payload)) as image:
                size = image.size
            cases.append(({
                "suite": suite,
                "id": row["id"],
                "category": row.get("category", suite),
                "image": str(path.relative_to(BENCHMARKS)),
                "input_sha256": digest,
                "size_px": size,
                "expected_latex": row["latex"],
            }, payload))
    return hashes, cases


def control_inputs(manifest):
    payload = manifest.read_bytes()
    rows = json.loads(payload)["cases"]
    if not rows or len({row["id"] for row in rows}) != len(rows):
        raise ValueError("Empty control manifest or duplicate fixture IDs")
    cases = []
    for row in rows:
        crop = (manifest.parent / row["image"]).read_bytes()
        digest = hashlib.sha256(crop).hexdigest()
        with Image.open(io.BytesIO(crop)) as image:
            size = image.size
        if digest != row["sha256"] or size != (row["width_px"], row["height_px"]):
            raise ValueError(f"Control crop changed: {row['id']}")
        cases.append(({
            "suite": "crop-controls",
            "id": row["id"],
            "category": row["formula"],
            "variant": row["variant"],
            "font_size_css_px": row["font_size_css_px"],
            "image": row["image"],
            "input_sha256": digest,
            "size_px": size,
            "expected_latex": row["latex"],
        }, crop))
    return {"crop-controls": hashlib.sha256(payload).hexdigest()}, cases


def paired_inputs(cases):
    small_type = [(case, payload) for case, payload in cases if case["category"] == "small-type"]
    smallest = sorted(small_type, key=lambda item: (min(item[0]["size_px"]), item[0]["id"]))[:3]
    roots = {"root-1x-24px-light-2", "root-1x-24px-dark-2"}
    selected = smallest + [(case, payload) for case, payload in cases if case["id"] in roots]
    for case, payload in selected:
        with Image.open(io.BytesIO(payload)) as image:
            size = (image.width * 2, image.height * 2)
            scaled = image.convert("RGB").resize(size, Image.Resampling.LANCZOS)
            output = io.BytesIO()
            scaled.save(output, format="PNG")
        upscaled = output.getvalue()
        yield ({
            **case,
            "suite": "upscale-2x",
            "baseline_suite": case["suite"],
            "size_px": size,
            "input_sha256": hashlib.sha256(upscaled).hexdigest(),
        }, upscaled)


def read_exact(handle, size):
    result = handle.read(size)
    if len(result) != size:
        raise RuntimeError("Worker closed its reply pipe")
    return result


def predict(process, payload, timeout):
    expired = threading.Event()

    def kill_on_timeout():
        expired.set()
        process.kill()

    watchdog = threading.Timer(timeout, kill_on_timeout)
    watchdog.start()
    try:
        started = time.perf_counter()
        process.stdin.write(struct.pack(">I", len(payload)) + payload)
        process.stdin.flush()
        size = struct.unpack(">I", read_exact(process.stdout, 4))[0]
        if not 0 < size <= 1024 * 1024:
            raise RuntimeError(f"Invalid worker response length: {size}")
        response = json.loads(read_exact(process.stdout, size))
        elapsed = time.perf_counter() - started
        if isinstance(response.get("latex"), str):
            return response, elapsed
        if isinstance(response.get("error"), str) and response.get("recoverable") is True:
            return response, elapsed
        raise RuntimeError(f"Fatal or invalid worker response: {response}")
    except (OSError, RuntimeError) as error:
        if expired.is_set():
            raise TimeoutError(f"Worker timed out after {timeout:g} seconds") from error
        raise
    finally:
        watchdog.cancel()
        watchdog.join()


def timing_summary(rows):
    times = sorted(row["warm_worker_seconds"] for row in rows)
    return {
        "measured": len(times),
        "warm_p95_seconds": times[math.ceil(0.95 * len(times)) - 1] if times else None,
        "worker_errors": sum("error" in row["response"] for row in rows),
    }


def save(output, evidence):
    rows = evidence["results"]
    groups = {
        "printed": [row for row in rows if row["suite"] in ("wikipedia", "hefferon-pdf")],
        "small-type": [row for row in rows if row["suite"] == "wikipedia" and row["category"] == "small-type"],
        **{name: [row for row in rows if row["suite"] == name] for name in (*SUITES, "upscale-2x", "crop-controls")},
    }
    evidence["summary"] = {name: timing_summary(group) for name, group in groups.items()}
    repeats = groups["repeat-root"]
    evidence["summary"]["repeat-root"]["exact_matches"] = sum(
        row["response"].get("latex") == row["expected_latex"] for row in repeats
    )
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--model-lock", type=Path, default=DIRECTORY / "model-lock.json")
    parser.add_argument("--first-id", action="append", default=[], help="Run this frozen ID first (repeatable)")
    parser.add_argument("--skip-upscaled", action="store_true")
    parser.add_argument("--crop-manifest", type=Path, help="Add the paired controls in this manifest")
    parser.add_argument("--controls-only", action="store_true")
    parser.add_argument("--output", type=Path, help="New JSON output file, required for inference")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    if not args.validate_only and (args.output is None or args.output.exists()):
        parser.error("inference requires a new --output path")

    lock_path = args.model_lock
    lock = json.loads(lock_path.read_text())
    if lock["model"] not in TRIAL_FLAGS:
        parser.error("model lock must describe a supported trial model")
    for entry in lock["files"]:
        target = args.model / entry["name"]
        if target.stat().st_size != entry["bytes"] or sha256(target) != entry["sha256"]:
            raise ValueError(f"Model artifact changed: {target}")
    if args.controls_only and (args.crop_manifest is None or args.first_id or args.skip_upscaled):
        parser.error("--controls-only requires --crop-manifest and excludes frozen-suite options")
    manifest_hashes, cases = ({}, []) if args.controls_only else frozen_inputs()
    if args.first_id:
        by_id = {case["id"]: (case, payload) for case, payload in cases}
        if len(set(args.first_id)) != len(args.first_id) or set(args.first_id) - by_id.keys():
            parser.error("--first-id requires distinct frozen fixture IDs")
        cases = [by_id[case_id] for case_id in args.first_id] + [
            (case, payload) for case, payload in cases if case["id"] not in args.first_id
        ]
    if not args.controls_only and not args.skip_upscaled:
        cases.extend(paired_inputs(cases))
    if args.crop_manifest:
        control_hashes, controls = control_inputs(args.crop_manifest)
        manifest_hashes.update(control_hashes)
        cases.extend(controls)
    print(f"Verified {len(cases)} inputs", flush=True)
    if args.validate_only:
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    evidence = {
        "model": lock["model"],
        "revision": lock["revision"],
        "model_lock_sha256": sha256(lock_path),
        "worker_sha256": sha256(WORKER),
        "manifest_sha256": manifest_hashes,
        "requirements_sha256": sha256(BENCHMARKS / "requirements-lock.txt"),
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "hardware": subprocess.check_output(["sysctl", "-n", "hw.model", "machdep.cpu.brand_string"], text=True).splitlines(),
        "runtime": {name: version(name) for name in ("paddlepaddle", "paddlex", "pillow")},
        "python": platform.python_version(),
        "network_profile": NETWORK_PROFILE,
        "timing_scope": "Cold from worker spawn to first complete response. Warm from request to response on the same worker. Capture, Swift encoding, clipboard writes and rendering are outside this measurement.",
        "percentile_method": "Nearest rank over all completed requests in each group, including recoverable errors",
        "expected_warm_requests": len(cases),
        "status": "running",
        "results": [],
    }
    save(args.output, evidence)
    env = {name: value for name, value in os.environ.items() if name not in TRIAL_FLAGS.values()}
    env[TRIAL_FLAGS[lock["model"]]] = "1"
    try:
        started = time.perf_counter()
        with subprocess.Popen(
            ["/usr/bin/sandbox-exec", "-p", NETWORK_PROFILE, sys.executable, "-I", "-B",
             str(WORKER), str(args.model.resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env,
        ) as process:
            try:
                first, payload = cases[0]
                response, _ = predict(process, payload, timeout=300)
                evidence["cold_first_response"] = {
                    "suite": first["suite"],
                    "id": first["id"],
                    "seconds": time.perf_counter() - started,
                    "response": response,
                }
                save(args.output, evidence)
                print(f"Cold first response: {evidence['cold_first_response']['seconds']:.3f} s", flush=True)
                for case, payload in cases:
                    response, elapsed = predict(process, payload, timeout=120)
                    evidence["results"].append({**case, "response": response, "warm_worker_seconds": elapsed})
                    save(args.output, evidence)
                    print(f"{case['suite']} {case['id']}: {elapsed:.3f} s", flush=True)
            finally:
                process.stdin.close()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if process.returncode != 0:
                raise RuntimeError(f"Worker exited with code {process.returncode}")
        evidence["status"] = "complete"
    except (Exception, KeyboardInterrupt) as error:
        evidence["status"] = "interrupted"
        evidence["failure"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        save(args.output, evidence)


if __name__ == "__main__":
    main()
