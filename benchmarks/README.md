# Recognition development and evidence

The public-source follow-up in `held-out/README.md` records 60 website cases and
six independently published PDF cases, with pre-inference source freezes,
license attribution, and provisional structural reviews. Neither preprocessing
candidate meets the release criteria on this material.

The crop-normalization follow-up in `preprocessing-study/README.md` compares
48 complete recaptures and the existing 60 fixtures. It records two rejected
preprocessing variants and preserves the production configuration.

The app boundary is `EquationRecognizing.recognize(CGImage) async throws -> String`.
`OfflineEquationRecognizer()` sends PNG bytes over anonymous pipes to one persistent
local PP-FormulaNet process. It returns the formula body for app-side wrapping.
The worker uses the upstream PaddleX preprocessing and tokenizer. Preprocessing
version 1 adds inversion when the median outer border is dark. Captures stay in
memory. Startup, malformed output, and worker termination return errors. The app
must preserve the clipboard on these errors.

## Run a local trial

Use Apple silicon Python 3.12. The following preparation downloads dependencies
and weights and needs network access. The destination is outside the checkout.

```sh
python3.12 benchmarks/prepare-development.py /tmp/latexshot-development
LATEXSHOT_RECOGNITION_PYTHON=/tmp/latexshot-development/RecognitionRuntime/bin/python3 \
LATEXSHOT_MODEL_DIRECTORY=/tmp/latexshot-development/RecognitionModel \
swift run LaTeXShot
```

For the current development machine, the already prepared paths are
`/tmp/latexshot-recognition-venv/bin/python` and
`/tmp/latexshot-PP-FormulaNet-S`.

The app looks for packaged resources `RecognitionRuntime/bin/python3` and
`RecognitionModel` when development variables are absent. A standard Python venv
references its creating interpreter. A release needs a relocatable runtime,
dependency licenses, code signing integration and clean-account verification.
The current setup prepares a machine-local development environment. The weights
and runtime are deliberately kept outside Git.

## Candidates and provenance

`model-lock.json` pins PP-FormulaNet-S to the official PaddlePaddle Hugging Face
revision and SHA-256 for each file. `model-large-lock.json` pins PP-FormulaNet-L.
Both official model cards declare Apache-2.0. The downloader validates length and
SHA-256 before replacing a local artifact. S parameters occupy 231,675,001 bytes.
L parameters occupy 724,452,527 bytes. Neither has been approved for release.

Official references

- https://huggingface.co/PaddlePaddle/PP-FormulaNet-S
- https://huggingface.co/PaddlePaddle/PP-FormulaNet-L
- https://github.com/PaddlePaddle/PaddleX/tree/v3.3.13/paddlex/inference/models/formula_recognition
- https://paddlepaddle.github.io/PaddleX/3.4/en/module_usage/tutorials/ocr_modules/formula_recognition.html

`requirements-lock.txt` records all versions installed for this run, including
PaddlePaddle 3.3.1 and PaddleX 3.3.13. The environment occupied approximately
1.1 GB before model weights. Binary dependency distribution licenses and runtime
portability require review during packaging.

## Printed fixtures

`fixtures/manifest.json` identifies 60 author-created printed equation crops,
ten in each required category. The fixture equations are dedicated to the public
domain under CC0-1.0. `printed.html` and `printed.pdf` contain their source
renderings. This is a controlled synthetic suite. Independent real PDF and
website capture coverage is still required before release. The PNGs were
rasterized directly from the same SVGs embedded in those documents. MathJax
3.2.2 is copyright the MathJax Consortium and distributed under the Apache 2.0
license included in `LICENSE-APACHE-2.0.txt`.

To regenerate with Node.js, install fixture-only tools in an external directory
and set `NODE_PATH` to that directory's `node_modules`.

```sh
npm install --prefix /tmp/latexshot-fixture-tools mathjax-full@3.2.2 sharp@0.34.5 pdfkit@0.17.2 svg-to-pdfkit@0.1.8
NODE_PATH=/tmp/latexshot-fixture-tools/node_modules node benchmarks/generate-fixtures.cjs
```

## Evaluate and verify

```sh
/tmp/latexshot-recognition-venv/bin/python benchmarks/evaluate.py \
  --python /tmp/latexshot-recognition-venv/bin/python \
  --model /tmp/latexshot-PP-FormulaNet-S --output /tmp/results-small.json
```

For L, prepare with `prepare-model.py DESTINATION --lock
benchmarks/model-large-lock.json` and pass `--model-name PP-FormulaNet-L` to
the evaluator. New result rows include `expected_latex` from the fixture manifest,
the model prediction in `latex`, and the warm pipe round-trip time. For the
checked-in baseline reports, match the crop ID to the manifest for expected LaTeX.
The first crop is used for warmup. These timings include
PNG decode, preprocessing, inference and pipe I/O. Capture, Swift PNG encoding,
clipboard write and popup rendering are outside this timer.

`structurally_correct` begins as null. Agent review is stored separately in
`reviews-small.json` and `reviews-large.json`. Equivalent matrix and array notation is accepted when
content and structure agree. Human review and the full product benchmark remain
required. Passing this suite alone cannot establish the 95% product target.

The Swift tests cover missing-runtime failure, early process exit with a large
crop followed by retry, and an optional real model prediction. Set both trial
environment variables when running `swift test` to run the model test.

All 60 S predictions were additionally verified under enforced network denial
using macOS `sandbox-exec` with `(version 1)(allow default)(deny network*)`.
`offline-verification.json` records this evidence. The worker receives only
explicit local model paths and disables model-source connectivity checks.

On the Apple M5 development Mac, the recorded S warm worker p95 was 0.208 seconds.
Provisional agent structural review accepted 37 of 60 predictions (61.7%).
The separate network-denied run completed 60 predictions with zero runtime
errors. Native Swift tests passed for real inference, missing runtime, and
repeated early worker exits with a 4 MB input image.

L completed the same 60 crops. Provisional agent review accepted 49 of 60
predictions (81.7%). Ten matrices were represented as binomial coefficients
containing spaced row contents, failing the matrix structure criterion. One
integral split the upper bound 10 into 1 and a zero inside the integrand.
The measured L warm worker p95 was approximately 3.87 seconds.
`summary.json` records both candidates and keeps release approval false.

## Release status

A follow-up screen tested PaddlePaddle's LaTeX_OCR_rec at revision
`563fb029dfdf5fc847d0677f3870039960e3a801`. The installed PaddleX forces an
unavailable MKL-DNN mode for this model, so the isolated test selected native
Paddle CPU mode. It ran all 60 controlled crops with outbound network access
denied. Warm worker p95 was 0.233 seconds. At least five checked crops changed
the math (fractions-01, roots-01, matrices-01, aligned-01 and
dark-background-01), so accuracy is at most 55/60 and this model fails the gate.
The app's configured model is unchanged.

Keep the app local. S shows structural errors on fractions, matrices and aligned
equations. L's warm inference alone exceeds two seconds on this machine.
The measured model has no calibrated confidence score, so a returned formula can
still be mathematically wrong. There is no selected release model or bundled
redistributable runtime yet. Handwriting support remains a follow-up release.
