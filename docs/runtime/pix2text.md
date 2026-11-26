# Pix2Text arm64 recognition bundle

The runtime uses CPython 3.12.14 from Astral Python Standalone Builds and the
54 wheel versions from the native Pix2Text trial. The model is
`breezedeus/pix2text-mfr-1.5` revision
`1cef9f0bdcd6a4c63df7de1311fb0894593340cc`. The worker uses ONNX Runtime's
CPU execution provider with the same processor and generation settings as
the trial. In a packaged app, `LaTeXShotRecognitionBackend=pix2text` in
`Info.plist` selects the model and the app resolves both directories relative
to its own resources.

Build on Apple silicon with Python 3.12 or later and Xcode command line tools.
The destination must be new. The download directory can be reused.

```sh
python3 scripts/build-pix2text-runtime.py /private/tmp/latexshot-pix2text \
  --cache /private/tmp/latexshot-pix2text-downloads
```

Use the resulting `RecognitionRuntime` and `RecognitionModel` directories as
`RECOGNITION_RUNTIME_DIR` and `RECOGNITION_MODEL_DIR` for the packager. For
archive inputs, archive the contents of each directory so that the runtime
archive has `bin/python3` at its root and the model archive has
`encoder_model.onnx` at its root.

The builder verifies the size and SHA-256 of every upstream input, installs
wheels with network access denied, and runs `pip check`. It retains upstream
notices and includes [additional recognition notices](pix2text-NOTICES.md) in
`RecognitionRuntime/ThirdPartyNotices`. The worker verifies the eight model
files again before loading the model. Recognition uses isolated Python and
local model files. PNG crops and the response travel over anonymous pipes.

## Local verification

The runtime was copied to a new path containing spaces. With an empty home
directory and macOS sandbox rules blocking network access, Homebrew, the
original runtime and download locations, and the trial's environment and model
cache, the relocated worker reproduced six exact responses from the frozen
trial run in `e51e60c`. The samples covered fractions, roots, matrices, aligned
equations, small type, and dark backgrounds. A malformed PNG was rejected and
the same worker returned the expected result on the next request.

All 181 Mach-O files exposed an arm64 slice with an encoded minimum macOS
version at or below 14.0. The audit found no absolute non-system dynamic
library references or search paths. The Swift recognizer suite also passed
with the assembled runtime, covering real model inference and packaged mode
selection.

These checks cover assembly, relocation, and the recognition interface.
Recognition accuracy and end-to-end capture timing are tracked in the frozen
trial results.
