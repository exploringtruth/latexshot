#!/usr/bin/env python3
"""Stage LaTeXShot's locked arm64 Pix2Text runtime and model on macOS."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "docs/runtime/pix2text-lock.json"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def matches(path, entry):
    return path.is_file() and path.stat().st_size == entry["bytes"] and digest(path) == entry["sha256"]


def fetch(entry, cache):
    target = cache / entry["filename"]
    if matches(target, entry):
        return
    if urlsplit(entry["url"]).scheme != "https":
        raise ValueError(f"Expected an HTTPS URL for {target.name}")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
            temporary = Path(output.name)
            with urlopen(entry["url"], timeout=60) as response:
                if urlsplit(response.url).scheme != "https":
                    raise ValueError(f"Non-HTTPS redirect for {target.name}")
                shutil.copyfileobj(response, output)
        if not matches(temporary, entry):
            raise ValueError(f"Size or SHA-256 mismatch for {target.name}")
        temporary.replace(target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def install_python(lock, cache, stage):
    with tarfile.open(cache / lock["python"]["filename"]) as source:
        source.extractall(stage, filter="data")
    runtime = stage / "RecognitionRuntime"
    (stage / "python").rename(runtime)
    # pip creates console launchers containing the staging path. The app runs
    # the interpreter itself. Remove those launchers after installation.
    python = runtime / "bin/python3"
    requirements = stage / "requirements.txt"
    requirements.write_text("".join(
        f"{entry['name']}=={entry['version']} --hash=sha256:{entry['sha256']}\n" for entry in lock["wheels"]
    ))
    offline_python = [
        "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
        str(python), "-I", "-B",
    ]
    environment = {"PATH": "/usr/bin:/bin", "PIP_CONFIG_FILE": os.devnull}
    subprocess.run(
        offline_python + ["-m", "pip", "install", "--disable-pip-version-check", "--no-compile",
                          "--no-deps", "--no-index", "--find-links", str(cache), "--require-hashes",
                          "-r", str(requirements)],
        env=environment, check=True
    )
    subprocess.run(offline_python + ["-m", "pip", "check"], env=environment, check=True)
    requirements.unlink()
    for path in (runtime / "bin").iterdir():
        if path.name not in {"python", "python3", "python3.12"}:
            path.unlink()
    return runtime


def copy_notices(lock, cache, runtime):
    notices = runtime / "ThirdPartyNotices"
    notices.mkdir()
    # Astral ships the embedded libraries' notices in the corresponding full
    # archive. Extract only those files using the macOS tar's zstd support.
    subprocess.run(
        ["/usr/bin/tar", "-xf", str(cache / lock["python_licenses"]["filename"]),
         "-C", str(notices), "--strip-components", "1", "python/licenses", "python/PYTHON.json"],
        check=True
    )
    sources = notices / "sources"
    sources.mkdir()
    for entry in lock["sources"]:
        shutil.copyfile(cache / entry["filename"], sources / entry["filename"])
    for entry in lock["notices"]:
        shutil.copyfile(cache / entry["filename"], notices / entry["filename"])
    shutil.copyfile(ROOT / "docs/runtime/pix2text-NOTICES.md", notices / "README.md")
    shutil.copyfile(LOCK, notices / LOCK.name)


def assemble(destination, cache):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Use arm64 Python on an Apple silicon Mac")
    if destination.exists():
        raise ValueError(f"Use a new destination: {destination}")
    lock = json.loads(LOCK.read_text())
    entries = [lock["python"], lock["python_licenses"], *lock["wheels"], *lock["model"],
               *lock["notices"], *lock["sources"]]
    cache.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda entry: fetch(entry, cache), entries))

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pix2text-assembly-", dir=destination.parent) as working:
        stage = Path(working) / "stage"
        stage.mkdir()
        runtime = install_python(lock, cache, stage)
        model = stage / "RecognitionModel"
        model.mkdir()
        for entry in lock["model"]:
            shutil.copyfile(cache / entry["filename"], model / entry["filename"])
        for entry in lock["remove_rpaths"]:
            binary = str(runtime / entry["file"])
            subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", entry["path"], binary], check=True)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", binary], check=True)
        copy_notices(lock, cache, runtime)
        stage.rename(destination)

    print(f"Recognition runtime: {destination / 'RecognitionRuntime'}")
    print(f"Recognition model: {destination / 'RecognitionModel'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="New directory for RecognitionRuntime and RecognitionModel")
    parser.add_argument("--cache", required=True, type=Path, help="Reusable download directory")
    args = parser.parse_args()
    try:
        assemble(args.destination.resolve(), args.cache.resolve())
    except (ValueError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
