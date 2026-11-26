# Updates, packaging, and release operations

The operational boundary is the Apple silicon SwiftPM executable → `.app` resource/framework assembly → DMG/ZIP → Sparkle appcast → GitHub release → latest-release URLs. The website is deployed separately through GitHub Pages. Check the tagged workflow and GitHub release before treating public assets as available.

## App and updater contract

- Executable: `LaTeXShot`; bundle ID: `io.github.exploringtruth.LaTeXShot`; macOS minimum: 14.0; architecture: arm64.
- App resource bundle: `LaTeXShot_LaTeXShotApp.bundle`. Packaging copies every SwiftPM `.bundle` from the selected build output to `Contents/Resources`, including recognition and KeyboardShortcuts resources.
- Sparkle.framework is copied with `ditto`, preserving symlinks and executable permissions, from the resolved Sparkle artifact into `Contents/Frameworks`. The executable needs `@executable_path/../Frameworks`; packaging adds it if missing.
- Public `SUFeedURL`: `https://github.com/exploringtruth/latexshot/releases/latest/download/appcast.xml`.
- `SUEnableAutomaticChecks=true`, `SUScheduledCheckInterval=86400`, `SUAllowsAutomaticUpdates=false`, `SUAutomaticallyUpdate=false`. The app owns the immediate manual check and foreground presentation. Users choose when to install.
- The v1.0.0 packager sets `LaTeXShotRecognitionBackend=pix2text` in the packaged application plist.
- A local package removes the feed and key and disables automatic checks. It is for local testing and cannot act as the earlier updater test build without a separate test feed/key configuration.

Implementation follows [Sparkle's framework embedding and signing documentation](https://sparkle-project.org/documentation/) and [publishing documentation](https://sparkle-project.org/documentation/publishing/). The workflow uses the [standard arm64 macOS runner label](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and verifies the runner architecture before building. It selects Xcode 26.3 explicitly for Swift tools 6.2; verify that pinned Xcode remains installed on the runner image before a future release.

## Signing configuration

LaTeXShot currently uses **ad-hoc app signing without Apple Developer ID signing or notarization**. Sparkle's bundled framework retains its existing nested signatures; the outer app is ad-hoc signed. `codesign --verify --deep --strict` must pass. Recognition-runtime native components must already carry valid signatures in the pinned runtime archive. Packaging fails verification if they do not.

Sparkle archive signatures are mandatory for public distribution and separate from Apple signing. The first public release needs its own production signing key.

Create LaTeXShot's own key once on the maintainer's Mac (do not reuse DropShake's key):

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account latexshot
```

In GitHub repository settings, create the `release` Actions environment. Set the private key secret on the environment and add the other five settings as repository Actions variables. Keep the Keychain item and a secure backup so future releases can use the same key. Run this provisioning once after the release gates pass.

| Setting | Type | Value |
| --- | --- | --- |
| `SPARKLE_PUBLIC_ED_KEY` | Variable | Public key for the `latexshot` Keychain account |
| `SPARKLE_PRIVATE_ED_KEY` | Secret | Export from that same Keychain account |
| `RECOGNITION_RUNTIME_URL` | Variable | Immutable HTTPS URL for the qualified runtime archive |
| `RECOGNITION_RUNTIME_SHA256` | Variable | Archive digest from the version's readiness record |
| `RECOGNITION_MODEL_URL` | Variable | Immutable HTTPS URL for the qualified model archive |
| `RECOGNITION_MODEL_SHA256` | Variable | Archive digest from the version's readiness record |

From the repository on the maintainer's Mac, provision the two Sparkle settings using the approved GitHub account:

```sh
(
  set -eu
  umask 077
  key_dir="$(mktemp -d)"
  trap 'rm -rf "$key_dir"' EXIT
  tool=.build/artifacts/sparkle/Sparkle/bin/generate_keys
  "$tool" --account latexshot -p > "$key_dir/public"
  "$tool" --account latexshot -x "$key_dir/private"
  gh variable set SPARKLE_PUBLIC_ED_KEY < "$key_dir/public"
  gh secret set SPARKLE_PRIVATE_ED_KEY --env release < "$key_dir/private"
)
```

The workflow passes the private key to Sparkle over standard input. Guard the key backup and keep private material out of chat, source, and logs.

`prepare-appcast.sh` uses the resolved Sparkle `generate_appcast`, embeds Markdown release notes, and disables delta generation. It validates the exact version-specific HTTPS enclosure URL, ZIP length, minimum OS, version, and embedded public key. A separate CryptoKit verifier validates the archive's Ed25519 signature against that public key, detecting mismatched key pairs and modified archives before publication.

## Offline recognition assets

For v1.0.0 the recognition owner supplies two gzip-compressed tar archives from the same qualified Pix2Text candidate. Keep the archives immutable and retain the exact copies used to qualify the runtime and app.

- `runtime.tar.gz` extracts directly to `bin/python3`, the relocatable arm64 Python/ONNX runtime, and its licenses. The runtime is copied to `Contents/Resources/RecognitionRuntime`.
- `model.tar.gz` extracts directly to the eight files in the [Pix2Text-MFR 1.5 model lock](../Sources/EquationRecognition/Resources/pix2text-model-lock.json). The model is copied to `Contents/Resources/RecognitionModel`.

Record the lowercase results of `shasum -a 256 runtime.tar.gz model.tar.gz` in `recognition_archives.runtime_sha256` and `recognition_archives.model_sha256` in the version's readiness JSON. Upload the **input** archives to immutable runner-accessible HTTPS storage and configure the URL and digest variables above. Tag-triggered Actions checks the configured digests against the readiness record, then downloads the archives. The packager verifies the same archive digests before extracting with Python 3.12's safe tar data filter. Before signing, it verifies the packaged model lock against the source and checks every packaged model file for exact membership and digest. Distribution includes these assets so users can recognize equations on the first run without a network connection.

For v0.1.0 the recognition inputs are the arm64 CPython/Paddle runtime and exactly the five files in the [Plus-S model lock](../benchmarks/plus-s-screen/model-lock.json). The fetch script verifies and extracts those archives and the packager checks the staged model against the Plus-S lock. The [Paddle relocation prototype](runtime/README.md) records its remaining native audit issues.

For a v1.0.0 local candidate with prepared assets:

```sh
VERSION=1.0.0 \
RECOGNITION_RUNTIME_DIR=/absolute/path/to/RecognitionRuntime \
RECOGNITION_MODEL_DIR=/absolute/path/to/RecognitionModel \
bash scripts/build-dmg.sh --local
```

After moving the bundled app outside the build tree, verify that its native runtime resolves its imports and libraries and performs actual inference with the network disabled. Record the runtime archive and model archive digests and the resulting app or DMG digest in the evidence for `offline_runtime_verified`.

## Release gates

Read the version-specific records for [v1.0.0](releases/v1.0.0.json) and [v0.1.0](releases/v0.1.0.json). Do not change a check without recording the observation in a repository evidence document. Each evidence path must resolve inside the repository and name a nonempty file. Readiness records are version-specific. Reviewers must verify the results in the linked evidence.

Before release:

1. Obtain the user's icon selection, then commit approved `Assets/Icon/LaTeXShot.icns`, `LaTeXShot.png`, and `LaTeXShotMenuBar.pdf`. No substitute branding is accepted for public release.
2. Benchmark the frozen suite of 66 printed crops for the v1.0.0 Pix2Text candidate and the v0.1.0 Plus-S candidate, covering fractions, roots, matrices, alignment, small type, and dark backgrounds. Require at least 95% mathematically and structurally correct and **warm p95 mouse-up to clipboard strictly under 0.8 seconds**, plus **the first capture strictly under 0.8 seconds from mouse-up to clipboard** on the development Mac. Include startup/readiness waiting in capture latency whenever the recognizer is not ready at mouse-up. Record cold app-start-to-recognizer-ready time separately; it must not be hidden or substituted for first-capture latency. Record crop IDs, model/runtime hashes, Mac, timing method, and results. Neither placeholder results nor a stub recognizer qualify.
3. Complete the user's local trial. Record version/source commit, observations, and accepted outcome.
4. Verify the [clean-account install](#clean-account-install) from the candidate DMG.
5. Test Launch at Login in both states across fresh logins during that install check.
6. Verify a [packaged Sparkle update](#packaged-sparkle-update) using unpublished test builds.
7. Confirm offline inference from the relocated packaged runtime and model, and commit `Package.resolved` so the release pins dependencies.
8. Record passing evidence and signing status in the version's JSON, then run `python3 scripts/release-readiness.py 1.0.0` for v1.0.0.

The benchmark record requires `warm_p95_seconds`, `first_capture_seconds`, dedicated `first_capture_evidence`, and separate `cold_start_ready_seconds` / `cold_start_evidence`. Set `timing_scope` to `mouse-up-to-clipboard-including-readiness-wait`. Both capture times must be positive and strictly below 0.8 seconds; a measurement of exactly 0.8 fails. Cold readiness must be measured and preserved as a positive duration with its own evidence; it is diagnostic and does not replace either capture threshold. Older reports lacking these fields fail validation. Backend worker-round-trip measurements alone cannot fill these capture fields.

The [v1.0.0 review](../benchmarks/pix2text-v1/README.md) accepted 60 of 66 printed crops. The pinned candidate missed the accuracy gate, and the recorded worker timings do not cover physical capture and clipboard write. The readiness record leaves the physical timing fields open. Use `benchmark.model` = `breezedeus/pix2text-mfr-1.5` and `benchmark.model_revision` = `1cef9f0bdcd6a4c63df7de1311fb0894593340cc` for the candidate in that record.

For v0.1.0, set `benchmark.model` to `PaddlePaddle/PP-FormulaNet_plus-S` and `printed_crops` to 66. Use the frozen held-out suite for the benchmark evidence. Also record `cube_root_exact_repeats` (48 required), `decoder_fix_evidence`, and `repeat_capture_evidence`. Use the same pinned model and runtime across the decoder proof, recaptures, benchmark, and packaged candidate.

## Clean-account install

After recognition qualification and the user's trial, build the candidate with the qualified model and runtime. Use a clean macOS account on a test Mac or VM without a pre-existing `/Applications/LaTeXShot.app`. Record the candidate commit, version, DMG SHA256, and macOS version.

1. Download the candidate DMG in a browser from a trusted private test location so macOS applies quarantine. Open the DMG in Finder, drag the app to **Applications**, eject the image, and launch the installed app from Finder.
2. Record the first-launch prompt and follow the [README walkthrough](../README.md#if-macos-blocks-the-app) if macOS blocks the app. Confirm the installed app icon, menu bar icon, and first-run hint. Dismiss the hint and confirm it stays dismissed after relaunch.
3. Deny Screen Recording on the first capture attempt and verify the app's recovery instructions. Grant permission, relaunch if macOS requests it, and verify capture from another app, Escape, mixed-scale displays, repeated captures, all clipboard formats including empty and multiline custom wrappers, and popup and Settings focus. Reassign the shortcut from Settings, then verify it from another app and after relaunch.
4. Confirm Launch at Login starts enabled. Sign out and sign back in to verify the app starts. Turn the setting off, sign out and back in again, and verify the app stays closed. Record both observations and any macOS login-item prompts.

## Packaged Sparkle update

Use two unpublished, locally packaged versions of the qualified app and a dedicated test key. Set `SUFeedURL` to the isolated HTTPS appcast and `SUPublicEDKey` to the test public key in both staging apps. Restore `SUEnableAutomaticChecks` to true after local packaging. Preserve the bundle identity, the 86400-second schedule, and the settings requiring installation consent. Ad-hoc sign each app again after editing its plist and verify the deep signature before archiving. Keep the test key, URLs, and artifacts out of public distribution.

Install the earlier test build in Applications. Verify **Check for Updates…** brings the offer forward, then accept the update and confirm the new version relaunches from Applications. Retry from an independent clean snapshot to observe a scheduled check at the configured cadence without triggering a manual check. Record the request time and the version offered. Also test an altered ZIP with its original signature and confirm Sparkle rejects it and leaves the installed version usable. The disposable updater harness covers the update mechanics and interval configuration. The packaged check requires observing the app itself.

## Disposable updater verification

A disposable updater test harness (`scripts/test-sparkle-updater.py` with `scripts/sparkle-smoke.m`) verifies the complete Sparkle update cycle in an isolated sandbox under `/private/tmp`:
- Uses an ephemeral test bundle ID (`io.github.exploringtruth.LaTeXShot.DisposableUpdaterTest.<uuid>`), leaving user preferences and `/Applications/LaTeXShot.app` untouched.
- Generates an in-memory Curve25519 keypair and signs a test v2.0 package.
- Serves a localhost feed and verifies manual update check, 24-hour interval configuration (`SUScheduledCheckInterval=86400`), automatic check enablement (`SUEnableAutomaticChecks=true`), download, Ed25519 archive verification, extraction, and clean relaunch into v2.0.
- See the [updater verification report](updater/README.md) and [test evidence](updater/verification.json).

Run the smoke test directly:

```sh
python3 scripts/test-sparkle-updater.py
```

Or run all release tool tests:

```sh
python3 scripts/test-release-tools.py
```

## Build and publish

Local package smoke build:

```sh
bash scripts/build-dmg.sh --local
```

For a local v1.0.0 release rehearsal after the gates pass, use a pristine worktree of the release commit with both `Info.plist` version fields set to `1.0.0` and the two reviewed archives in a single directory:

```sh
VERSION=1.0.0 \
SPARKLE_PUBLIC_ED_KEY='<public key>' \
RECOGNITION_ASSET_DIR=/absolute/path/to/reviewed-archives \
bash scripts/build-dmg.sh --release
```

The v0.1.0 packager uses the extracted `RECOGNITION_RUNTIME_DIR` and `RECOGNITION_MODEL_DIR` inputs in release mode. For a prequalification v1.0.0 rehearsal, use `--local` with the extracted inputs and the [isolated packaged update setup](#packaged-sparkle-update). Keep rehearsal outputs local.

Local-only `PACKAGE_OUTPUT_DIR` and `SWIFT_BUILD_DIR` may point at absolute external directories for smoke verification; public builds reject these overrides.

Output is `.build/dist/--release/VERSION/`; local output lives separately under `--local`. Existing output apps cause an error, preventing accidental mixing of successive builds. Archive old local output or remove that exact generated version directory before rebuilding. The app, versioned DMG, stable-name DMG, and ZIP are assembled once; signing the ZIP does not rebuild the app. Never replace artifacts in an already published version.

The installer uses a 500 × 264 point Finder icon-view preset with
96-point icons. LaTeXShot appears on the left and the Applications link
appears on the right. Finder uses the system appearance for colors and
filenames. The release build includes this layout in the stable `LaTeXShot.dmg`.
`scripts/create-installer-dmg.sh` takes an already signed app and writes a new
disk image with native macOS tools. The ZIP comes from the signed app directly.

To rewrap an already verified app without rebuilding or signing it again,
use a new output file in an existing directory:

```sh
bash scripts/create-installer-dmg.sh \
  /absolute/path/to/LaTeXShot.app /absolute/path/to/LaTeXShot-1.0.0-Installer.dmg
```

The v1.0.0 download links point to this versioned installer and its own
checksum to preserve the original published downloads and checksums. Verify
the rewrapped app against the original, including its deep code signature.

The release workflow requires the `release` environment. Configure GitHub environment protection appropriate to repository ownership before publication; do not assume an unconfigured environment supplies an approval gate. Pages must be configured for GitHub Actions in repository Settings. There is no automatic application/schema migration in this release.

Write `.github/release-notes/vX.Y.Z.md`, commit all changes, and prepare a version:

```sh
bash scripts/release.sh 1.0.0
```

This creates only a local annotated tag and a version commit if needed. For a later release it bumps both plist version fields. It allows the initial plist version when no matching tag exists and rejects backwards versions. Review the local commit and tag. When publication is explicitly authorized, push the commit and tag together:

```sh
git fetch origin main --tags
git merge-base --is-ancestor FETCH_HEAD HEAD
git push --atomic origin HEAD:refs/heads/main refs/tags/v1.0.0
```

Alternatively `scripts/release.sh VERSION --push` performs the fetch, ancestry check, local preparation, and atomic push together. It never force-pushes. Use it only when external publication is authorized. If push fails, the local commit/tag remain; inspect the failure and retry the same atomic push rather than creating a replacement tag.

Tag-triggered Actions checks evidence and signing/asset settings **before building**, verifies pinned recognition archives, builds/packages, signs the update ZIP, verifies its signature, creates a draft release with all five assets, then publishes the draft and marks it latest. It downloads every public asset again, verifies SHA256 against local output, and compares both latest-release links. Release workflow concurrency prevents overlapping publication; it never cancels an in-progress publication. Retain workflow logs and artifact checksums as the audit of commit/tag, operator, and output.

After each public release, update the version, version-specific DMG URL,
and SHA-256 in the [Homebrew tap](https://github.com/exploringtruth/homebrew-tap).
Use the checksum of the exact published DMG and verify the cask with
`brew fetch --cask exploringtruth/tap/latexshot`. Keep the [original tap's
cask](../Casks/latexshot.rb) in sync for earlier Homebrew installs.

## Failure and recovery

- **Preflight, build, signing, or signature failure:** no public release is created. Correct the source/configuration, prepare a new immutable version when necessary, and rerun the checks. The previous public feed and installed apps stay unchanged.
- **Interrupted build:** image creation leaves no staging volume mounted. The installer cleans up its private staging directory on exit. If the process is killed before cleanup, archive or remove the exact `.latexshot-dmg.*` staging directory. A new local attempt refuses the existing app. Inspect and remove or archive that exact output before retrying.
- **Interrupted publication before publish:** inspect the GitHub draft. Published releases are never overwritten. If all assets are present, download them and verify against `SHA256SUMS`, then publish that exact draft after review. If incomplete, delete only the unpublished draft, retain the tag, and rerun the workflow. This is an explicit operator action; the workflow fails on any existing release instead of guessing.
- **Post-publication link/checksum failure:** stop further releases, inspect the named release and latest designation, and preserve all evidence. Do not upload replacement binaries under the same version. Restore the previous good release as latest only after verifying its appcast and archives; this stops offering the faulty version to older installs but does not downgrade already updated apps. Coordinate website messaging if downloads need to pause.
- **Bad installed update:** quit LaTeXShot and reinstall the previous known-good official DMG in Applications, preserving the existing local preferences. If newer preferences are incompatible, back them up and document a tested recovery before release. Sparkle does not automatically downgrade. Ship a corrected build with a **higher** version using the same trusted Ed25519 key. Keep old versioned assets available for manual recovery.
- **Compromised or lost key:** stop publication. Do not silently substitute a new key; existing installs trust the old one. Follow Sparkle's documented rotation/recovery rules and plan a separately verified migration or manual install path. Ad-hoc signing limits available trust-rotation paths.

After publication, verify README/website DMG links, HTTPS appcast, version-specific ZIP, GitHub Actions result, feedback links, and a real packaged update. Those checks require live GitHub and macOS environments and cannot be inferred from local script syntax validation.
