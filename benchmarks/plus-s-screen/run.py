"""Measure the opt-in plus-S trial worker on frozen crops."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--python", required=True)
parser.add_argument("--model", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--repeat-root", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
directory = Path(__file__).parent
lock = json.loads((directory / "model-lock.json").read_text())
for entry in lock["files"]:
    target = args.model / entry["name"]
    if target.stat().st_size != entry["bytes"] or hashlib.sha256(target.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit("Model artifact changed: " + entry["name"])
worker = root / "Sources/EquationRecognition/Resources/recognize.py"
suites = [("wikipedia", root / "benchmarks/held-out/manifest.json"),
          ("hefferon-pdf", root / "benchmarks/held-out/pdf/manifest.json")]
if args.repeat_root:
    suites.append(("repeat-root", root / "benchmarks/preprocessing-study/recaptures/manifest.json"))
args.output.mkdir(parents=True, exist_ok=True)
protocol = {"model": lock["model"], "revision": lock["revision"],
    "model_lock_sha256": hashlib.sha256((directory / "model-lock.json").read_bytes()).hexdigest(),
    "trial_worker_sha256": hashlib.sha256(worker.read_bytes()).hexdigest(),
    "worker_environment": {"LATEXSHOT_ALLOW_PLUS_S_TRIAL": "1"},
    "benchmark_python": platform.python_version(),
    "worker_python": str(Path(args.python).absolute()),
    "model_directory": str(args.model.resolve()),
    "preprocessing": "Production v1 dark-border inversion; no experimental crop normalization",
    "manifest_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in suites},
    "app_latency_target_seconds": 0.8, "release_approved": False,
    "timing_scope": "Cold process launch to first complete prediction, and separate warm pipe round trips. Both exclude capture, Swift encoding and clipboard write."}
(args.output / "protocol.json").write_text(json.dumps(protocol, indent=2) + "\n")


def read_exact(handle, length):
    result = bytearray()
    while len(result) < length:
        chunk = handle.read(length - len(result))
        if not chunk:
            raise RuntimeError("Worker exited or timed out")
        result.extend(chunk)
    return bytes(result)


def predict(process, payload):
    watchdog = threading.Timer(60, process.kill)
    watchdog.start()
    try:
        process.stdin.write(struct.pack(">I", len(payload)) + payload)
        process.stdin.flush()
        size = struct.unpack(">I", read_exact(process.stdout, 4))[0]
        if not 0 < size <= 1024 * 1024:
            raise RuntimeError("Invalid worker response")
        response = json.loads(read_exact(process.stdout, size))
        if "error" in response and response.get("recoverable") is not True:
            raise RuntimeError(response["error"])
        return response
    finally:
        watchdog.cancel()


def run_suites():
    for suite, manifest in suites:
        fixtures = json.loads(manifest.read_text())
        if suite != "repeat-root":
            freeze = json.loads(manifest.with_name("freeze.json").read_text())
            if freeze["manifest_sha256"] != hashlib.sha256(manifest.read_bytes()).hexdigest():
                raise SystemExit("Frozen manifest changed")
        payloads = []
        for fixture in fixtures:
            payload = (manifest.parent / fixture["image"]).read_bytes()
            expected_hash = fixture.get("image_sha256") or fixture["sha256"]
            if hashlib.sha256(payload).hexdigest() != expected_hash:
                raise SystemExit("Frozen crop changed: " + fixture["id"])
            payloads.append(payload)
        started = time.perf_counter()
        process = subprocess.Popen([args.python, "-I", "-B", str(worker), str(args.model.resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            env={**os.environ, "LATEXSHOT_ALLOW_PLUS_S_TRIAL": "1"})
        try:
            first = predict(process, payloads[0])
            cold_seconds = time.perf_counter() - started
            result = {"model": lock["model"], "revision": lock["revision"],
                "platform": platform.platform(), "python": platform.python_version(),
                "cold_first_prediction_seconds": cold_seconds, "cold_first_prediction_case": fixtures[0]["id"],
                "cold_first_prediction": first, "results": [], "release_approved": False}
            for fixture, payload in zip(fixtures, payloads, strict=True):
                before = time.perf_counter()
                response = predict(process, payload)
                result["results"].append({"id": fixture["id"], "category": fixture.get("category", "repeat-root"),
                    "image": fixture["image"], "expected_latex": fixture["latex"],
                    "latex": response.get("latex"), "error": response.get("error"),
                    "recoverable": response.get("recoverable"),
                    "warm_worker_seconds": time.perf_counter() - before, "structurally_correct": None})
                (args.output / (suite + ".json")).write_text(json.dumps(result, indent=2) + "\n")
                print(suite, fixture["id"], flush=True)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process.stdout.close()


run_suites()
