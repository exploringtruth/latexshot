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

- [ ] Build the menu bar app, global shortcut, screen selection, and permission handling.
- [ ] Implement the Settings sidebar, clipboard wrappers, first-run hint, and Launch at Login.
- [ ] Validate exact clipboard output and the rendered popup with a stub recognizer, then integrate the selected model and artwork.
- [ ] Verify live capture and deliver a local `swift run` build for the user's trial.

### Offline recognition

- [ ] Agree on the crop-to-LaTeX interface with the app lead.
- [ ] Assemble the printed benchmark and evaluate the candidate models against the accuracy and latency targets.
- [ ] Deliver the selected weights and inference code with benchmark evidence and offline verification.
- [ ] Add and verify handwriting support in the follow-up release.

### Icon design

- [ ] Present five distinct concepts with app-size and light/dark menu bar previews.
- [ ] Ask the user to choose a concept before finalizing.
- [ ] Export the approved `.icns`, menu bar asset, and PNG using the same recognizable mark.

### Packaging and distribution

- [ ] Configure Sparkle, the manual check, the 24-hour schedule, and signed update assets in coordination with the app lead.
- [ ] Set up versioned DMG and ZIP builds, the appcast, release scripts, and GitHub Actions.
- [ ] Write the README and GitHub Pages site, including the unnotarized first-launch instructions and privacy details.
- [ ] Verify clean-account installation and a packaged Sparkle update. Publish after the user's trial and release checks pass, then verify the public links and assets.

## Subagent Effort Routing Rules

Before spawning a subagent, the lead evaluates the assignment's complexity, ambiguity, and risk independently. Set `reasoning_effort` per worker automatically wherever the chosen role supports overrides. Keep fixed-effort roles at their configured setting. Apply the highest level justified by the individual assignment.

| Effort | Use |
| --- | --- |
| `low` | Straightforward lookup or a mechanical task with clear acceptance criteria |
| `medium` | Bounded implementation or verification with a known interface |
| `high` | Ambiguous requirements, substantial debugging, or cross-component integration |
| `xhigh` | The most complex or high-risk work, such as difficult native capture or updater integrity issues |
