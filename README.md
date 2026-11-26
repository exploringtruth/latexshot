<p align="center">
  <img src="Assets/Icon/LaTeXShot.png" width="128" alt="LaTeXShot app icon">
</p>
<h1 align="center">LaTeXShot</h1>
<p align="center">Screenshot an equation and copy it as LaTeX, offline.</p>
<p align="center">
  <a href="https://github.com/exploringtruth/latexshot/releases/latest/download/LaTeXShot.dmg"><strong>Download the DMG</strong></a>
  · <a href="https://github.com/exploringtruth/latexshot/releases/latest">Latest release</a>
  · <a href="https://exploringtruth.github.io/latexshot/">Website</a>
</p>
<p align="center">
  <a href="#install">Apple silicon · macOS 14 or later</a>
  · <a href="LICENSE">GPL-3.0-only</a>
</p>

LaTeXShot puts printed equations from PDFs and websites on your clipboard. Press **⌘⇧L**, select the equation, and paste the LaTeX into your editor. Recognition runs on your Mac.

## Install

LaTeXShot requires an **Apple silicon Mac (M1 or later) running macOS 14 or later**.

1. Download the [latest DMG](https://github.com/exploringtruth/latexshot/releases/latest/download/LaTeXShot.dmg) and open it.
2. Drag **LaTeXShot** into **Applications**, then eject the disk image.
3. Open **LaTeXShot** from Applications. Grant Screen Recording access when macOS prompts you so LaTeXShot can read the region you select.

The [v1.0.0 ZIP](https://github.com/exploringtruth/latexshot/releases/download/v1.0.0/LaTeXShot-1.0.0.zip) is also available. Verify either download against the [published checksums](https://github.com/exploringtruth/latexshot/releases/download/v1.0.0/SHA256SUMS).

### If macOS blocks the app

LaTeXShot is **ad-hoc signed and unnotarized**. If you trust the copy you downloaded from [GitHub Releases](https://github.com/exploringtruth/latexshot/releases):

1. Open the installed app once to trigger the macOS warning.
2. Go to **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** next to the LaTeXShot warning, then confirm **Open**.
4. Look for the LaTeXShot icon in the menu bar. [Apple’s instructions](https://support.apple.com/en-us/102445)

## Usage

1. Press **⌘⇧L** or choose **Capture Equation** from the menu bar.
2. Drag around a printed equation. Press **Escape** to cancel.
3. Paste the copied LaTeX wherever you need it. A popup previews the equation when rendering succeeds.

Change, clear, or restore the capture shortcut in **Settings → Shortcuts**. A failed recognition leaves your clipboard intact.

## Features

- **Clipboard formats.** Copy raw LaTeX, use Markdown or LaTeX delimiters, or define your own wrapper.
- **Equation History.** Reuse saved formulas in the current clipboard format.
- **Capture and shortcuts.** Adjust selection dimming and assign shortcuts for Settings, Equation History, or clipboard formats.
- **Launch at Login.** Manage it in **Settings → General**.

### Clipboard formats

Choose a format in **Settings → General**. Changing the format immediately recopies the latest LaTeXShot equation when one is available.

| Format | Example |
| --- | --- |
| Raw LaTeX (default) | `x^2` |
| Inline Markdown | `$x^2$` |
| Display Markdown | `$$x^2$$` |
| Inline LaTeX | `\(x^2\)` |
| Display LaTeX | `\[x^2\]` |
| Custom | Your literal prefix + `x^2` + suffix |

Custom wrappers preserve whitespace, line breaks, and empty fields. The popup renders the equation without its clipboard wrapper.

### Equation History

Choose **Equation History** from the menu bar. Click a rendered equation to copy it, or drag it into a compatible text field. History keeps the 10 most recent copies by default. You can pause recording or choose a limit from 1 to 5,000 in **Settings → General**. Use the trash button in the panel to clear saved entries.

## Privacy

The bundled Pix2Text model processes equation crops in memory on your Mac. Crops stay on your device. Preferences and Equation History are stored locally, and saved formulas persist across restarts. The app uses Screen Recording to capture your selection. **Send Feedback…** opens GitHub Issues in your browser, where you choose what to share. LaTeXShot has no analytics.

## FAQ

### Does LaTeXShot need an internet connection to recognize equations?

The installed app recognizes equations offline with the bundled model and runtime.

### What kinds of equations can I capture?

v1.0.0 supports printed equations in PDFs and websites. Handwriting support is planned. The frozen printed-equation benchmark accepted **60 of 66 results (90.9%)** against a 95% target. Review the copied LaTeX before using it. [Benchmark results](benchmarks/pix2text-v1/README.md)

### How do I update v1.0.0?

Download the new version from [GitHub Releases](https://github.com/exploringtruth/latexshot/releases). Quit LaTeXShot, then replace the app in Applications. In-app update checks and automatic updates are disabled in v1.0.0.

## Build from source

Use an Apple silicon Mac with macOS 14 or later, **Swift 6.2 / Xcode 26 or later**, and Python 3.12 or later. Preparing the [pinned Pix2Text runtime and model](docs/runtime/pix2text.md) requires a network connection.

```sh
python3 scripts/build-pix2text-runtime.py /absolute/path/to/latexshot-development
LATEXSHOT_ALLOW_PIX2TEXT_TRIAL=1 \
LATEXSHOT_RECOGNITION_PYTHON=/absolute/path/to/latexshot-development/RecognitionRuntime/bin/python3 \
LATEXSHOT_MODEL_DIRECTORY=/absolute/path/to/latexshot-development/RecognitionModel \
swift run LaTeXShot
```

To build a local v1.0.0 DMG and ZIP with those assets:

```sh
VERSION=1.0.0 \
RECOGNITION_RUNTIME_DIR=/absolute/path/to/latexshot-development/RecognitionRuntime \
RECOGNITION_MODEL_DIR=/absolute/path/to/latexshot-development/RecognitionModel \
bash scripts/build-dmg.sh --local
```

Output goes to `.build/dist/--local/1.0.0/`. See the [packaging and release guide](docs/UPDATER.md) and [product plan](PLAN.md).

## Feedback

Choose **Send Feedback…** in the menu bar or [open a GitHub issue](https://github.com/exploringtruth/latexshot/issues). Include your macOS version and what happened. Share an equation or screenshot only if you intend to make it public.

## License

LaTeXShot’s original source code is licensed under the [GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`).

Third-party components and the Pix2Text model retain their respective licenses. See the [recognition notices](docs/runtime/pix2text-NOTICES.md) and the license files shipped with individual components.
