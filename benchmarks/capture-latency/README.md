# Mouse-up to clipboard latency

A release-build test with PP-FormulaNet-S copied all 60 warm captures of
`roots-01.png`. Median mouse-up to clipboard write was **189.7 ms**, nearest-rank
p95 was **208.8 ms**, and the range was **180.7–233.1 ms**. The first capture
took **5.669 seconds**, including worker setup and model loading. App launch
was outside the timer.

| Warm phase | Median | p95 |
| --- | ---: | ---: |
| Mouse-up to clipboard write | 189.7 ms | 208.8 ms |
| Mouse-up to ScreenCaptureKit image | 58.7 ms | 65.6 ms |
| ScreenCaptureKit image to clipboard write | 130.6 ms | 139.9 ms |

The baseline used source commit `f005f89a6963336d17ec8d01e10cb0baf0765970`,
an Apple M5 (arm64) with macOS 27.2.1 (26B131) and Swift 6.4.2. The fixture
rendered at 126 × 34 points on a 2× display and produced a 252 × 68 pixel crop.
Every copy contained `{\sqrt{x+1}}+{\sqrt[3]{y}}=1`. See the
[60 warm samples and cold sample](results/small-baseline.json) and
[computed summary](results/small-baseline-summary.json).

| Input | SHA-256 |
| --- | --- |
| [Synthetic root fixture](../fixtures/roots-01.png) | `202444f17f60f3756d67589fcbf2c1fb8a1124d32558c4d1a357963ae0c902f4` |
| PP-FormulaNet-S `inference.pdiparams` | `b6392296d16e2a9f414c0a751d7ccbd1bd9d8272b68aab72df1d3875f35a7489` |

## Reproduce

Run from the repository root on an active macOS desktop with Screen Recording
already granted to the launching shell. Prepare the Apple silicon Python runtime
and model described in the [recognition setup](../README.md#run-a-local-trial).
Use absolute runtime, model, and result paths. The final argument selects a
committed revision and defaults to `HEAD`. The runner extracts the selected
source into a temporary directory, where it builds and runs the test. The
original checkout needs no edits. A first build may need to fetch Swift
dependencies.

```sh
benchmarks/capture-latency/run.sh "$PWD" \
  /tmp/latexshot-recognition-venv/bin/python /tmp/latexshot-PP-FormulaNet-S \
  60 /tmp/latexshot-small-baseline-rerun.json f005f89a6963336d17ec8d01e10cb0baf0765970
python3 benchmarks/capture-latency/summarize.py /tmp/latexshot-small-baseline-rerun.json
```

The fixture appears in a small nonactivating window near the lower-right corner
of the primary display. The harness starts the production capture overlay
and calls its AppKit mouse handlers with synthetic events directed to the
overlay. It starts the timer immediately before the mouse-up handler and stops
it after the app writes to a private pasteboard. This includes overlay
teardown, ScreenCaptureKit, Swift PNG encoding, a real worker round trip, and
formula validation and copying. The harness checks crop dimensions, exact
pasteboard readback, stable formula output, and foreground app identity
immediately around each selection. It leaves the general pasteboard, app
preferences, and Screen Recording settings alone.

System mouse-event transport, human drag time, app launch, and popup rendering
are outside the timer. This one repeated synthetic crop measures baseline
latency. Independent PDF and website crops, structural accuracy, and release
qualification require separate evidence.

## Cold startup

The [launch-time prewarm experiment](prewarm/README.md) measures first capture
during worker startup and after the worker reports readiness.

## Native ONNX cold-capture feasibility

The benchmark-only [ONNX CPU load script](measure_onnx_load.py) and
[end-to-end worker](onnx_e2e_worker.py) used the 308,743,097-byte
PP-FormulaNet-S ONNX model and the real `roots-01.png` crop. The input was
preprocessed to `[1,1,384,384]` with production margin cropping, 384-pixel
UniMERNet resizing and centering, grayscale normalization, and the
`LatexImageFormat` pad. No recognition or packaging choice was made.

With ONNX Runtime 1.32.0 and only `CPUExecutionProvider`, seven fresh sessions
measured:

| Metric | Median | Nearest-rank p95 |
| --- | ---: | ---: |
| Session load | 250.484 ms | 316.592 ms |
| Real-crop preprocessing | 51.073 ms | 65.901 ms |
| First inference | 105.252 ms | 114.059 ms |
| Session load + first inference | 350.569 ms | 421.871 ms |

The repeated native Swift capture benchmark measured mouse-up to private
clipboard:

| Phase | Samples | Median | Nearest-rank p95 | 800 ms gate |
| --- | ---: | ---: | ---: | --- |
| Cold capture | 7 | 779.687 ms | 849.723 ms | FAIL |
| Warm capture | 60 | 234.275 ms | 289.501 ms | PASS |

CoreML Execution Provider compilation remains blocked by
`MaxPool ceil_mode must be False when pad_type is same`. The 294 MB ONNX
candidate is therefore **FAIL** for the native cold-capture gate on this host,
although its isolated warm CPU inference and measured warm end-to-end path
passed. Raw data is in [onnx-cold-load.json](onnx-cold-load.json) and
[onnx-end-to-end.json](onnx-end-to-end.json).
