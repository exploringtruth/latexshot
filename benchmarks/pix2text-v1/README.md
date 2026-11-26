# Pix2Text v1.0.0 candidate check

The reviewed trial recognizer at `1fc3573` ran offline on all 66 frozen
printed crops with the verified `breezedeus/pix2text-mfr-1.5` revision
`1cef9f0bdcd6a4c63df7de1311fb0894593340cc`. The run checked the manifest and
crop hashes against the frozen suite and checked all eight model files against
the trial lock before inference. The 48-case Plus-S cube-root acceptance suite
belongs to that historical candidate and was excluded here.

One structural review accepted **60/66 (90.9%)**. Six outputs changed the
math, so this candidate misses the **63/66 (95%)** release gate. The review
allows equivalent TeX and changes to spacing, fonts, and line alignment.
[Raw predictions](printed-results.json) and the
[case-level review](printed-review.json) include the exact inputs and
results.

The development worker took **15.623 seconds** from process spawn to the
first response. Warm request-to-response p95 was **3.120 seconds** over 66
printed crops, with no protocol errors. These are diagnostic timings for
the existing local ONNX CPU environment under network denial. The test did
not include physical capture or a clipboard write. The published contract
requires both warm p95 and first capture strictly below 0.8 seconds from
mouse-up to clipboard, with app launch-to-ready measured separately. This
diagnostic run supplies no passing end-to-end timing evidence.
