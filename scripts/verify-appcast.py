#!/usr/bin/env python3
"""Check release URL, metadata, archive size and Ed25519 signature together."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET


def verify(feed, archive, app, version):
    namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    tree = ET.parse(feed)
    items = tree.findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one release in this fresh appcast')
    item = items[0]
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('Missing update enclosure')
    expected = f'https://github.com/exploringtruth/latexshot/releases/download/v{version}/LaTeXShot-{version}.zip'
    if enclosure.get('url') != expected or int(enclosure.get('length', -1)) != archive.stat().st_size:
        raise ValueError('Update URL or archive length mismatch')
    actual_version = item.findtext(namespace + 'version') or enclosure.get(namespace + 'version')
    if actual_version != version or item.findtext(namespace + 'minimumSystemVersion') != '14.0':
        raise ValueError('Appcast version or minimum macOS mismatch')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        plist = plistlib.load(stream)
    if (plist.get('CFBundleVersion') != version or
            plist.get('SUPublicEDKey') != os.environ.get('SPARKLE_PUBLIC_ED_KEY')):
        raise ValueError('App metadata or embedded public key mismatch')
    signature = enclosure.get(namespace + 'edSignature', '')
    subprocess.run(['swift', str(Path(__file__).with_name('verify-signature.swift')), str(archive),
                    plist['SUPublicEDKey'], signature], check=True)


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    except (IndexError, ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
