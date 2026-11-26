#!/usr/bin/env python3
"""Disposable Sparkle updater smoke test.

Verifies manual check, 24-hour scheduled check interval, download, Ed25519 archive
verification, extraction, and relaunch in an isolated disposable sandbox without
modifying user preferences or system installation.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent


def find_sparkle_framework(hint=None):
    if hint and Path(hint).is_dir():
        return Path(hint).resolve()

    env_path = os.environ.get("SPARKLE_FRAMEWORK_PATH")
    if env_path and Path(env_path).is_dir():
        return Path(env_path).resolve()

    candidates = [
        # SwiftPM build artifacts
        REPO_ROOT / ".build/packaging/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework",
        REPO_ROOT / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework",
        # Local staged packages
        Path("/private/tmp/latexshot-current-package.oEgI4nai/LaTeXShot.app/Contents/Frameworks/Sparkle.framework"),
        Path("/private/tmp/latexshot-integrated.obwZBvlK/.build/package/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"),
        Path("/private/tmp/latexshot-main-swift.1xsKOu76/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"),
        Path("/private/tmp/latexshot-tracks.O5guQbgA/mac-app/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"),
    ]

    for candidate in candidates:
        if candidate.is_dir():
            return candidate.resolve()

    # Dynamic search in .build and /private/tmp
    for search_root in (REPO_ROOT / ".build", Path("/private/tmp")):
        if search_root.is_dir():
            for found in search_root.rglob("Sparkle.framework"):
                if found.is_dir() and (found / "Sparkle").exists():
                    return found.resolve()

    raise RuntimeError(
        "Sparkle.framework not found. Build a local package first or set SPARKLE_FRAMEWORK_PATH."
    )


def generate_ephemeral_keypair(out_dir: Path):
    swift_code = f"""
import Foundation
import CryptoKit

let root = URL(fileURLWithPath: "{out_dir}")
let key = Curve25519.Signing.PrivateKey()
let privatePath = root.appendingPathComponent("test-private-seed")
try key.rawRepresentation.base64EncodedString().write(to: privatePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privatePath.path)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("test-public-key"), atomically: true, encoding: .utf8)
"""
    subprocess.run(["swift", "-"], input=swift_code.encode(), check=True, capture_output=True)
    pub_key = (out_dir / "test-public-key").read_text().strip()
    seed_path = out_dir / "test-private-seed"
    return pub_key, seed_path


def sign_zip(zip_path: Path, seed_path: Path) -> str:
    swift_code = f"""
import Foundation
import CryptoKit

let seedBase64 = try String(contentsOfFile: "{seed_path}", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let seed = Data(base64Encoded: seedBase64)!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let zipData = try Data(contentsOf: URL(fileURLWithPath: "{zip_path}"))
let sig = try key.signature(for: zipData)
print(sig.base64EncodedString())
"""
    res = subprocess.run(["swift", "-"], input=swift_code.encode(), capture_output=True, check=True)
    return res.stdout.decode().strip()


def compile_smoke_driver(source_path: Path, framework_path: Path, output_binary: Path):
    output_binary.parent.mkdir(parents=True, exist_ok=True)
    framework_dir = framework_path.parent
    cmd = [
        "clang",
        "-fobjc-arc",
        "-framework", "Cocoa",
        "-F", str(framework_dir),
        "-framework", "Sparkle",
        "-Wl,-rpath,@executable_path/../Frameworks",
        str(source_path),
        "-o", str(output_binary),
    ]
    subprocess.run(cmd, check=True, capture_output=True)


def assemble_bundle(app_path: Path, binary_path: Path, framework_path: Path,
                    bundle_id: str, version: str, port: int, pub_key: str, smoke_root: Path):
    if app_path.exists():
        shutil.rmtree(app_path)
    macos = app_path / "Contents/MacOS"
    frameworks = app_path / "Contents/Frameworks"
    macos.mkdir(parents=True, exist_ok=True)
    frameworks.mkdir(parents=True, exist_ok=True)

    shutil.copy2(binary_path, macos / "UpdaterSmoke")
    (macos / "UpdaterSmoke").chmod(0o755)

    shutil.copytree(framework_path, frameworks / "Sparkle.framework", symlinks=True)

    plist = {
        "CFBundleExecutable": "UpdaterSmoke",
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "UpdaterSmoke",
        "CFBundleVersion": version,
        "CFBundleShortVersionString": version,
        "CFBundlePackageType": "APPL",
        "SmokeRoot": str(smoke_root),
        "SUFeedURL": f"http://127.0.0.1:{port}/appcast.xml",
        "SUPublicEDKey": pub_key,
        "SUScheduledCheckInterval": 86400,
        "SUEnableAutomaticChecks": True,
    }
    with open(app_path / "Contents/Info.plist", "wb") as f:
        plistlib.dump(plist, f)

    subprocess.run(["codesign", "-s", "-", "--force", "--deep", str(app_path)], check=True, capture_output=True)


def run_smoke_test(sparkle_framework=None, work_dir=None, timeout=30):
    framework = find_sparkle_framework(sparkle_framework)
    source_m = SCRIPTS_DIR / "sparkle-smoke.m"
    if not source_m.exists():
        raise FileNotFoundError(f"Missing smoke source: {source_m}")

    managed_temp = None
    if work_dir:
        root = Path(work_dir).resolve()
        root.mkdir(parents=True, exist_ok=True)
    else:
        managed_temp = tempfile.TemporaryDirectory(prefix="latexshot-sparkle-smoke.", dir="/private/tmp")
        root = Path(managed_temp.name)

    test_id = uuid.uuid4().hex[:8]
    bundle_id = f"io.github.exploringtruth.LaTeXShot.DisposableUpdaterTest.{test_id}"

    build_dir = root / "build"
    feed_dir = root / "feed"
    installed_dir = root / "installed"
    build_dir.mkdir(parents=True, exist_ok=True)
    feed_dir.mkdir(parents=True, exist_ok=True)
    installed_dir.mkdir(parents=True, exist_ok=True)

    binary_path = build_dir / "UpdaterSmoke"
    compile_smoke_driver(source_m, framework, binary_path)

    pub_key, seed_path = generate_ephemeral_keypair(root)

    # Local quiet HTTP server on ephemeral port
    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(feed_dir), **kwargs)

        def log_message(self, format, *args):
            pass

    server = socketserver.TCPServer(("127.0.0.1", 0), QuietHandler)
    port = server.server_address[1]
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    proc = None
    events = []
    events_path = root / "events.jsonl"
    relaunched_path = root / "relaunched.txt"

    try:
        # Build v2.0
        v2_app = build_dir / "UpdaterSmoke.app"
        assemble_bundle(v2_app, binary_path, framework, bundle_id, "2.0", port, pub_key, root)

        # Zip v2.0
        zip_path = feed_dir / "UpdaterSmoke-2.0.zip"
        if zip_path.exists():
            zip_path.unlink()
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(v2_app), str(zip_path)], check=True)
        zip_size = zip_path.stat().st_size
        sig = sign_zip(zip_path, seed_path)

        # Release notes and feed
        (feed_dir / "release-notes.html").write_text("<html><body>Version 2.0 release notes</body></html>")
        appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>UpdaterSmoke</title>
    <item>
      <title>Version 2.0</title>
      <sparkle:releaseNotesLink>http://127.0.0.1:{port}/release-notes.html</sparkle:releaseNotesLink>
      <pubDate>Mon, 23 Nov 2026 12:00:00 +0000</pubDate>
      <enclosure url="http://127.0.0.1:{port}/UpdaterSmoke-2.0.zip"
                 sparkle:version="2.0"
                 sparkle:shortVersionString="2.0"
                 length="{zip_size}"
                 type="application/octet-stream"
                 sparkle:edSignature="{sig}" />
    </item>
  </channel>
</rss>
"""
        (feed_dir / "appcast.xml").write_text(appcast)

        # Build v1.0 in installed/
        v1_app = installed_dir / "UpdaterSmoke.app"
        assemble_bundle(v1_app, binary_path, framework, bundle_id, "1.0", port, pub_key, root)

        # Launch v1.0
        proc = subprocess.Popen([str(v1_app / "Contents/MacOS/UpdaterSmoke")])

        # Wait for relaunch
        start_time = time.time()
        while time.time() - start_time < timeout:
            if relaunched_path.exists():
                break
            time.sleep(0.2)

        # Allow relaunched app to write its event and terminate
        time.sleep(1.5)

    finally:
        server.shutdown()
        server.server_close()
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()

    if events_path.exists():
        for line in events_path.read_text().splitlines():
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

    event_names = [e.get("event") for e in events]
    relaunched_success = relaunched_path.exists()

    config_event = next((e for e in events if e.get("event") == "updaterConfigured"), {})
    final_launch = next((e for e in reversed(events) if e.get("event") == "launched"), {})

    success = (
        relaunched_success
        and "manualCheck" in event_names
        and "updateFound" in event_names
        and "downloadStarted" in event_names
        and "extracting" in event_names
        and "readyToInstall" in event_names
        and "installing" in event_names
        and final_launch.get("version") == "2.0"
    )

    result = {
        "success": success,
        "bundle_id": bundle_id,
        "port": port,
        "final_version": final_launch.get("version"),
        "config": {
            "automatically_checks": config_event.get("automaticallyChecks", True),
            "update_interval": config_event.get("updateInterval", 86400),
        },
        "event_names": event_names,
        "events": events,
        "error": None if success else f"Update cycle did not complete. Events: {event_names}",
    }

    if managed_temp:
        try:
            managed_temp.cleanup()
        except Exception:
            pass

    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", help="Path to Sparkle.framework")
    parser.add_argument("--work-dir", help="Directory to use for test artifacts (preserved)")
    parser.add_argument("--timeout", type=int, default=30, help="Timeout in seconds")
    parser.add_argument("--json", action="store_true", help="Output JSON result")
    args = parser.parse_args()

    try:
        res = run_smoke_test(sparkle_framework=args.framework, work_dir=args.work_dir, timeout=args.timeout)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Disposable Sparkle updater smoke test: {'PASSED' if res['success'] else 'FAILED'}")
            print(f"Bundle ID: {res['bundle_id']}")
            print(f"Scheduled interval: {res['config']['update_interval']}s, Auto-check: {res['config']['automatically_checks']}")
            print(f"Observed events: {' -> '.join(res['event_names'])}")
            if not res["success"]:
                print(f"Error: {res['error']}", file=sys.stderr)
        return 0 if res["success"] else 1
    except Exception as exc:
        if args.json:
            print(json.dumps({"success": False, "error": str(exc)}, indent=2))
        else:
            print(f"Error executing smoke test: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
