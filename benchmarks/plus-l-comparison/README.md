# PP-FormulaNet_plus-L offline comparison

This experiment compares the official plus-L Paddle inference model with the
archived plus-M run on the same frozen inputs. The original
`PP-FormulaNet-L` is a different checkpoint. The app trial uses its existing
settings.

The [model lock](model-lock.json) pins revision
`0809597a77f735bfb35354edb632f2e6dff606f3`. The weight SHA-256 matches
the publisher's LFS digest. The four other files match the Git blob IDs and
sizes in the pinned metadata. The runner checks the SHA-256 and size of all
five local files before loading the model.
[Pinned publisher metadata](https://huggingface.co/api/models/PaddlePaddle/PP-FormulaNet_plus-L/revision/0809597a77f735bfb35354edb632f2e6dff606f3?blobs=true)

## Reproduce

Use the [existing plus-M arm64 venv](../plus-m-trial/README.md) and its
verified model. Installing model files requires network access. Inference
runs in the worker's macOS network-denial sandbox. A separate loopback
connect probe under the same profile returned `EPERM`. The worker rejects
the plus-L model unless explicitly enabled with
`LATEXSHOT_ALLOW_PLUS_L_TRIAL=1`. The runner sets this flag for plus-L.

```sh
trial_dir=/private/tmp/latexshot-plus-m-trial
comparison_dir=/private/tmp/latexshot-plus-l-comparison
comparison=benchmarks/plus-l-comparison
runner=benchmarks/plus-m-trial/run.py
controls="$comparison/crop-controls/manifest.json"

"$trial_dir/venv/bin/python" -B benchmarks/prepare-model.py "$comparison_dir/model" \
  --lock "$comparison/model-lock.json"

PADDLE_PDX_CACHE_HOME="$comparison_dir/cache-l" "$trial_dir/venv/bin/python" -B "$runner" \
  --model "$comparison_dir/model" --model-lock "$comparison/model-lock.json" \
  --first-id fractions-08 --first-id roots-10 --first-id hefferon-04 --first-id hefferon-05 \
  --first-id root-1x-24px-light-2 --first-id root-1x-24px-dark-2 \
  --skip-upscaled --crop-manifest "$controls" --output "$comparison_dir/plus-l.json"

PADDLE_PDX_CACHE_HOME="$comparison_dir/cache-m" "$trial_dir/venv/bin/python" -B "$runner" \
  --model "$trial_dir/model" --controls-only --crop-manifest "$controls" \
  --output "$comparison_dir/controls-plus-m.json"
```

The six priority crops lead the plus-L run. One worker processes all
66 frozen printed crops and 48 frozen recaptures, then the 12 synthetic
trial controls. The runner repeats the first request warm after timing its
cold response. It measures from worker spawn to first response and from
request to response for warm samples. These measurements exclude macOS
capture and clipboard handling. The frozen printed target is 63/66 with
equivalent LaTeX accepted. Literal matches on the root suite are reported
alongside structural accuracy.

The [control manifest](crop-controls/manifest.json) describes 508 × 196
pixel headless browser crops using the same trial formulas at 13 and 24 CSS
pixels and device scale factor 2. Each pair has the same formula pixels and
crop geometry. The border changes 2,824 edge pixels and zero interior
pixels in all six pairs. The original live drag coordinates, partial edge
coverage, and browser rendering are unknown.

## Printed accuracy

Plus-L scored **58/66 (87.9%)**, below the 63/66 target. It recognized
54/60 Wikipedia crops and 4/6 PDF crops, including 8/10 small-type crops.
Plus-M's archived score was 62/66. This comparison's re-review scored the
same archived predictions at **61/66 (92.4%)** after confirming that both
models drop the second prime from the first integrand on `aligned-10`.
The archived plus-M results and review are preserved. A separate reviewer
agreed on all eight rejected plus-L cases.

| Previously reported plus-M miss | Plus-L output |
| --- | --- |
| `fractions-08` | Drops the cancellation marks and adds prime notation to the struck factors. |
| `roots-10` | Omits one fraction level from each continued fraction. |
| `hefferon-04` | Returns only the second of four equations. |
| `hefferon-05` | Retains all three equations and removes plus-M's spurious deltas. |

Relative to the re-reviewed plus-M baseline, plus-L repaired one crop and
regressed on four. It turned a mixed number into a power on
`fractions-01`, added superscript parallel bars on `small-type-03` and
`small-type-04`, and dropped two equations on `hefferon-02`.

## Root repeats and border controls

Plus-L and plus-M recognized the intended expression in **48/48** frozen
root recaptures. Plus-L returned the same braced LaTeX all 48 times,
yielding **0/48** literal matches to the frozen unbraced string. Plus-M
matched literally in **32/48** and used equivalent braces in the other 16.

Both models scored **12/12** on the synthetic controls. Within each model,
all six bordered outputs exactly matched their borderless partners. Neither
model produced an unwanted box or trailing empty array on these controls.
Plus-L matched the literal string on all four synthetic cube-root crops.
It appended a period to both 24 px root-fraction crops. Plus-M returned
equivalent LaTeX on all controls with zero literal matches.

All 126 plus-L predictions and 12 paired plus-M predictions parsed in
bundled KaTeX 0.19.1. The comparison verified that both models received
byte-identical inputs by SHA-256, including all frozen and control cases.
[Plus-L responses](results-plus-l.json), [plus-M control responses](controls-plus-m.json),
[case review](review.json)

## Worker timing

The run used an Apple M5 and the existing locked arm64 Python 3.12.14
environment with PaddlePaddle 3.3.1 and PaddleX 3.3.13. Plus-L took
19.022 seconds to its first response for `fractions-08`. Plus-M's archived
cold measurement started with `fractions-01`, so the two cold numbers
cover different inputs.

The live plus-L trial app launched during the benchmark at 17:38:49 UTC.
Its synthetic warm-up was complete by 17:39:21 UTC, and the app remained
available for user captures. The plus-L warm times are observational
because they may include CPU contention. The printed worker p95 was
10.291 seconds for plus-L and 2.592 seconds in the archived plus-M run.
The root p95 was 6.936 seconds for plus-L and 0.648 seconds for plus-M.
The control p95 was 7.007 seconds for plus-L and 1.958 seconds for plus-M.
These figures do not measure mouse-up to clipboard write. Plus-L remains a
local experiment.
