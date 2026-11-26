# Public-source printed-equation evaluation

This development holdout contains 60 website crops and six independently
published PDF crops. Expected LaTeX and source identities were frozen before
predictions. All three fixed PP-FormulaNet-S preprocessing configurations were
evaluated. None meets the release criteria.

## Provisional results

| Variant | Website cases | PDF cases |
| --- | --- | --- |
| Production baseline | 41/60 (68.3%) | 1/6 confirmed, one pending |
| Ink crop with 36px cap | 39/60 (65.0%) | 2/6 (33.3%) |
| Ink crop with 48px cap | 40/60 (66.7%) | 2/6 (33.3%) |

These are agent structural judgments. Independent review remains pending.
The rubric accepts equivalent syntax, harmless spacing/grouping and terminal
punctuation. It preserves operands, operators, indices, bounds and row/column
content. Equation alignment follows the earlier study's relaxed rubric. Upright
roman function names are accepted when the function content is unchanged.

The pending baseline PDF case `hefferon-05` has the right visible equations but
declares one array column while using two. Bundled KaTeX renders it with a
too-few-columns warning. It is excluded from the confirmed-correct count.
`reviews.json` records every decision and reason, with fingerprints tied to the
exact expected/predicted text. `analyze.py` verifies those fingerprints and both
frozen manifests before reproducing `summary.json`.

The 36px cap changes a previously correct series lower bound from 0 to 9,
corrupts a symbolic matrix, and damages a product derivation. It fixes one
dark-background grouping error. The 48px cap also damages the product
derivation. The earlier synthetic improvements did not generalize to this
new source material.

The current app target is less than 0.8 seconds from mouse-up to clipboard,
including the first capture. Saved `worker_seconds` values measure warm worker
pipe round trips. They exclude model startup, native capture, Swift PNG encoding
and clipboard write. These measurements cannot establish the app target.
No model, preprocessing or app configuration was promoted.

## Website provenance and reuse

The 60 equations come from independently authored Wikipedia articles. Ten cases
were selected in source order for each category before model predictions.
Categories cover fractions, roots, matrices, multirow aligned derivations,
small type and dark backgrounds. The selected mathematics is new to this
development evaluation. Public-source exclusion from model training is unknown.

`sources.json` retains article URLs, revision permalinks, source HTML hashes,
author attribution through page histories, footer license notices, and license
URLs. `manifest.json` retains each source node, unmodified attached source LaTeX,
the original MathML excerpt, image hash and crop geometry. Every captured node's
`data-mw.body.extsrc` was checked against its expected LaTeX before the screenshot.
The captured formula shapes were visually checked before inference.

The cropped article text and MathML excerpts are attributed to Wikipedia
contributors and distributed under CC BY-SA 4.0. The page links and revision
links in each manifest entry provide attribution and access to author histories.
The same license applies to the cropped and recolored adaptations. The source
article footer and official Wikimedia Terms section 7 document the license and
attribution route. [Wikimedia Terms](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use),
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

Chrome 157 rendered archived original article HTML and its original native
MathML. Source scripts were removed to prevent asynchronous page shifts, and
the base URL was restored for linked page styles. Capture uses stable document
coordinates with a small crop margin around the MathML content. Ten cases have
a declared 12px math font override. Ten have a declared dark page color override.
The mathematical source was preserved. These are controlled archived-page
captures, with source-specific font and layout preserved. `capture.json` records
the browser and changes. Captures underwent visual QA after an initial clipping
problem was corrected, before inference began.

## Independently published PDF provenance

Six systems come from Jim Hefferon's *Linear Algebra*, Fourth Edition, hosted
on his University of Vermont site. They cover six separate worked examples on
PDF pages 13, 15, 16, 17 and 18. They are a supplement focused on aligned linear
systems. Broader PDF coverage across the other categories remains to be collected.

The author's license page explicitly covers *Linear Algebra* and permits reuse
under CC BY-SA 3.0 US or GFDL. These six cropped adaptations use CC BY-SA 3.0 US
and retain author, title, example, PDF page, source URL and license links in
`pdf/manifest.json`. The PDF SHA-256 is pinned, and the renderer refuses a changed
document. Each system was manually transcribed and checked against both exact
PDF text and the rendered crop before predictions. Crops are genuine PDF page
rasters at 144 dpi. [Author's license and source page](https://hefferon.net/source.html),
[Author's book page](https://hefferon.net/linearalgebra/),
[Source PDF](https://jheffero.w3.uvm.edu/linearalgebra/book.pdf),
[CC BY-SA 3.0 US](https://creativecommons.org/licenses/by-sa/3.0/us/).

## Reproduce the evaluation

Use the existing pinned development runtime and model setup in the parent
benchmark README. The archived PNGs and frozen manifests are the evaluation
inputs. Renderer and browser changes can affect regenerated images.

```sh
/tmp/latexshot-recognition-venv/bin/python benchmarks/preprocessing-study/run.py \
  --python /tmp/latexshot-recognition-venv/bin/python \
  --model /tmp/latexshot-PP-FormulaNet-S \
  --manifest benchmarks/held-out/manifest.json --suite wikipedia \
  --output benchmarks/held-out/results
/tmp/latexshot-recognition-venv/bin/python benchmarks/preprocessing-study/run.py \
  --python /tmp/latexshot-recognition-venv/bin/python \
  --model /tmp/latexshot-PP-FormulaNet-S \
  --manifest benchmarks/held-out/pdf/manifest.json --suite hefferon-pdf \
  --output benchmarks/held-out/pdf/results
python3 benchmarks/held-out/analyze.py
```

`collect.py` implements the source-order selection criteria and license-footer
checks. It downloads source HTML to an external cache. `capture.cjs` captures the
selected nodes in that cache. The current source cache is
`/tmp/latexshot-heldout-sources`. To recreate the website inputs, fetch the saved
revision URLs into that cache with the filenames in `sources.json`, then run
`node benchmarks/held-out/capture.cjs CACHE OUTPUT`. Each expected LaTeX string
is checked again. Browser versions, remote styles and system fonts can change
the resulting pixels, so compare against the retained image hashes.

To recreate PDF crops, download the source PDF and run the following command.
Its pinned hash check protects page identity and crop transcriptions.

```sh
/tmp/latexshot-recognition-venv/bin/python benchmarks/held-out/pdf-cases.py \
  --pdf /tmp/latexshot-hefferon-book.pdf --output /tmp/latexshot-pdf-recaptured
```

## Remaining validation gaps

Independent structural review, broader PDF category coverage, native app timing
including first capture, and clean offline packaged-runtime testing remain.
The source material clusters within six articles and one textbook. Formula
strings are distinct, while some express related or equivalent identities.
Counts describe test cases and do not establish 66 independent mathematical
topics or model-training exclusion. Both candidate normalizations continue to
lose or corrupt mathematical content, so release approval stays false.
