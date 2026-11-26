"""Evaluate the identical app worker against crops. Manual structural review is required."""
import argparse
import json
import platform
from pathlib import Path
import struct
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--python", required=True)
parser.add_argument("--model", required=True)
parser.add_argument("--model-name", choices=["PP-FormulaNet-S", "PP-FormulaNet-L"], default="PP-FormulaNet-S")
parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("fixtures") / "manifest.json")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--worker", type=Path)
parser.add_argument("--preprocessing", default="v1-dark-border-inversion")
args = parser.parse_args()
worker = args.worker or Path(__file__).parent.parent / "Sources/EquationRecognition/Resources/recognize.py"
process = subprocess.Popen([args.python, "-I", "-B", str(worker), args.model],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def predict(payload):
    watchdog = threading.Timer(60, process.kill)
    watchdog.start()
    try:
        process.stdin.write(struct.pack(">I", len(payload)) + payload)
        process.stdin.flush()
        header = process.stdout.read(4)
        if len(header) != 4:
            raise RuntimeError("Worker exited or exceeded the 60-second timeout")
        size = struct.unpack(">I", header)[0]
        if size > 1024 * 1024:
            raise RuntimeError("Invalid worker response")
        return json.loads(process.stdout.read(size))
    finally:
        watchdog.cancel()


try:
    fixtures = json.loads(args.manifest.read_text())
    warmup = predict((args.manifest.parent / fixtures[0]["image"]).read_bytes())
    if "error" in warmup:
        raise RuntimeError(warmup["error"])
    results = []
    for fixture in fixtures:
        payload = (args.manifest.parent / fixture["image"]).read_bytes()
        started = time.perf_counter()
        response = predict(payload)
        elapsed = time.perf_counter() - started
        results.append({
            **fixture,
            **response,
            "expected_latex": fixture["latex"],
            "latex": response.get("latex"),
            "worker_seconds": elapsed,
            "structurally_correct": None,
        })
        print(fixture["id"], round(elapsed, 3), flush=True)
        args.output.write_text(json.dumps({"model": args.model_name, "preprocessing": args.preprocessing,
            "platform": platform.platform(), "architecture": platform.machine(), "python": platform.python_version(),
            "timing_scope": "Warm pipe round trip including PNG decoding and inference. Excludes capture, Swift PNG encoding and clipboard write.",
            "results": results,
            "release_gate": "PENDING_MANUAL_REVIEW_AND_END_TO_END_TIMING"}, indent=2) + "\n")
finally:
    try:
        process.stdin.close()
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    finally:
        process.stdout.close()
