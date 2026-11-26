"""Prepare an isolated development runtime. Run with an arm64 Python 3.12."""
import argparse
from pathlib import Path
import platform
import subprocess
import sys
import venv

parser = argparse.ArgumentParser()
parser.add_argument("destination", type=Path)
args = parser.parse_args()
if sys.version_info[:2] != (3, 12) or platform.machine() != "arm64":
    raise SystemExit("Use an Apple silicon Python 3.12 interpreter")
destination = args.destination.resolve()
venv.create(destination / "RecognitionRuntime", with_pip=True)
python = destination / "RecognitionRuntime/bin/python3"
subprocess.run([str(python), "-m", "pip", "install", "-r",
                str(Path(__file__).with_name("requirements-lock.txt"))], check=True)
subprocess.run([sys.executable, str(Path(__file__).with_name("prepare-model.py")),
                str(destination / "RecognitionModel")], check=True)
print("Set LATEXSHOT_RECOGNITION_PYTHON to", python)
print("Set LATEXSHOT_MODEL_DIRECTORY to", destination / "RecognitionModel")
