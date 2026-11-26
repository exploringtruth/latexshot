"""Summarize frozen manual labels, refusing labels for changed predictions."""
import hashlib
import json
import math
from pathlib import Path

directory = Path(__file__).parent
reviews = json.loads((directory / "reviews.json").read_text())
summary = {
    "review_status": reviews["status"],
    "selection": "No production promotion",
    "limitations": [
        "The 48 recaptures repeat one equation and are correlated observations.",
        "The 60 fixtures use related synthetic templates and were already used in development.",
        "Scores are provisional structural review and do not estimate independent product accuracy.",
        "Warm worker timing excludes capture, Swift PNG encoding and clipboard write.",
    ],
    "suites": {},
}
for suite in ("recaptures", "fixtures"):
    variants = {}
    baseline_correct = None
    for variant in ("baseline", "ink-cap-36", "ink-cap-48"):
        name = variant + "-" + suite + ".json"
        data = json.loads((directory / "results" / name).read_text())
        reviewed = reviews["files"][name]
        predictions = [[r["id"], r["expected_latex"], r.get("latex"), r.get("error")]
                       for r in data["results"]]
        fingerprint = hashlib.sha256(json.dumps(predictions, ensure_ascii=False).encode()).hexdigest()
        if fingerprint != reviewed["prediction_sha256"]:
            raise SystemExit("Predictions changed. Review again before scoring " + name)
        ids = {r["id"] for r in data["results"]}
        correct = set(reviewed["correct_ids"])
        if len(ids) != len(data["results"]) or not correct.issubset(ids):
            raise SystemExit("Invalid case identities in " + name)
        if baseline_correct is None:
            baseline_correct = correct
        times = sorted(r["worker_seconds"] for r in data["results"])
        variants[variant] = {
            "correct": len(correct), "total": len(ids), "provisional_accuracy": len(correct) / len(ids),
            "gains_over_baseline": sorted(correct - baseline_correct),
            "regressions_from_baseline": sorted(baseline_correct - correct),
            "failures": sorted(ids - correct),
            "warm_worker_p95_seconds": times[math.ceil(0.95 * len(times)) - 1],
            "release_approved": False,
        }
    summary["suites"][suite] = variants
(directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({suite: {variant: str(row["correct"]) + "/" + str(row["total"])
    for variant, row in variants.items()} for suite, variants in summary["suites"].items()}, indent=2))
