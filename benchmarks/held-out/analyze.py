"""Apply provisional reviews only to the exact frozen inputs and predictions."""
import hashlib
import json
import math
from pathlib import Path

root = Path(__file__).parent
reviews = json.loads((root / "reviews.json").read_text())
summary = {"status": "Provisional agent review; independent review pending",
    "release_approved": False, "app_latency_target_seconds": 0.8,
    "latency_target_scope": "Mouse-up to clipboard, including first capture",
    "timing_limitation": "Recorded times are warm worker pipe round trips. Cold start and app end-to-end timing are outside this measurement.",
    "training_overlap": "Unknown. Public source exclusion from training cannot be proven.", "suites": {}}
for suite, folder in (("wikipedia", root), ("hefferon-pdf", root / "pdf")):
    manifest = (folder / "manifest.json").read_bytes()
    freeze = json.loads((folder / "freeze.json").read_text())
    if hashlib.sha256(manifest).hexdigest() != freeze["manifest_sha256"]:
        raise SystemExit("Frozen manifest changed for " + suite)
    variants = {}
    for variant in ("baseline", "ink-cap-36", "ink-cap-48"):
        name = variant + "-" + suite + ".json"
        rows = json.loads((folder / "results" / name).read_text())["results"]
        expected = json.loads(manifest)
        if [(r["id"], r["expected_latex"]) for r in rows] != [(r["id"], r["latex"]) for r in expected]:
            raise SystemExit("Expected formulas changed in " + name)
        predictions = [[r["id"], r["expected_latex"], r.get("latex"), r.get("error")] for r in rows]
        fingerprint = hashlib.sha256(json.dumps(predictions, ensure_ascii=False).encode()).hexdigest()
        review = reviews["files"][name]
        if fingerprint != review["prediction_sha256"]:
            raise SystemExit("Predictions require fresh review in " + name)
        labels = {case["id"]: case["structurally_correct"] for case in review["cases"]}
        if set(labels) != {r["id"] for r in rows}:
            raise SystemExit("Incomplete review in " + name)
        times = sorted(r["worker_seconds"] for r in rows)
        categories = {}
        for row in rows:
            category = categories.setdefault(row["category"], {"correct": 0, "incorrect": 0, "pending": 0})
            label = labels[row["id"]]
            category["pending" if label is None else "correct" if label else "incorrect"] += 1
        correct = sum(label is True for label in labels.values())
        pending = sum(label is None for label in labels.values())
        variants[variant] = {"correct": correct, "pending": pending, "total": len(rows),
            "provisional_confirmed_accuracy": correct / len(rows),
            "warm_worker_p95_seconds": times[math.ceil(0.95 * len(times)) - 1], "categories": categories,
            "failed_cases": [case for case in review["cases"] if case["structurally_correct"] is False]}
    summary["suites"][suite] = variants
(root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
for suite, variants in summary["suites"].items():
    for variant, values in variants.items():
        print(suite, variant, values["correct"], "/", values["total"], "pending", values["pending"])
