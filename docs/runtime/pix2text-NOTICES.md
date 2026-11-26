# LaTeXShot recognition notices

Pix2Text-MFR 1.5 by BreezeDeus is distributed under the MIT license. This
directory includes the model card from the pinned model revision and the
Pix2Text MIT license text.

The bundled CPython distribution comes from Astral's Python Standalone Builds.
The `licenses/` directory and `PYTHON.json` come from the matching full release
archive and describe CPython and its bundled dependencies.

Python wheel license and notice files are installed alongside their packages
and in their `.dist-info` directories under `../lib/python3.12/site-packages`.
This directory also includes the upstream FlatBuffers and Hugging Face
Tokenizers license files. The corresponding source distributions for
MPL-licensed certifi and tqdm are provided in `sources/` under their original
licenses. Their download URLs and SHA-256 identities, along with those of the
other original artifacts, are recorded in `pix2text-lock.json`.

Three compiled libraries in the Pillow and torchvision wheels had their
upstream build-machine search paths removed. Their versions and model
behavior are unchanged. The affected paths are recorded in the lock.
