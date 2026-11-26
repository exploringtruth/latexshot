# Crop normalization study

Both candidate variants remain rejected for production. A 36px ink-height cap
improves the repeated-equation case but breaks a previously correct fraction.
A 48px cap preserves the baseline's correct corpus cases but still fails one
third of the recaptures. The production worker and model configuration retain
their existing behavior.

## Paired results

All scores are provisional structural review using the existing relaxed
alignment rubric. Equivalent syntax and extra grouping are accepted. Array rows
preserving both equations are accepted even if the alignment markers differ.

| Preprocessing | One equation, 48 recaptures | Existing 60 fixtures | Corpus gains | Corpus regressions |
| --- | --- | --- | --- | --- |
| Production baseline | 12/48 (25.0%) | 37/60 (61.7%) | 0 | 0 |
| Ink crop and 36px cap | 44/48 (91.7%) | 57/60 (95.0%) | 21 | 1 |
| Ink crop and 48px cap | 32/48 (66.7%) | 57/60 (95.0%) | 20 | 0 |

The 36px variant's corpus failures are `fractions-09`, `roots-07` and
`dark-background-10`. Its `fractions-09` prediction regresses a previously correct
formula into malformed fraction syntax. The 48px variant's failures are
`aligned-01`, `roots-07` and `dark-background-10`. All recapture failures change or
drop the cube-root index or otherwise corrupt the second root.

Independent review reconciled the 36px corpus tally to 57/60. All ten matrix
predictions had the same bundled KaTeX MathML table structure as their expected
formulas. The retained labels remain provisional. `reviews.json` stores labels
and fingerprints of the reviewed expected/predicted text. `analyze.py` refuses
to apply these labels if a rerun changes any prediction.

Warm worker p95 times in this run ranged from 0.133 to 0.207 seconds on recaptures
and 0.159 to 0.165 seconds on the corpus. These are warm pipe round trips. The
timer excludes capture, Swift PNG encoding and clipboard write. These numbers
cannot establish the end-to-end product latency gate.

## Experimental boundary

The fixed PP-FormulaNet-S artifact and dependency environment are the same as the
original benchmark. Production preprocessing inverts dark outer borders before
the upstream transforms. The two experiments additionally detect ink at least
32 luminance levels darker than the median border, crop its bounding box,
downsample tall crops to a maximum ink height, and restore symmetric padding of
13% of the resulting ink height with a minimum of four pixels. Small crops are
never upsampled. The compared caps are 36 and 48 pixels.

The 36px cap came from the lead's earlier repeated-root investigation. The 48px
challenge was selected before this paired run to test whether retaining more
detail helps stacked structures. Both were evaluated on both complete suites.
No thresholds were changed after inspecting these results. `run.py` derives
temporary workers from the production source, records source/model-lock hashes,
and leaves production files untouched.

The 48 recaptures contain one equation rendered by Chrome MathML. They span
three CSS font sizes, light/dark colors, 1x/2x rasterization, and four asymmetric
drag margins. Every crop contains the complete equation. They exercise image
variation while holding mathematical content fixed. These observations are
correlated and cannot be treated as 48 independent equations. The 60 existing
fixtures also use related synthetic templates and were already used during
development. No pooled accuracy or statistical generalization claim is made.

The saved recaptures reproduce the user's equation, while the browser page and
equation assets are author-created. The mathematical fixture content is CC0-1.0.
The archived PNG hashes are in `recaptures/manifest.json`. The recapture script
was verified to regenerate all 48 PNGs with identical pixel values on this Mac.
`capture-verification.json` records the browser version and this check. Browser
profiles and screenshots used during regeneration remain outside the repository.

## Reproduce

Use the runtime and pinned model preparation instructions in the parent benchmark
README. Evaluate both suites and all three variants with the same interpreter.

```sh
/tmp/latexshot-recognition-venv/bin/python benchmarks/preprocessing-study/run.py \
  --python /tmp/latexshot-recognition-venv/bin/python \
  --model /tmp/latexshot-PP-FormulaNet-S \
  --output benchmarks/preprocessing-study/results
python3 benchmarks/preprocessing-study/analyze.py
```

Regenerate the recaptures into a separate directory with the pinned environment's
Pillow and an installed Chrome. Rendering can change with browser and system font
versions, so retain the archived crops for comparisons of model behavior.

```sh
/tmp/latexshot-recognition-venv/bin/python benchmarks/preprocessing-study/recapture.py \
  --output /tmp/latexshot-recaptured
```

## Next independent evaluation

Freeze the next candidate before collecting held-out printed crops from real
PDFs and websites. Include distinct equations across all six product categories,
record source provenance and expected LaTeX, and retain complete capture geometry
and display scale. Review mathematical content and matrix/alignment structure
independently, then measure mouse-up to clipboard write on the native app path.
Keep the repeated-root suite as a regression check. A candidate needs the
product accuracy and latency gates on the independent corpus before release
promotion. The current results support further investigation of normalization.
