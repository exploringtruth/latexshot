"""Download the pinned candidate to a supplied build directory and verify every byte."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("destination", type=Path)
parser.add_argument("--lock", type=Path, default=Path(__file__).with_name("model-lock.json"))
args = parser.parse_args()
lock = json.loads(args.lock.read_text())
args.destination.mkdir(parents=True, exist_ok=True)
for entry in lock["files"]:
    target = args.destination / entry["name"]
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == entry["sha256"]:
        continue
    url = "https://huggingface.co/{}/resolve/{}/{}".format(
        lock["repository"], lock["revision"], entry["name"])
    temporary = target.with_suffix(target.suffix + ".download")
    try:
        urllib.request.urlretrieve(url, temporary)
        if temporary.stat().st_size != entry["bytes"] or hashlib.sha256(temporary.read_bytes()).hexdigest() != entry["sha256"]:
            raise RuntimeError("Artifact checksum mismatch: " + entry["name"])
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
print(args.destination.resolve())
