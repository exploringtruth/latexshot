# LaTeXShot for macOS

Press **⌘⇧L**, drag around an equation, and paste the LaTeX. The first release supports printed equations in PDFs and websites on Apple silicon Macs running macOS 14 or later. Handwriting is a required follow-up release.

## Capture and copy

- Build a SwiftUI menu bar app with Swift Package Manager and `LSUIElement`. Use the same capture handler for the configurable global shortcut and **Capture Equation** menu item.
- Use an AppKit crosshair and drag overlay with ScreenCaptureKit. Capture at native pixel density on any connected display and constrain each selection to the display where it starts. Escape cancels. Handle first-run screen recording permission and restore focus to the previous app.
- Recognize selected crops offline. Benchmark PP-FormulaNet-S first and PP-FormulaNet-L if the smaller model misses the release targets. Bundle the selected weights, inference runtime, and math renderer. Keep crops in memory during processing. Use one crop-to-LaTeX interface so a later handwriting model can use the same flow.
- Copy plain text immediately with the configured wrapper applied once. Show a brief, non-activating in-app popup with **Copied** and the typeset equation. On recognition failure, preserve the clipboard and show a retry message. If only math rendering fails, show **Copied** by itself.

## Menu bar and Settings

- Include **Capture Equation**, **Settings…**, **Check for Updates…**, **Send Feedback…**, and **Quit**. Send Feedback opens the project's GitHub Issues page in the default browser.
- Open a single Settings window with **General** and **Shortcuts** in the sidebar. Start on General, remember the selected section, and bring the existing window forward on reopen.
- General lets users choose **Raw LaTeX** (default), **Inline Markdown** (`$…$`), **Display Markdown** (`$$…$$`), **Inline LaTeX** (`\(…\)`), **Display LaTeX** (`\[…\]`), or **Custom**.
- Custom exposes literal prefix and suffix fields and a live plain-text preview. Allow empty fields and preserve whitespace and line breaks. Remember both fields when switching presets. Changes apply to the next capture. The copy popup renders the formula body independently of the wrapper.
- Use KeyboardShortcuts to let users change, clear, or restore **⌘⇧L**. Put **Launch at Login** in General, enabled by default in packaged builds subject to macOS login-item controls. Honor the user's choice across relaunches and updates. Show a dismissible first-run hint pointing out the menu bar icon, shortcut, and **Settings → Shortcuts**.

## Icon

- Show five distinct concepts that explore capture corners, math symbols, and typography. Pair each full-size app icon with a menu bar-sized preview in light and dark appearances. Ask the user to choose before finalizing or packaging the artwork.
- Use the same recognizable mark for both icons, adapted for menu bar scale and contrast. Export an `.icns` for the app, a menu bar asset, and a PNG for the README and website.

## Updates, website, and README

- Follow the background-mac-app skill and [DropShake's updater setup](https://github.com/exploringtruth/dropshake/blob/main/docs/UPDATER.md). **Check for Updates…** triggers an immediate Sparkle check. Packaged builds also check every 24 hours while LaTeXShot is running. Bring the update dialog forward and let users choose when to install.
- Package a versioned `.app`, a first-install DMG, and an update ZIP. Use LaTeXShot's own bundle ID, icon, and Sparkle key. Embed the HTTPS appcast URL and public key. Keep the private key in GitHub Actions secrets and fail early when signing configuration is missing. Adapt DropShake's release script to bump the version and push the release commit and version tag together. Use Markdown release notes. Publish the DMG, signed update ZIP, and appcast together from tag-triggered GitHub Actions. Use stable latest-release links for the DMG and appcast and version-specific links for update ZIPs.
- Publish a GitHub Pages site with the icon, “Screenshot an equation. Copy it as LaTeX.”, a prominent **Download for Mac** button linking to the latest DMG, the supported Mac requirements, and GitHub and feedback links. Put a link to the README first-launch walkthrough beside the download.
- Start the README with the icon, app name, “Screenshot an equation and copy it as LaTeX, offline,” and links to Download and Website. Cover installation, shortcuts, clipboard formats, updates, privacy, feedback, and building with `swift run`. State the actual Apple signing and notarization status, the printed-math scope, and planned handwriting support. Explain local preferences, why screen recording permission is needed, and when updates or feedback use the network.
- For an unnotarized build, add a numbered **If macOS blocks the app** walkthrough directly under **Install**. Tell users to download the official DMG, move the app to Applications, and try opening it. If macOS blocks it and they trust the download, direct them to **System Settings → Privacy & Security → Open Anyway** and have them confirm the prompt. Link to [Apple's instructions](https://support.apple.com/en-us/102445). Explain Sparkle archive verification in the Updates section.

## Verification and rollout

- Test exact clipboard output for every preset and custom wrapper, including empty fields and line breaks. Verify settings persistence, shortcut reassignment and capture from another app, Settings focus, capture cancellation, denied permission, repeated captures, mixed-scale displays, popup focus, and offline recognition.
- Benchmark at least 60 printed crops from PDFs and websites covering fractions, roots, matrices, aligned equations, small type, and dark backgrounds. Require at least 95% mathematically and structurally correct results, allowing equivalent LaTeX syntax, and a warm 95th-percentile time under two seconds from mouse-up to clipboard write on the development Mac. Keep the build local if neither model passes.
- Deliver a `swift run` build for the user's trial. On a clean macOS account, verify DMG installation, first-launch instructions, app and menu bar icons, the first-run hint, and both Launch at Login states after signing in again. Test manual and scheduled Sparkle checks, installation, and relaunch from an earlier packaged build.
- Publish `v0.1.0` after the user's trial and release checks pass. Verify GitHub Actions, the release assets and appcast, and all download and feedback links.
- Before shipping handwriting, test tablet notes and onscreen photos of paper separately and rerun the printed benchmark.

## Parallel implementation handoff

| Track | Deliverable |
| --- | --- |
| Mac app and integration | Native capture, Settings, clipboard, and popup. Test the flow with a stub while recognition is evaluated. Integrate the chosen recognizer, artwork, and packaging changes. |
| Offline recognition | Printed fixtures, model benchmarks, and the selected offline recognizer behind the shared crop-to-LaTeX interface. |
| Icon design | Five concepts, user selection, and approved exports for the app, menu bar, README, and website. |
| Packaging and distribution | Versioned package, manual and scheduled Sparkle checks, GitHub Actions, release scripts, README, and Pages site. |

Keep product decisions in the planning chat and implementation in separate chats in the same Codex project. Each track uses its own branch or worktree and reports verification and blockers to the integration lead. See [AGENTS.md](AGENTS.md) for ownership and routing.
