# PP-FormulaNet_plus-S qualification

**Blocked for printed math.** The clean pinned official model returned 42 of
66 structurally correct crops in a provisional review (41 of 60 Wikipedia, 1
of 6 Hefferon PDF), below the 63 required. All 48 frozen recaptures of
`\sqrt{x+1}+\sqrt[3]{y}=1` returned recoverable recognition errors and none
returned the exact expected LaTeX. The 48 images vary scale, font size, theme
and margin around one equation. The earlier benchmark and its scoring remain
in the parent directory. This review counts malformed LaTeX against printed
accuracy even when it contains most of the intended symbols.

| Frozen suite | Structural or exact result | Cold first response | Warm worker p95 |
| --- | ---: | ---: | ---: |
| Wikipedia | 41/60 structural | 10.295 s | 1.037 s |
| Hefferon PDF | 1/6 structural | 8.564 s | 0.344 s |
| Fixed root recaptures | 0/48 exact | 8.648 s | 0.233 s |

The repeat timing is for rejected requests. The worker timings exclude capture,
Swift PNG encoding, clipboard writes and rendering. The product's warm
mouse-up-to-clipboard timing gate remains unmeasured. Fresh response text and
errors matched all 114 archived predictions. The fresh score applies this
report's syntax rubric to the same strings and is provisional pending
independent review.

## Where the error originates

The locked Hugging Face export matched the model-card output on the original
sample PNG. The static graph emits IDs 11242 and 11237 in the root degree.
Direct tokenizer decoding already contains `[object Object]` before
`UniMERNetDecode.post_process`. The complete embedded tokenizer documents in
both export configs are identical to the PaddleOCR training tokenizer.
`object` is 11242, `ĠObject` is 11237 and `3` is 41.

The official PaddleOCR training checkpoint loaded with all 464 parameter keys
and shapes matching. Its eager CPU forward pass and the static export produced
identical raw IDs through EOS on byte-identical tensors for the card sample and
four representative frozen recaptures. This reproduces the bad prediction before
postprocessing and without executing the exported graph. The evidence identifies
an upstream model prediction failure under this input path. The provenance of
the training labels and the behavior on a different backend remain unverified.

The PaddleOCR inference mirror also contains the same three inference files
byte-for-byte as the locked Hugging Face export. The mirror archive SHA-256 is
`31e8659fd5bdbefcc1339ab531e359c58fae6c0971097ca4cc897073e3fd28a6`.
Its first download timed out at 177,522,103 of 259,604,480 bytes. Resuming
the download yielded the complete archive and all three hashes matched the
lock. A corrected official plus-S artifact or an upstream decoding change
that predicts degrees from pixels would need fresh qualification.

Five pixel-only variants tested contrast normalization, single-pass Lanczos
scaling, binarization, a smaller centered ink region and shifted placement on
the fixed 384×384 canvas. All 20 variant predictions across the four
representative recaptures still contained the placeholder. The three more
aggressive variants also changed the card formula. None qualified for a
full variant benchmark or a change to the worker's preprocessing.

The placeholder remains a recognition error. Since commit `426a780`, a
per-crop error keeps the worker available for the next capture. Fatal startup,
transport and invalid protocol replies still tear it down. The focused Swift
test covers a recoverable reply followed by success on the same worker and
verifies restarts after startup errors and malformed replies. The optional
Swift real-model smoke on the cube-root fixture failed with the expected
recognition error. The guard targets the placeholder and the structural review
shows other kinds of wrong LaTeX can still be emitted by this model.

## Reproduction

Both the worker run and trace ran on arm64 macOS under
`sandbox-exec -p '(version 1)(allow default)(deny network*)'`. The verified
trial environment is `/tmp/latexshot-plus-s-clean-venv/bin/python` with
`/tmp/latexshot-plus-s-clean-model`. Use the [model lock](../model-lock.json) if
those temporary files are unavailable. The trace includes the original image
hashes, input-tensor hashes, raw token IDs, checkpoint digest and timings.

```sh
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  /tmp/latexshot-plus-s-clean-venv/bin/python -B benchmarks/plus-s-screen/run.py \
  --python /tmp/latexshot-plus-s-clean-venv/bin/python \
  --model /tmp/latexshot-plus-s-clean-model --repeat-root \
  --output /tmp/plus-s-worker-evidence

sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  /tmp/latexshot-plus-s-clean-venv/bin/python -B benchmarks/plus-s-screen/trace.py \
  --model /tmp/latexshot-plus-s-clean-model \
  --card-sample /tmp/plus-s-model-card-sample.png \
  --upstream-tokenizer /tmp/latexshot-plus-s-diagnose-upstream/ppocr/utils/dict/unimernet_tokenizer/tokenizer.json \
  --upstream-source /tmp/latexshot-plus-s-diagnose-upstream \
  --training-checkpoint /tmp/latexshot-plus-s-diagnose-pretrained.pdparams \
  --output /tmp/plus-s-trace-evidence.json
```

- [Pinned official model card and sample](https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-S/blob/3d46f557e3a1752f4bf81202395af3b5ecfadfd2/README.md)
- [PaddleX 3.7.2 preprocessing and token decoding](https://github.com/PaddlePaddle/PaddleX/blob/ffb64904d23708863ff5b8da312a5cbd52a7f462/paddlex/inference/models/formula_recognition/processors.py)
- [PaddleOCR 3.7.0 source revision](https://github.com/PaddlePaddle/PaddleOCR/tree/b03f46425e8ff4442b268ce449e3eef758146cd4)
- [PaddleOCR plus-S training configuration](https://github.com/PaddlePaddle/PaddleOCR/blob/b03f46425e8ff4442b268ce449e3eef758146cd4/configs/rec/PP-FormuaNet/PP-FormulaNet_plus-S.yaml)
- [PaddleOCR training tokenizer](https://github.com/PaddlePaddle/PaddleOCR/blob/b03f46425e8ff4442b268ce449e3eef758146cd4/ppocr/utils/dict/unimernet_tokenizer/tokenizer.json)
- [Official training checkpoint](https://paddle-model-ecology.bj.bcebos.com/paddlex/official_pretrained_model/PP-FormulaNet_plus-S_pretrained.pdparams)
- [Official inference mirror](https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/PP-FormulaNet_plus-S_infer.tar)
