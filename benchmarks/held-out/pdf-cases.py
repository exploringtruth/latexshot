"""Capture six independently published PDF systems before model evaluation."""
import argparse
import hashlib
import json
import math
from pathlib import Path

import pypdfium2

parser = argparse.ArgumentParser()
parser.add_argument("--pdf", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
digest = hashlib.sha256(args.pdf.read_bytes()).hexdigest()
if digest != "5240f2782e645bc6351ad9eba69d8c19500142a5cca9c90450c17b3765a1a400":
    raise SystemExit("PDF changed. Verify source, license and ground truth again.")
cases = [
    (13, "1.3", "3x1 + 2x2 = 7\r\n−x1 + x2 = 6", r"\begin{aligned}3x_1+2x_2&=7\\-x_1+x_2&=6\end{aligned}"),
    (15, "1.7", "x + y = 0\r\n2x − y + 3z = 3\r\nx − 2y − z = 3", r"\begin{aligned}x+y&=0\\2x-y+3z&=3\\x-2y-z&=3\end{aligned}"),
    (16, "1.9", "x + y + z = 9\r\n2x + 4y − 3z = 1\r\n3x + 6y − 5z = 0", r"\begin{aligned}x+y+z&=9\\2x+4y-3z&=1\\3x+6y-5z&=0\end{aligned}"),
    (16, "1.11", "x − y = 0\r\n2x − 2y + z + 2w = 4\r\ny + w = 0\r\n2z + w = 5", r"\begin{aligned}x-y&=0\\2x-2y+z+2w&=4\\y+w&=0\\2z+w&=5\end{aligned}"),
    (17, "1.12", "x + 3y = 1\r\n2x + y = −3\r\n2x + 2y = −2", r"\begin{aligned}x+3y&=1\\2x+y&=-3\\2x+2y&=-2\end{aligned}"),
    (18, "1.14", "x + 2y = 8\r\n2x + 4y = 8", r"\begin{aligned}x+2y&=8\\2x+4y&=8\end{aligned}"),
]
args.output.mkdir(parents=True, exist_ok=True)
(args.output / "crops").mkdir(exist_ok=True)
document = pypdfium2.PdfDocument(args.pdf)
manifest = []
for index, (page_number, example, excerpt, expected) in enumerate(cases, 1):
    page = document[page_number - 1]
    textpage = page.get_textpage()
    text = textpage.get_text_range()
    start = text.index(excerpt)
    boxes = [textpage.get_charbox(i) for i in range(start, start + len(excerpt))]
    boxes = [box for box in boxes if box[2] > box[0] and box[3] > box[1]]
    left, bottom = min(box[0] for box in boxes), min(box[1] for box in boxes)
    right, top = max(box[2] for box in boxes), max(box[3] for box in boxes)
    bounds = (math.floor((left - 3) * 2), math.floor((page.get_height() - top - 3) * 2),
              math.ceil((right + 3) * 2), math.ceil((page.get_height() - bottom + 3) * 2))
    image = page.render(scale=2).to_pil().crop(bounds)
    identifier = "hefferon-" + str(index).zfill(2)
    target = args.output / "crops" / (identifier + ".png")
    image.save(target)
    manifest.append({"id": identifier, "image": "crops/" + identifier + ".png", "category": "aligned",
        "latex": expected, "source_url": "https://jheffero.w3.uvm.edu/linearalgebra/book.pdf",
        "source_title": "Linear Algebra, Fourth edition", "author": "Jim Hefferon",
        "source_pdf_sha256": digest, "pdf_page_one_based": page_number, "example": example,
        "printed_page": page_number - 10, "source_text_excerpt": excerpt,
        "expected_latex_provenance": "Manually transcribed system, checked against PDF text and rendered crop before inference",
        "license": "CC-BY-SA-3.0-US", "license_url": "https://creativecommons.org/licenses/by-sa/3.0/us/",
        "license_evidence": "https://hefferon.net/source.html", "author_site": "https://hefferon.net/linearalgebra/",
        "render_changes": "PDF rasterized at 144 dpi and cropped. No mathematical content edited.",
        "pixel_bounds": bounds, "image_sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
(args.output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print("Captured", len(manifest), "PDF systems")
