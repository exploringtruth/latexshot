# PP-FormulaNet_plus-M local trial

The trial worker requires `LATEXSHOT_ALLOW_PLUS_M_TRIAL=1` to load
`PP-FormulaNet_plus-M`. Use an explicit local model directory and the
isolated arm64 Python 3.12 environment. The worker uses PaddleX on CPU,
with the existing crop preprocessing and malformed-output checks.

The [model lock](model-lock.json) records revision
`712e6e2e4c313b1ea163be5c350127b82662c58d` and five SHA-256 digests.
The weight digest matches the publisher's LFS SHA-256. The other files
match the pinned revision's Git blob IDs, and the lock records the SHA-256
of each of those downloads.
[Pinned publisher metadata](https://huggingface.co/api/models/PaddlePaddle/PP-FormulaNet_plus-M/revision/712e6e2e4c313b1ea163be5c350127b82662c58d?blobs=true)

The verified local paths are:

```sh
LATEXSHOT_ALLOW_PLUS_M_TRIAL=1 \
LATEXSHOT_RECOGNITION_PYTHON=/private/tmp/latexshot-plus-m-trial/venv/bin/python \
LATEXSHOT_MODEL_DIRECTORY=/private/tmp/latexshot-plus-m-trial/model \
swift run
```

To restore the trial files in a different temporary directory, use:

```sh
trial_dir="$(mktemp -d /tmp/latexshot-plus-m.XXXXXX)"
python3.12 -m venv "$trial_dir/venv"
"$trial_dir/venv/bin/python" -m pip install -r benchmarks/requirements-lock.txt
"$trial_dir/venv/bin/python" -m pip check
python3.12 benchmarks/prepare-model.py "$trial_dir/model" --lock benchmarks/plus-m-trial/model-lock.json
```

[Smoke evidence](smoke.json) records the framed worker output with networking
blocked using the [official sample image](https://cdn-uploads.huggingface.co/production/uploads/68493f0616e67d38f02f138a/4kkIUGxXMGozIg6U1BIxZ.png).

## Frozen benchmark

```sh
trial_dir=/private/tmp/latexshot-plus-m-trial
"$trial_dir/venv/bin/python" -B benchmarks/plus-m-trial/run.py \
  --model "$trial_dir/model" --output "$trial_dir/benchmark.json"
```

Use a fresh output path for each run. Add `--validate-only` to verify the
five model artifacts, frozen manifests, crop hashes, and paired inputs
without starting inference. Asset installation needs network access.
The runner starts the app's Python worker under the macOS network-denial
sandbox and checkpoints the JSON after each response.

One worker processes 60 Wikipedia and six Hefferon PDF crops, followed
by the 48 frozen root recaptures. The ten `small-type` crops are a subset
of the 66 printed crops. The first Wikipedia crop is sent once while
the worker starts, then counted once in the warm samples. Warm p95 uses
the nearest rank across completed requests, including errors. Cold timing
covers worker spawn to first response. The product's 0.8-second gate
measures mouse-up to clipboard write and requires a separate app test.

Printed scoring compares the prediction with the visible crop and its
frozen LaTeX. Allow equivalent commands, grouping, spacing, cosmetic
punctuation, and delimiter sizing. Require the same mathematical
symbols, operands, operations, scripts, bounds, delimiters, and
row and column structure. Malformed LaTeX or a recognition error fails
the case. The printed gate requires 63 of 66. The root repeat gate uses
literal equality with `\sqrt{x+1}+\sqrt[3]{y}=1` for every crop.

The paired experiment sends 2× Lanczos versions of the three small-type
crops with the shortest minor dimensions and the two tight 24px 1× root
crops, one light and one dark. This tests sensitivity to interpolation
before the model's resize with the crop boundaries, aspect ratio, and
underlying glyph information held fixed. Each pair shares the same
worker. The five variants sit outside the frozen accuracy and timing
gates.

## Results on Apple M5

Plus-M remains a local trial. The printed score was **62/66 (93.9%)**,
one case short of the 95% gate. All 119 responses rendered in
KaTeX 0.19.1. Four rendered predictions still changed the math or its
structure. The independent review identified the same four misses.
[Raw responses](results.json) and [structural review](review.json)

| Frozen suite | Structural accuracy | Literal root matches | Warm worker p95 |
| --- | ---: | ---: | ---: |
| Printed total | 62/66 | — | 2.592 s |
| Wikipedia | 58/60 | — | 2.592 s |
| Hefferon PDF | 4/6 | — | 1.342 s |
| Small type (subset) | 10/10 | — | 1.027 s |
| Root recaptures | 48/48 | 32/48 | 0.648 s |

The other 16 root responses added equivalent braces around both
radicals. The same frozen inputs yielded 42/66 structurally correct
printed predictions and 48 recoverable root errors in the prior guarded
plus-S run. [Plus-S diagnosis](../plus-s-screen/diagnosis/README.md)

Cold worker spawn to first response took **38.779 s** on the first
Wikipedia crop. The worker figures exclude physical capture, Swift PNG
encoding, clipboard write, and rendering. In the separate controlled app
check, the app track measured **14.34 s** during startup and **2.46 s**
warm for the official sample crop to a private pasteboard. These
controlled measurements exceed 0.8 s and leave physical
mouse-up-to-clipboard timing and launch-to-ready verification open.

All five original and upscaled pairs kept the same mathematical
structure. Three small-type variants changed formatting. The tight
dark cube root changed from equivalent braces to a literal match.
The tight light cube root kept the same braced output.
