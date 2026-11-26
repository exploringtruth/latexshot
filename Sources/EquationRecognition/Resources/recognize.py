"""Persistent local recognition worker. Crops travel only over anonymous pipes."""
import io
import json
import os
import struct
import sys

# Reserve stdout exclusively for the framed response protocol, including native logs.
protocol = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["DISABLE_MODEL_SOURCE_CHECK"] = "True"


def respond(value):
    payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
    protocol.write(struct.pack(">I", len(payload)) + payload)


def read_exact(length):
    data = bytearray()
    while len(data) < length:
        chunk = sys.stdin.buffer.read(length - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def load_pix2text(model_dir):
    import hashlib
    import platform
    from pathlib import Path

    if platform.machine() != "arm64":
        raise RuntimeError("Pix2Text requires arm64 Python")
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

    # Pix2Text-MFR 1.5 revision 1cef9f0bdcd6a4c63df7de1311fb0894593340cc.
    lock = json.loads(Path(__file__).with_name("pix2text-model-lock.json").read_text())
    directory = Path(model_dir)
    if {path.name for path in directory.iterdir()} != set(lock):
        raise RuntimeError("Unexpected contents in the pinned Pix2Text model directory")
    for name, expected in lock.items():
        path = directory / name
        if len(expected) == 64:
            with path.open("rb") as file:
                actual = hashlib.file_digest(file, "sha256").hexdigest()
        else:
            data = path.read_bytes()
            actual = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Pinned Pix2Text model checksum mismatch: {name}")

    from optimum.onnxruntime import ORTModelForVision2Seq
    from transformers import TrOCRProcessor

    processor = TrOCRProcessor.from_pretrained(directory, local_files_only=True)
    model = ORTModelForVision2Seq.from_pretrained(
        directory, use_cache=False, provider="CPUExecutionProvider", local_files_only=True
    )
    print("Pix2Text-MFR 1.5 ready (ONNX CPU)", file=sys.stderr, flush=True)

    def predict(image):
        pixels = processor(images=image, return_tensors="pt").pixel_values
        ids = model.generate(pixels)
        return processor.batch_decode(ids, skip_special_tokens=True)[0]

    return predict


def load_paddle(model_dir):
    import numpy as np
    from PIL import ImageOps
    from paddlex import create_model
    import yaml

    # Explicit local path prevents a missing model from initiating a download.
    for name in ("inference.json", "inference.pdiparams", "inference.yml"):
        if not os.path.isfile(os.path.join(model_dir, name)):
            raise RuntimeError("Recognition model is incomplete")
    with open(os.path.join(model_dir, "inference.yml"), encoding="utf-8") as source:
        name = yaml.safe_load(source)["Global"]["model_name"]
    if name not in ("PP-FormulaNet-S", "PP-FormulaNet-L"):
        trial_flag = {
            "PP-FormulaNet_plus-S": "LATEXSHOT_ALLOW_PLUS_S_TRIAL",
            "PP-FormulaNet_plus-M": "LATEXSHOT_ALLOW_PLUS_M_TRIAL",
            "PP-FormulaNet_plus-L": "LATEXSHOT_ALLOW_PLUS_L_TRIAL",
        }.get(name)
        if trial_flag is None or os.environ.get(trial_flag) != "1":
            raise ValueError("Unsupported recognition model")
    model = create_model(model_name=name, model_dir=model_dir, device="cpu")

    def predict(image):
        # Preprocessing v1. Invert uniformly dark page backgrounds before the
        # upstream resize/normalization. The benchmark uses this same worker.
        gray = np.asarray(image.convert("L"))
        border = np.concatenate((gray[0], gray[-1], gray[:, 0], gray[:, -1]))
        if np.median(border) < 128:
            image = ImageOps.invert(image)
        # PaddleX's ndarray reader expects BGR and converts it to RGB itself.
        bgr = np.asarray(image)[:, :, ::-1].copy()
        return next(iter(model.predict(bgr, batch_size=1)))["rec_formula"]

    return predict


def main():
    from PIL import Image

    model_dir = sys.argv[1]
    use_pix2text = sys.argv[2:] == ["pix2text"] or os.environ.get("LATEXSHOT_ALLOW_PIX2TEXT_TRIAL") == "1"
    load_model = load_pix2text if use_pix2text else load_paddle
    predict = load_model(model_dir)
    while True:
        try:
            length = struct.unpack(">I", read_exact(4))[0]
        except EOFError:
            return
        if not 0 < length <= 64 * 1024 * 1024:
            raise ValueError("Invalid crop frame size")
        payload = read_exact(length)
        try:
            with Image.open(io.BytesIO(payload)) as image:
                body = predict(image.convert("RGB"))
            if not isinstance(body, str) or not body.strip() or "\x00" in body:
                raise ValueError("Model returned an empty or invalid formula")
            if "[object Object]" in body or "[[object Object]]" in body:
                raise ValueError("Model returned an invalid decoder token")
            respond({"latex": body})
        except Exception:
            # Do not include crop contents or prediction text in diagnostics.
            respond({"error": "The equation could not be recognized. Try another selection.",
                     "recoverable": True})


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        respond({"error": "Offline recognition could not start (" + type(error).__name__ + ")."})
        sys.exit(1)
