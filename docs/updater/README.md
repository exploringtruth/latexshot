# Disposable Sparkle updater verification

This test harness verifies LaTeXShot's complete Sparkle updater cycle in an isolated, disposable sandbox without modifying user preferences, touching `/Applications/LaTeXShot.app`, or publishing to GitHub.

## Architecture and contract

- **Manual update check:** The menu item **Check for Updates…** calls `checkForUpdates` on `SPUUpdater`. The test exercises this path and asserts that the check is user-initiated.
- **Scheduled update check:** `Info.plist` defines `SUScheduledCheckInterval=86400` (every 24 hours) and `SUEnableAutomaticChecks=true`. Automatic background updates without user consent are disabled (`SUAllowsAutomaticUpdates=false` and `SUAutomaticallyUpdate=false`). The test verifies that `SPUUpdater` loads and exposes `updateCheckInterval == 86400` and `automaticallyChecksForUpdates == YES`.
- **Integrity and cryptographic signature:** While local trial packages and unnotarized builds are ad-hoc codesigned, Sparkle archive integrity is enforced by an **Ed25519 digital signature** (`sparkle:edSignature`) checked by Sparkle against the app's embedded `SUPublicEDKey`.
- **Atomic install and relaunch:** Sparkle extracts the downloaded update archive, stages the new bundle, terminates the host application, swaps the bundles, and relaunches the upgraded application.

## Test harness

The test harness consists of:
- `scripts/sparkle-smoke.m`: An Objective-C test application implementing `SPUUserDriver` and `SPUUpdaterDelegate` headlessly (`NSApplicationActivationPolicyProhibited`). It validates that it runs within an isolated disposable path with a test bundle ID, records lifecycle events to `events.jsonl`, signals successful relaunch by creating `relaunched.txt`, and terminates cleanly.
- `scripts/test-sparkle-updater.py`: A Python orchestration script that:
  1. Dynamically locates `Sparkle.framework` across build artifacts, staging directories, or `SPARKLE_FRAMEWORK_PATH`.
  2. Compiles `scripts/sparkle-smoke.m` against `Sparkle.framework` using `clang`.
  3. Generates an ephemeral in-memory Ed25519 keypair via Swift CryptoKit.
  4. Generates an isolated test bundle ID (`io.github.exploringtruth.LaTeXShot.DisposableUpdaterTest.<uuid>`).
  5. Assembles `v1.0` in `installed/UpdaterSmoke.app` and `v2.0` in `build/UpdaterSmoke.app`.
  6. Compresses and signs `UpdaterSmoke-2.0.zip` with the ephemeral Ed25519 private key.
  7. Spawns an ephemeral HTTP server on a random loopback port serving `appcast.xml`, `release-notes.html`, and `UpdaterSmoke-2.0.zip`.
  8. Launches `v1.0`, verifies updater initialization, initiates manual update check, observes download, verifies Ed25519 signature verification, extraction, atomic replacement, and relaunch into `v2.0`.
  9. Verifies the full ordered event trail and shuts down cleanly.

## Reproducing

Run the standalone updater test:

```sh
python3 scripts/test-sparkle-updater.py
```

Or run all release tool checks including the updater test:

```sh
python3 scripts/test-release-tools.py
```

## Observed verification

See [verification.json](verification.json) for the full record:
- Platform: macOS arm64 (Apple silicon).
- Sparkle framework: Sparkle 2.10.1 (`@rpath/Sparkle.framework/Versions/B/Sparkle`).
- Schedule configuration: `updateInterval: 86400`, `automaticallyChecks: true`.
- Event sequence:
  1. `launched` (v1.0, PID 36396)
  2. `updaterConfigured` (`automaticallyChecks: true`, `updateInterval: 86400`)
  3. `manualCheck` (user-initiated check triggered)
  4. `updateFound` (`updateVersion: 2.0`, `userInitiated: true`)
  5. `downloadStarted`
  6. `releaseNotes`
  7. `downloadLength` (`1,067,209` bytes)
  8. `extracting`
  9. `readyToInstall`
  10. `willInstall`
  11. `installing` (`hostTerminated: false`)
  12. `launched` (v2.0, PID 36404)
- Verification outcome: Succeeded. Full update cycle completed in ~3.8 seconds without affecting system state.
