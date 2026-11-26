"""Recreate the controlled Chrome MathML drag variants using a fresh browser profile."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageChops

parser = argparse.ArgumentParser()
parser.add_argument("--chrome", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
html = Path(__file__).parent / "recaptures/sample.html"
manifest = []
version = subprocess.check_output([args.chrome, "--version"], text=True).strip()
for scale in (1, 2):
    screenshot = (args.output / f"scale-{scale}.png").resolve()
    with tempfile.TemporaryDirectory(prefix="latexshot-recapture-chrome-") as profile:
        subprocess.run([args.chrome, "--headless", "--no-first-run", "--disable-background-networking",
                        "--hide-scrollbars", "--user-data-dir=" + profile,
                        "--window-size=600,760", f"--force-device-scale-factor={scale}",
                        "--screenshot=" + str(screenshot), html.resolve().as_uri()],
                       check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    image = Image.open(screenshot).convert("RGB")
    for theme_index, theme in enumerate(("light", "dark")):
        for size_index, size in enumerate((24, 36, 48)):
            top = (theme_index * 3 + size_index) * 120 * scale
            cell = image.crop((0, top, image.width, top + 120 * scale))
            background = Image.new("RGB", cell.size, cell.getpixel((0, 0)))
            bounds = ImageChops.difference(cell, background).getbbox()
            if bounds is None:
                raise RuntimeError("Browser produced a blank equation")
            for padding in (2, 6, 16, 30):
                left, top, right, bottom = bounds
                box = (max(0, left - padding * scale), max(0, top - (padding // 2 + 2) * scale),
                       min(cell.width, right + (padding // 2 + 2) * scale),
                       min(cell.height, bottom + padding * scale))
                identifier = f"root-{scale}x-{size}px-{theme}-{padding}"
                cell.crop(box).save(args.output / (identifier + ".png"))
                manifest.append({"id": identifier, "image": identifier + ".png",
                                 "latex": r"\sqrt{x+1}+\sqrt[3]{y}=1"})
(args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(args.output / "capture-environment.json").write_text(json.dumps({"chrome": version,
    "screen_capture": "Chrome headless rasterization followed by complete-ink crops",
    "scale_factors": [1, 2], "font_sizes_css_px": [24, 36, 48],
    "drag_parameter_css_px": [2, 6, 16, 30],
    "drag_margins": "left=p, top=floor(p/2)+2, right=floor(p/2)+2, bottom=p"}, indent=2) + "\n")
