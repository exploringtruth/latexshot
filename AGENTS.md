# LaTeXShot agent guide

Read [PLAN.md](PLAN.md) for the product contract and release gates. Keep this planning chat for product decisions and coordinate implementation through separate chats in the LaTeXShot project.

## Architecture and file ownership

The SwiftUI menu bar target owns AppKit capture and Settings. The app passes an in-memory crop to a separate offline recognition target and receives a LaTeX formula body. The app applies the clipboard format and renders the popup. Packaging supplies bundle metadata, updater configuration, and public distribution.

Use a separate branch or worktree for each track. The paths below are reserved for implementation. One track owns each path. Request cross-track changes from the owner and coordinate shared interfaces before editing or merging. The integration lead owns shared decisions, merge order, `PLAN.md`, and `AGENTS.md`.

| Track | Owned paths |
| --- | --- |
| Mac app and integration | `Package.swift`, `Package.resolved`, `Sources/LaTeXShotApp/`, `Tests/LaTeXShotAppTests/` |
| Offline recognition | `Sources/EquationRecognition/`, `Tests/EquationRecognitionTests/`, `benchmarks/` |
| Icon design | `Assets/Icon/` for concepts and approved app, menu bar, and PNG exports |
| Packaging and distribution | `Info.plist`, `scripts/`, `.github/`, `docs/`, `README.md`, `site/` |

The Mac app lead owns the app-side Sparkle menu binding and SwiftPM dependency declarations. Packaging owns the updater configuration and embeds the release framework. The icon track provides exports in its own directory. The Mac app and packaging tracks integrate those exports in their owned paths.

## Track checklist

### Mac app and integration

- [x] Build the menu bar app, global shortcut, screen selection, and permission handling.
- [x] Implement the Settings sidebar, clipboard wrappers, first-run hint, and Launch at Login.
- [x] Verify exact clipboard output and offline math rendering with a stub. Connect the development app to the real PP-FormulaNet-S runtime and test inference through the Swift interface.
- [x] Verify live capture, Escape cancellation, and focus on the connected 2× display. Provide the local `swift run` trial in [benchmarks/README.md](benchmarks/README.md).
- [x] Integrate the approved Split Beam app and menu bar artwork.
- [x] Launch the isolated plus-S trial and verify live capture and clipboard write. Record the incorrect result in [HANDOFF.md](HANDOFF.md).
- [x] Complete the local Pix2Text trial with Equation History and record the user's v1.0.0 approval.
- [ ] Integrate a qualified recognizer. Verify physical mixed-scale displays, denied permission, shortcut reassignment, and popup focus.

### Offline recognition

- [x] Agree on the crop-to-LaTeX interface with the app lead.
- [x] Build 60 controlled printed fixtures and evaluate PP-FormulaNet-S, PP-FormulaNet-L, plus-S, and preprocessing variants. Preserve evidence in [benchmark results](benchmarks/summary.json); S, L, and preprocessing variants are rejected.
- [x] Freeze a held-out benchmark with 60 website and six PDF crops and a separate 48-capture cube-root repeat suite.
- [x] Diagnose the pinned PP-FormulaNet_plus-S output failure and rerun the frozen suites. [Results](benchmarks/plus-s-screen/diagnosis/README.md) record the failed accuracy and repeat gates.
- [x] Evaluate the pinned Pix2Text v1.0.0 candidate on the frozen printed suite. The [review](benchmarks/pix2text-v1/README.md) records the accuracy failure.
- [ ] Qualify the release recognizer on printed accuracy and the end-to-end mouse-up-to-clipboard timing gates.
- [ ] Bundle the qualified model and relocatable runtime.
- [ ] Add and verify handwriting support in the follow-up release.

### Icon design

- [x] Present five distinct concepts with app-size and light/dark menu bar previews.
- [x] Ask the user to choose a concept before finalizing.
- [x] Export the approved Split Beam `.icns`, menu bar PDF, and PNG.

### Packaging and distribution

- [x] Configure Sparkle, its manual check, and the 24-hour schedule. Test appcast signing and archive verification with a temporary key.
- [x] Set up versioned DMG and ZIP builds, the appcast, release scripts, and GitHub Actions. Verify the local arm64 DMG, app signature, and ZIP.
- [x] Write the README and GitHub Pages site, including the unnotarized first-launch instructions and privacy details.
- [ ] Configure production Sparkle keys and generate signed release assets after the trial and benchmark gates pass.
- [ ] Verify clean-account installation and a packaged Sparkle update. Publish after the user's trial and release checks pass, then verify the public links and assets.

## Orchestrator delegation and completion

- Delegate every in-scope implementation task to the worker or implementation chat that owns the affected track. This applies to follow-up fixes and checklist items discovered during verification. Give each assignment an owner, a bounded scope, and acceptance criteria. The orchestrator remains responsible for coordination, integration, and final verification.
- Before dispatching, map the request to every applicable requirement in PLAN.md and AGENTS.md. Track each item through assignment, integration, and verification. Check the integrated result against both documents before giving a completion report.
- Do not stop while any applicable item remains incomplete or unverified and there is an authorized next step. Follow up on unfinished assignments, retry or reassign failed work, and keep independent tracks moving while dependencies are blocked. A worker report is a checkpoint. Verify the result before marking the item complete.
- Stop only when all applicable items are complete and verified, the user asks to stop, or no authorized next step remains. If blocked, report each unfinished item and its specific blocker. Honor the trial, approval, release, and follow-up milestones in PLAN.md.

## Subagent Effort Routing Rules

Before spawning a subagent, the lead evaluates the assignment's complexity, ambiguity, and risk independently. Set `reasoning_effort` per worker automatically wherever the chosen role supports overrides. Keep fixed-effort roles at their configured setting. Apply the highest level justified by the individual assignment.

| Effort | Use |
| --- | --- |
| `low` | Straightforward lookup or a mechanical task with clear acceptance criteria |
| `medium` | Bounded implementation or verification with a known interface |
| `high` | Ambiguous requirements, substantial debugging, or cross-component integration |
| `xhigh` | The most complex or high-risk work, such as difficult native capture or updater integrity issues |
