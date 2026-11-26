#!/usr/bin/env python3
"""Fail closed on missing, stale, or incomplete public release evidence."""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
PLUS_S = "PaddlePaddle/PP-FormulaNet_plus-S"
PLUS_S_LOCK = Path("benchmarks/plus-s-screen/model-lock.json")
PIX2TEXT_VERSION = "1.0.0"
PIX2TEXT = "breezedeus/pix2text-mfr-1.5"
PIX2TEXT_REVISION = "1cef9f0bdcd6a4c63df7de1311fb0894593340cc"
PIX2TEXT_LOCK = Path("Sources/EquationRecognition/Resources/pix2text-model-lock.json")
ARCHIVES = ("runtime", "model")
CHECKS = ("icon_selected", "user_trial_passed", "clean_account_install_passed",
          "login_both_states_passed", "manual_update_passed", "scheduled_update_passed",
          "packaged_update_relaunch_passed", "offline_runtime_verified")


def validate(root, version):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        raise ValueError("Expected MAJOR.MINOR.PATCH version")
    record = json.loads((root / "docs/releases" / f"v{version}.json").read_text())
    if record.get("version") != version:
        raise ValueError("Readiness record version does not match")
    if record.get("distribution_signing") != "adhoc-unnotarized":
        raise ValueError("Only the documented adhoc-unnotarized distribution is configured")
    for key in CHECKS:
        check = record.get(key, {})
        if check.get("passed") is not True:
            raise ValueError(f"Release blocked: {key}")
        evidence = check.get("evidence", "")
        path = (root / evidence).resolve()
        if not evidence or not path.is_relative_to(root.resolve()) or not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing repository evidence for {key}")
    benchmark = record.get("benchmark", {})
    model = benchmark.get("model")
    if version == "0.1.0" and model != PLUS_S:
        raise ValueError(f"v{version} requires benchmark.model to be {PLUS_S}")
    if version == PIX2TEXT_VERSION:
        if model != PIX2TEXT or benchmark.get("model_revision") != PIX2TEXT_REVISION:
            raise ValueError(f"v{version} requires {PIX2TEXT} revision {PIX2TEXT_REVISION}")
    if not isinstance(model, str) or not model.strip():
        raise ValueError("Identify the benchmarked release model")
    correct_fraction = benchmark.get("correct_fraction")
    if (type(benchmark.get("printed_crops")) is not int or benchmark["printed_crops"] < 60 or
            type(correct_fraction) not in (int, float) or not 0.95 <= correct_fraction <= 1):
        raise ValueError("Printed benchmark must cover >=60 crops and >=95% correct")
    warm = benchmark.get("warm_p95_seconds")
    first = benchmark.get("first_capture_seconds")
    cold = benchmark.get("cold_start_ready_seconds")
    if any(type(value) not in (int, float) or not math.isfinite(value) for value in (warm, first, cold)):
        raise ValueError("Missing or invalid benchmark timings: warm p95, first capture, and cold startup readiness")
    if not 0 < warm < 0.8 or not 0 < first < 0.8:
        raise ValueError("Printed benchmark requires warm p95 <0.8s and first capture <0.8s")
    if cold <= 0:
        raise ValueError("Record cold startup readiness separately from capture latency")
    if benchmark.get("timing_scope") != "mouse-up-to-clipboard-including-readiness-wait":
        raise ValueError("Benchmark capture timings must include mouse-up to clipboard and any readiness wait")
    evidence_fields = [
        ("printed benchmark", "evidence"),
        ("first capture", "first_capture_evidence"),
        ("cold startup readiness", "cold_start_evidence"),
    ]
    if model.strip() == PLUS_S:
        if benchmark["printed_crops"] != 66:
            raise ValueError("Plus-S requires the frozen 66-crop benchmark")
        repeats = benchmark.get("cube_root_exact_repeats")
        if type(repeats) is not int or repeats != 48:
            raise ValueError("Plus-S requires 48 exact cube-root recaptures")
        evidence_fields.extend([
            ("Plus-S decoder fix", "decoder_fix_evidence"),
            ("Plus-S repeat-capture", "repeat_capture_evidence"),
        ])
    for label, field in evidence_fields:
        evidence = benchmark.get(field, "")
        path = (root / evidence).resolve()
        if not evidence or not path.is_relative_to(root.resolve()) or not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing {label} evidence")
    for asset in ("Assets/Icon/LaTeXShot.icns", "Assets/Icon/LaTeXShot.png", "Assets/Icon/LaTeXShotMenuBar.pdf", f".github/release-notes/v{version}.md", "Package.resolved"):
        if not (root / asset).is_file() or not (root / asset).stat().st_size:
            raise ValueError(f"Missing release input: {asset}")
    if version == PIX2TEXT_VERSION:
        archive_checksums(record)
        if not (root / PIX2TEXT_LOCK).is_file():
            raise ValueError(f"Missing release input: {PIX2TEXT_LOCK}")
    return record


def archive_checksums(record):
    archives = record.get("recognition_archives", {})
    if not isinstance(archives, dict):
        raise ValueError("Expected recognition_archives to contain the reviewed archive checksums")
    for kind in ARCHIVES:
        checksum = archives.get(f"{kind}_sha256", "")
        if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ValueError(f"Missing or invalid release {kind} archive SHA-256")
    return {kind: archives[f"{kind}_sha256"] for kind in ARCHIVES}


def check_archive_configuration(record):
    for kind, expected in archive_checksums(record).items():
        name = f"RECOGNITION_{kind.upper()}_SHA256"
        if os.environ.get(name, "").lower() != expected:
            raise ValueError(f"{name} must match the version's reviewed archive checksum")


def stage_release_assets(record, archives, destination):
    for kind, expected in archive_checksums(record).items():
        archive_path = archives / f"{kind}.tar.gz"
        if archive_path.is_symlink() or not archive_path.is_file():
            raise ValueError(f"Missing pinned recognition archive: {archive_path}")
        with archive_path.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != expected:
                raise ValueError(f"Release {kind} archive checksum mismatch: {archive_path}")
            stream.seek(0)
            with tarfile.open(fileobj=stream, mode="r:gz") as archive:
                archive.extractall(destination / kind, filter="data")


def validate_staged_pix2text(root, resources):
    source_lock = (root / PIX2TEXT_LOCK).read_bytes()
    packaged_lock = resources / "LaTeXShot_EquationRecognition.bundle/Contents/Resources/Resources/pix2text-model-lock.json"
    if packaged_lock.is_symlink() or packaged_lock.read_bytes() != source_lock:
        raise ValueError("Packaged Pix2Text model lock differs from the release source")
    lock = json.loads(source_lock)
    model_dir = resources / "RecognitionModel"
    if model_dir.is_symlink() or not lock or {path.name for path in model_dir.iterdir()} != set(lock):
        raise ValueError("Staged Pix2Text model directory must contain exactly the pinned files")
    for name, expected in lock.items():
        path = model_dir / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Invalid staged Pix2Text model file: {path}")
        if re.fullmatch(r"[0-9a-f]{64}", expected):
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
        elif re.fullmatch(r"[0-9a-f]{40}", expected):
            # The small model configuration files are pinned by their Git blob OIDs.
            data = path.read_bytes()
            digest = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        else:
            raise ValueError(f"Invalid Pix2Text model lock digest: {name}")
        if digest != expected:
            raise ValueError(f"Staged Pix2Text model checksum mismatch: {name}")


def validate_staged_plus_s(root, model_dir):
    lock = json.loads((root / PLUS_S_LOCK).read_text())
    if lock["repository"] != PLUS_S or not lock["files"]:
        raise ValueError(f"Expected a populated model lock for {PLUS_S}")
    for entry in lock["files"]:
        path = model_dir / entry["name"]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != entry["bytes"]:
            raise ValueError(f"Missing or invalid pinned model file: {path}")
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != entry["sha256"]:
            raise ValueError(f"Pinned model file checksum mismatch: {path}")
    unexpected = sorted({path.name for path in model_dir.iterdir()} -
                        {entry["name"] for entry in lock["files"]})
    if unexpected:
        raise ValueError(f"Unexpected staged model files: {', '.join(unexpected)}")


def public_key(value):
    try:
        key = base64.b64decode(value, validate=True)
    except ValueError as exc:
        raise ValueError("SPARKLE_PUBLIC_ED_KEY must be base64") from exc
    if len(key) != 32 or key == bytes(32):
        raise ValueError("SPARKLE_PUBLIC_ED_KEY must be a real 32-byte Ed25519 public key")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--check-archive-configuration", action="store_true")
    operation.add_argument("--stage-archives", nargs=2, type=Path, metavar=("ARCHIVES", "DESTINATION"))
    args = parser.parse_args()
    try:
        record = validate(ROOT, args.version)
        if args.check_archive_configuration:
            if args.version == PIX2TEXT_VERSION:
                check_archive_configuration(record)
        elif args.stage_archives:
            stage_release_assets(record, *args.stage_archives)
        print(f"Readiness evidence accepted for v{args.version}")
    except (ValueError, OSError, TypeError, tarfile.TarError) as exc:
        sys.exit(str(exc))
