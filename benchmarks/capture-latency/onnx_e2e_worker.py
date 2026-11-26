#!/usr/bin/env python3
"""Benchmark-only persistent CPU ONNX worker for native capture timing."""

import io
import json
import os
import struct
import sys
from pathlib import Path


PROTOCOL = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())


def read_exact(length):
    data = bytearray()
    while len(data) < length:
        chunk = sys.stdin.buffer.read(length - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def respond(value):
    payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
    PROTOCOL.write(struct.pack(">I", len(payload)) + payload)


def main():
    import numpy as np
    from PIL import Image
    import onnxruntime as ort

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from measure_onnx_load import preprocess_image

    model = sys.argv[1]
    session = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    output_names = [item.name for item in session.get_outputs()]

    while True:
        try:
            length = struct.unpack(">I", read_exact(4))[0]
        except EOFError:
            return
        if not 0 < length <= 64 * 1024 * 1024:
            raise ValueError("Invalid crop frame size")
        png = read_exact(length)
        try:
            image = Image.open(io.BytesIO(png)).convert("RGB")
            tensor = preprocess_image(image)
            outputs = session.run(output_names, {input_name: tensor})
            respond({
                "ok": True,
                "input_shape": list(tensor.shape),
                "output_shape": list(outputs[0].shape),
            })
        except Exception:
            respond({"ok": False})


if __name__ == "__main__":
    main()
