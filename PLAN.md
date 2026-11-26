# LaTeXShot for macOS

Press **⌘⇧L**, drag around an equation, and paste the LaTeX. The first release supports printed equations in PDFs and websites on Apple silicon Macs running macOS 14 or later. Handwriting is a required follow-up release.

## Capture and copy

- Build a SwiftUI menu bar app with Swift Package Manager and `LSUIElement`. Use the same capture handler for the configurable global shortcut and **Capture Equation** menu item.
- Use an AppKit crosshair and drag overlay with ScreenCaptureKit. Capture at native pixel density on any connected display and constrain each selection to the display where it starts. Escape cancels. Handle first-run screen recording permission and restore focus to the previous app.
- In General, let users toggle screen dimming during selection and adjust its opacity from 1% to 90% when enabled. Capture Appearance reset restores dimming on at 26%. The crosshair, selection outline, and Escape work with dimming off.
- Use the pinned Pix2Text-MFR 1.5 model from the accepted local trial as the v1.0.0 candidate. Qualify it on the frozen 66 printed crops and end-to-end latency gates. Keep the trial local while qualification is pending and preserve the clipboard on malformed output. Bundle the model weights, inference runtime, and math renderer for distribution after qualification. Keep crops in memory during processing. Use one crop-to-LaTeX interface so a later handwriting model can use the same flow.
- Lazy-load recognition in the background when the menu bar app launches (Option B). Do not delay app or menu bar startup, and do not start a duplicate worker during model initialization. A capture started while loading waits behind the single worker and shows the processing popup.
- Copy plain text immediately with the configured wrapper applied once. Immediately after selection, show a brief, non-activating processing popup with a clear indeterminate spinner or progress indicator. Replace it with **Copied** and the typeset equation when recognition and rendering finish. On recognition failure, preserve the clipboard and show a retry message. If only math rendering fails, show **Copied** by itself.
- Render the formula body with bundled KaTeX and use bundled MathJax offline when KaTeX rejects it. Verify both preview paths and keep clipboard copying independent of preview success.

## Menu bar and Settings

- Include **Capture Equation**, **Settings…**, **Check for Updates…**, **Send Feedback…**, and **Quit**. Send Feedback opens the project's GitHub Issues page in the default browser.
- Open a single Settings window with **General** and **Shortcuts** in the sidebar. Start on General, remember the selected section, and bring the existing window forward on reopen.
- General lets users choose **Raw LaTeX** (default), **Inline Markdown** (`$…$`), **Display Markdown** (`$$…$$`), **Inline LaTeX** (`\(…\)`), **Display LaTeX** (`\[…\]`), or **Custom**.
- Custom exposes literal prefix and suffix fields and a live plain-text preview. Allow empty fields and preserve whitespace and line breaks. Remember both fields when switching presets. The copy popup renders the formula body independently of the wrapper.
- Let users assign and clear a global shortcut for opening Settings and for selecting each clipboard format. Show the selected format in General and use it for the next capture. Show only assigned format actions indented below Settings in the menu bar menu, with their key combinations and the active format in bold. Show the Settings shortcut on its menu item when assigned.
- Open Equation History from the menu bar or General, with an optional global shortcut in Shortcuts. The draggable, borderless overlay opens at the top center of the current display. Size previews around the rendered equations, highlight the hovered card, and allow scrolling when entries exceed the display. On a successful click-to-copy, briefly replace the clicked card's blue highlight with green before closing the overlay. A drop accepted by a compatible text field inserts the card's LaTeX and briefly replaces the blue highlight with green at release. Then restore the normal card highlight and keep History open. Both use the current clipboard format. Put a trash button at the top right and confirm before clearing stored history.
- Keep successful LaTeXShot copies as formula bodies in local history across restarts. Enable history by default with a limit of 10 entries. In General, let the user turn history off or on and edit the limit from 1 to 5,000 while it is on. At commit, values above 5,000 save as 5,000. Render all saved formulas, prioritize visible cards, and retain completed previews as the user scrolls sideways. Keep the overlay narrower than the display and sized to the content within that limit. Turning history off pauses recording and closes the overlay, retaining saved entries and the limit. Changing the clipboard format in General or through a menu action or shortcut immediately recopies the latest LaTeXShot equation when available. Copies made with history off remain available for reformatting in memory for the current session.
- Use KeyboardShortcuts to let users change, clear, or restore **⌘⇧L**. Put **Launch at Login** in General, enabled by default in packaged builds subject to macOS login-item controls. Honor the user's choice across relaunches and updates. Show a dismissible first-run hint pointing out the menu bar icon, shortcut, and **Settings → Shortcuts**.
- Provide one **Reset Shortcuts** action. Restore **⌘⇧L** for Capture Equation and clear the optional Settings, Equation History, and format bindings.

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
- Benchmark at least 60 printed crops from PDFs and websites covering fractions, roots, matrices, aligned equations, small type, and dark backgrounds. Require at least 95% mathematically and structurally correct results, allowing equivalent LaTeX syntax. On the development Mac, require both a warm 95th-percentile time under 0.8 seconds and a first capture under 0.8 seconds, measured from mouse-up to clipboard write. Test the first capture immediately after launch and record launch-to-ready time separately. Keep the build local until a candidate passes.
- Deliver a `swift run` build for the user's trial. On a clean macOS account, verify DMG installation, first-launch instructions, app and menu bar icons, the first-run hint, and both Launch at Login states after signing in again. Test manual and scheduled Sparkle checks, installation, and relaunch from an earlier packaged build.
- Publish `v1.0.0` manually under the user's November 25 release decision. Use the verified local DMG and ZIP, publish SHA-256 checksums, and disclose the benchmark result, signing status, and manual update requirement. Future automated releases still require the qualification checks and a signed Sparkle update. Verify the public source, tag, download and feedback links.
- Before shipping handwriting, test tablet notes and onscreen photos of paper separately and rerun the printed benchmark.

## Parallel implementation handoff

| Track | Deliverable |
| --- | --- |
| Mac app and integration | Native capture, Settings, clipboard, and popup. Test the flow with a stub while recognition is evaluated. Integrate the chosen recognizer, artwork, and packaging changes. |
| Offline recognition | Printed fixtures, model benchmarks, and the selected offline recognizer behind the shared crop-to-LaTeX interface. |
| Icon design | Five concepts, user selection, and approved exports for the app, menu bar, README, and website. |
| Packaging and distribution | Versioned package, manual and scheduled Sparkle checks, GitHub Actions, release scripts, README, and Pages site. |

Keep product decisions in the planning chat and implementation in separate chats in the same Codex project. Each track uses its own branch or worktree and reports verification and blockers to the integration lead. See [AGENTS.md](AGENTS.md) for ownership and routing.
