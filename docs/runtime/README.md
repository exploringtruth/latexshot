# Relocatable runtime prototype

A pinned standalone CPython runtime can execute the existing PP-FormulaNet-S worker after relocation into a staged app, with networking and development Python installations inaccessible. This proves a packaging path, **not a release recognizer or an approved redistributable**. No release gate or model selection was changed.

The runtime uses [Astral's python-build-standalone install-only distribution](https://github.com/astral-sh/python-build-standalone/blob/main/docs/distributions.rst) of CPython 3.12.16 for arm64 macOS, pinned to the upstream [20261110 release](https://github.com/astral-sh/python-build-standalone/releases/tag/20261110). `prototype-lock.json` records the release asset's upstream SHA256 and byte length. The 85 wheels match `benchmarks/requirements-lock.txt`; each wheel URL, version, byte length and SHA256 was verified against its version's official PyPI JSON metadata and recorded in the lock. Model artifacts use the unchanged official `benchmarks/model-lock.json`.

## Reproduce

Run on Apple silicon macOS using Python 3.12 and the command-line tools. Destination directories must be new. Downloads need a network connection; package installation is subsequently performed with networking denied and only the locked local wheels available.

```sh
python3.12 scripts/prototype-recognition-runtime.py /private/tmp/latexshot-runtime-assembly \
  --cache /private/tmp/latexshot-runtime-downloads
mkdir /private/tmp/latexshot-runtime-relocated
mv /private/tmp/latexshot-runtime-assembly/RecognitionRuntime /private/tmp/latexshot-runtime-relocated/
python3.12 benchmarks/prepare-model.py /private/tmp/latexshot-runtime-relocated/RecognitionModel
python3.12 scripts/verify-runtime-prototype.py \
  --runtime /private/tmp/latexshot-runtime-relocated/RecognitionRuntime \
  --model /private/tmp/latexshot-runtime-relocated/RecognitionModel \
  --output /private/tmp/latexshot-runtime-proof.json
```

The assembler verifies every artifact hash, pins the entire existing requirements file, refuses existing output trees, preserves packaged license material, and records its original prefix. It creates no venv. It removes pip-generated console scripts because their shebangs embed the assembly path; the supported runtime entry point is `bin/python3 -I -B`. Compiling new Python extensions or using unrelated package command-line tools is outside this prototype. This is reproducibility of inputs and assembly procedure, not a claim that archive timestamps or resulting bytes are deterministic.

The verifier checks that the runtime moved outside its original assembly directory, that symlinks stay inside it, and that model hashes match. It inventories arm64 Mach-O load commands and RPATHs. It then starts isolated Python with an empty HOME, denies all networking and reads from Homebrew, `/usr/local`, the original assembly directory, and the previous development venv. An attempted network connection must fail with EPERM/EACCES. Six synthetic fixture categories are sent through the unchanged worker. An invalid PNG must be rejected, followed by a successful retry in the same process. A 180-second watchdog stops the entire probe process group on a hang.

For a copied **local** packaged app, move the assembled runtime into `LaTeXShot.app/Contents/Resources/RecognitionRuntime`, copy the pinned model into `RecognitionModel`, and run:

```sh
python3.12 scripts/verify-runtime-prototype.py --app /absolute/path/LaTeXShot.app \
  --output /private/tmp/latexshot-staged-runtime-proof.json --strict
```

This uses the worker found inside the app's SwiftPM resource bundle. `--strict` performs inference and writes evidence, then exits unsuccessfully if non-system absolute load commands or RPATHs remain. The current prototype is expected to fail that strict check. An existing trial app without the staged runtime is rejected with `Missing staged RecognitionRuntime/bin/python3`.

## Observed validation

`prototype-verification.json` records the staged-app run from source commit `f005f89` on macOS 27.2.1 arm64. The runtime was assembled twice from the pinned artifacts, then the second assembly was moved into an external path containing spaces. No base-Python file was copied from Homebrew.

- All six representative categories produced responses with outbound networking denied. The network canary returned errno 1 (EPERM). Invalid image rejection and same-worker recovery passed; the worker exited 0.
- The isolated interpreter's prefix and executable were inside the moved runtime. Original development installations and assembly paths were denied by sandbox policy.
- The staged app passed `codesign --verify --deep --strict` after its outer app was re-signed **ad hoc**, retaining Sparkle's existing nested signatures. No real signing key was used.
- Runtime payload: 1,001,048,248 file bytes, 19,796 regular files, 471 Mach-O binaries. Locked wheels total 272,137,960 download bytes; base CPython archive is 25,237,581 bytes. The S model adds roughly 238 MB of locked files. The experimental runtime tar.gz is 290,407,583 bytes; its observed digest is recorded in the evidence. Generated archives remain outside Git.
- These are execution checks. Several returned equations are known to be wrong. Timings in the evidence include a cold first request and warm worker round trips, not mouse-up-to-clipboard measurements, and do not qualify product latency.

## Remaining distribution boundary

Strict audit found **six external LC_LOAD_DYLIB references**: `paddle/libs/libblas.dylib` and `liblapack.dylib` each reference `/opt/homebrew/opt/gcc/lib/gcc/current/{libgfortran.5,libgomp.1,libquadmath.0}.dylib`. Each BLAS file is 20,209,296 bytes. Those files are present in the official wheel even though the representative inference path succeeds with Homebrew inaccessible. They cannot be assumed safe for every future code path.

There are also 73 absolute upstream build RPATHs across Paddle, SciPy, scikit-learn, Shapely, Pillow and OpenCV. The raw references are preserved in the evidence. RPATHs are search locations; this count does not mean 73 missing libraries were loaded. `LC_ID_DYLIB` identities were deliberately excluded from dependency counts.

The smallest next packaging action is to audit the required native closure for the eventual qualifying recognizer, then rebuild or deliberately relocate/remove unused native components with equivalent-path and failure/recovery checks. Do not install Homebrew on end-user machines or rely on the developer's environment. Do not silently strip these files or patch the locked wheel in production on the strength of six samples. A redistribution also needs a complete dependency-license inventory, minimum-macOS validation, clean-account installation and the packaged updater checks. Preserving wheel license files alone does not complete that review.

The prototype's scripts are separate from public build/release validation. `offline_runtime_verified` remains false, and no production asset URL, signing key, appcast or published release was created. Rollback for this experiment is deletion of its exact temporary assembly/staging directories; the existing trial app and production configuration are untouched.
