# Launch-time prewarm experiment

This experiment uses the production capture path at
`f1fcf596308e00094cad06bd5c5f19976296cd56` with PP-FormulaNet-S. Each of its
two test scenarios creates a fresh recognizer and worker process. A known
synthetic fixture initializes the model. Its prediction is checked in memory.
The capture itself goes through the AppKit overlay, ScreenCaptureKit, real
recognizer, and private pasteboard. The measured startup clock begins just
before recognizer construction and excludes the GUI process launch before its
startup hook. The recorded host was an Apple M5 running macOS 27.2.1.
[Raw measurements](results.json) contain one sample per scenario.

| Scenario | Startup hook to ready | Mouse-up to clipboard | Startup hook to clipboard |
| --- | ---: | ---: | ---: |
| Immediate first capture (mouse-up 71 ms after hook) | 7.719 s | 7.807 s | 7.878 s |
| First capture after reporting ready | 5.825 s | 0.198 s | 6.028 s |

The startup-hook-to-ready measurements include model setup and a first real
inference. The ready-after-hook case moved this work before capture. The
immediate case still missed the sub-800 ms first-capture target.

Use the [baseline setup](../README.md#reproduce) for the runtime, model,
fixture hashes, and permissions. Run from the repository root. The runner
extracts the selected source revision and creates the test in an isolated
temporary directory. Pass a sample count of 1 for one capture per startup case.

```sh
benchmarks/capture-latency/run.sh "$PWD" \
  /tmp/latexshot-recognition-venv/bin/python /tmp/latexshot-PP-FormulaNet-S \
  1 /tmp/latexshot-prewarm-rerun.json f1fcf596308e00094cad06bd5c5f19976296cd56 prewarm
```

The harness calls the real overlay handlers with synthetic events directed
to the overlay. It checks capture dimensions, foreground focus, and private
pasteboard readback. It uses no global input events and keeps the warmup
prediction and captured image in memory. System mouse-event delivery, human
drag time, and popup rendering are outside the timer.
