"""Paired preprocessing experiment. All variants derive from the production worker."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--python", required=True)
parser.add_argument("--model", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--manifest", type=Path)
parser.add_argument("--suite", default="held-out")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
worker = root / "Sources/EquationRecognition/Resources/recognize.py"
source = worker.read_text()
anchor = "            bgr = np.asarray(image)[:, :, ::-1].copy()"
if source.count(anchor) != 1:
    raise SystemExit("Production preprocessing changed. Review the experiment before rerunning.")
args.output.mkdir(parents=True, exist_ok=True)
normalization = """            luminance = np.asarray(image.convert("L"), dtype=np.int16)
            edges = np.concatenate((luminance[0], luminance[-1], luminance[:, 0], luminance[:, -1]))
            background = int(np.median(edges))
            rows, columns = np.where(luminance < background - 32)
            if rows.size:
                image = image.crop((int(columns.min()), int(rows.min()),
                                    int(columns.max()) + 1, int(rows.max()) + 1))
                if image.height > HEIGHT:
                    image = image.resize((max(1, round(image.width * HEIGHT / image.height)), HEIGHT),
                                         Image.Resampling.LANCZOS)
                image = ImageOps.expand(image, border=max(4, round(image.height * 0.13)), fill=(background,) * 3)
"""
suites = [("recaptures", Path(__file__).parent / "recaptures/manifest.json"),
          ("fixtures", root / "benchmarks/fixtures/manifest.json")]
if args.manifest:
    suites = [(args.suite, args.manifest.resolve())]
protocol = {
    "production_worker_sha256": hashlib.sha256(source.encode()).hexdigest(),
    "model_lock_sha256": hashlib.sha256((root / "benchmarks/model-lock.json").read_bytes()).hexdigest(),
    "variants": ["baseline", "ink-cap-36", "ink-cap-48"],
    "hypothesis": "Crop-margin normalization reduces drag variance. A 48px cap may retain stacked-symbol detail lost by 36px downsampling.",
    "selection_rule": "Reject promotion if any previously correct structure regresses. Both product accuracy and end-to-end latency gates plus independent corpus validation remain required.",
    "evaluation_sets": {name: len(json.loads(manifest.read_text())) for name, manifest in suites},
    "manifest_sha256": {name: hashlib.sha256(manifest.read_bytes()).hexdigest() for name, manifest in suites},
    "limitations": "See each corpus provenance. Public-source model training overlap is unknown. Scores require structural review and end-to-end timing.",
}
(args.output / "protocol.json").write_text(json.dumps(protocol, indent=2) + "\n")
with tempfile.TemporaryDirectory(prefix="latexshot-preprocessing-workers-") as temporary:
    for variant, height in (("baseline", None), ("ink-cap-36", 36), ("ink-cap-48", 48)):
        derived = source if height is None else source.replace(anchor, normalization.replace("HEIGHT", str(height)) + anchor)
        candidate = Path(temporary) / (variant + ".py")
        candidate.write_text(derived)
        for name, manifest in suites:
            subprocess.run([args.python, str(root / "benchmarks/evaluate.py"), "--python", args.python,
                            "--model", args.model, "--worker", str(candidate),
                            "--preprocessing", variant, "--manifest", str(manifest),
                            "--output", str(args.output / (variant + "-" + name + ".json"))], check=True)
