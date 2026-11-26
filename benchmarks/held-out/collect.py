"""Freeze source equations before inference. Downloads remain outside the checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

from lxml import html

parser = argparse.ArgumentParser()
parser.add_argument("--cache", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
pages = ["Fraction", "Square_root", "Matrix_(mathematics)", "System_of_linear_equations",
         "Derivative", "Integration_by_parts", "Quadratic_formula", "Gaussian_elimination"]
args.cache.mkdir(parents=True, exist_ok=True)
args.output.mkdir(parents=True, exist_ok=True)
sources = {}
for page in pages:
    url = "https://en.wikipedia.org/wiki/" + page
    cached = args.cache / (page + ".html")
    if not cached.exists():
        request = urllib.request.Request(url, headers={"User-Agent": "LaTeXShot-benchmark/0.1"})
        cached.write_bytes(urllib.request.urlopen(request, timeout=30).read())
    document = html.fromstring(cached.read_bytes())
    footer = document.xpath("//*[@id='footer-info-copyright']")[0].text_content()
    if "Creative Commons Attribution-ShareAlike 4.0" not in footer:
        raise RuntimeError("Review the source license before proceeding: " + page)
    permalink = document.xpath("//*[@id='t-permalink']/a/@href")[0]
    sources[page] = {"url": url, "permalink": "https://en.wikipedia.org" + permalink,
        "history": url + "?action=history", "copyright_holder": "Wikipedia contributors",
        "license": "CC-BY-SA-4.0", "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
        "footer_notice": footer.strip(), "source_html_sha256": hashlib.sha256(cached.read_bytes()).hexdigest(),
        "candidates": []}
    for node in document.xpath("//*[contains(@class,'mwe-math-element')][@data-mw]"):
        body = json.loads(node.get("data-mw")).get("body", {}).get("extsrc", "")
        sources[page]["candidates"].append({"node_id": node.get("id"), "latex": body.strip(),
            "display": "block" in node.get("class", ""),
            "mathml": html.tostring(node, encoding="unicode", with_tail=False)})

groups = [
    ("fractions", ["Fraction"], lambda x: "\\frac" in x["latex"] and "=" in x["latex"]),
    ("roots", ["Square_root", "Quadratic_formula"], lambda x: "\\sqrt" in x["latex"] and "=" in x["latex"]),
    ("matrices", ["Matrix_(mathematics)"], lambda x: any(s in x["latex"] for s in ("{bmatrix}", "{pmatrix}")) and "\\color" not in x["latex"]),
    ("aligned", ["System_of_linear_equations", "Gaussian_elimination", "Integration_by_parts"],
        lambda x: any(s in x["latex"] for s in ("{align}", "{aligned}")) and "\\\\" in x["latex"] and "=" in x["latex"] and "matrix" not in x["latex"]),
    ("small-type", ["Derivative", "Fraction"], lambda x: not x["display"] and "=" in x["latex"]),
    ("dark-background", ["Integration_by_parts", "Quadratic_formula"], lambda x: x["display"] and "=" in x["latex"]),
]
manifest = []
seen = set()
for category, choices, condition in groups:
    selected = []
    for page in choices:
        for candidate in sources[page]["candidates"]:
            normalized = re.sub(r"\s+", "", candidate["latex"])
            if normalized in seen or not 18 <= len(candidate["latex"]) <= 700 or not condition(candidate):
                continue
            identifier = category + "-" + str(len(selected) + 1).zfill(2)
            selected.append({"id": identifier, "image": "crops/" + identifier + ".png",
                "category": category, "source_page": page, "source_url": sources[page]["url"],
                "source_revision_url": sources[page]["permalink"], "source_node_id": candidate["node_id"],
                "latex": candidate["latex"], "expected_latex_provenance": "Unmodified source data-mw.body.extsrc attached to the captured native MathML node",
                "license": "CC-BY-SA-4.0", "attribution": "Wikipedia contributors, " + page.replace("_", " "),
                "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
                "render_changes": "12px math font" if category == "small-type" else "dark page color override" if category == "dark-background" else "none",
                "source_mathml": candidate["mathml"]})
            seen.add(normalized)
            if len(selected) == 10:
                break
        if len(selected) == 10:
            break
    if len(selected) != 10:
        raise RuntimeError("Insufficient independently authored cases for " + category)
    manifest.extend(selected)
(args.output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
for source in sources.values():
    del source["candidates"]
(args.output / "sources.json").write_text(json.dumps(sources, indent=2, ensure_ascii=False) + "\n")
print("Frozen", len(manifest), "distinct expected formulas")
