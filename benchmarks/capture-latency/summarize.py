#!/usr/bin/env python3
import json
import math
import statistics
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
if isinstance(report.get("cold"), list) and isinstance(report.get("warm"), list):
    cold = report["cold"]
    warm = report["warm"]
    cold_copy = sorted(row["mouseUpToCopyMs"] for row in cold)
    warm_copy = sorted(row["mouseUpToCopyMs"] for row in warm)
    warm_p95 = warm_copy[math.ceil(len(warm_copy) * 0.95) - 1]
    cold_p95 = cold_copy[math.ceil(len(cold_copy) * 0.95) - 1]
    print(json.dumps({
        "fixture": report["fixture"],
        "geometry": report["geometry"],
        "observedLaTeX": report["observedLaTeX"],
        "coldSamples": len(cold),
        "warmSamples": len(warm),
        "coldMouseUpToClipboard": {
            "median": statistics.median(cold_copy),
            "p95NearestRank": cold_p95,
            "minimum": cold_copy[0],
            "maximum": cold_copy[-1],
        },
        "warmMouseUpToClipboard": {
            "median": statistics.median(warm_copy),
            "p95NearestRank": warm_p95,
            "minimum": warm_copy[0],
            "maximum": warm_copy[-1],
        },
        "warmPass": warm_p95 < 800,
        "coldPass": cold_p95 < 800,
        "gateSeconds": 0.8,
    }, indent=2))
    sys.exit(0)

phases = {}
for key in report["cold"]:
    values = sorted(row[key] for row in report["warm"])
    phases[key] = {
        "median": statistics.median(values),
        "p95NearestRank": values[math.ceil(len(values) * 0.95) - 1],
        "minimum": values[0],
        "maximum": values[-1],
    }
print(json.dumps({
    "fixture": report["fixture"],
    "geometry": report["geometry"],
    "observedLaTeX": report["observedLaTeX"],
    "warmSamples": len(report["warm"]),
    "cold": report["cold"],
    "warm": phases,
}, indent=2))
