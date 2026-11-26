#!/usr/bin/env python3
"""Exercise release gates and normal, tampered, and recovered archive verification."""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f'{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


readiness = module('release-readiness')
appcast = module('verify-appcast')
updater = module('test-sparkle-updater')


class ReleaseToolsTests(unittest.TestCase):
    def test_gate_accepts_evidence_rejects_missing_failed_and_outside_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'docs/releases').mkdir(parents=True)
            (root / 'evidence.md').write_text('Observed test result')
            record = {'version': '0.1.0', 'distribution_signing': 'adhoc-unnotarized'}
            for check in readiness.CHECKS:
                record[check] = {'passed': True, 'evidence': 'evidence.md'}
            record['benchmark'] = {'model': readiness.PLUS_S, 'printed_crops': 66, 'correct_fraction': 63 / 66,
                                   'cube_root_exact_repeats': 48, 'decoder_fix_evidence': 'evidence.md',
                                   'repeat_capture_evidence': 'evidence.md',
                                   'warm_p95_seconds': 0.79, 'first_capture_seconds': 0.79,
                                   'first_capture_evidence': 'evidence.md', 'cold_start_ready_seconds': 5.67,
                                   'cold_start_evidence': 'evidence.md',
                                   'timing_scope': 'mouse-up-to-clipboard-including-readiness-wait',
                                   'evidence': 'evidence.md'}
            for asset in ('Assets/Icon/LaTeXShot.icns', 'Assets/Icon/LaTeXShot.png',
                          'Assets/Icon/LaTeXShotMenuBar.pdf', '.github/release-notes/v0.1.0.md', 'Package.resolved'):
                path = root / asset
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
            path = root / 'docs/releases/v0.1.0.json'
            def save(): path.write_text(json.dumps(record))
            save()
            readiness.validate(root, '0.1.0')
            record['user_trial_passed']['passed'] = False
            save()
            with self.assertRaisesRegex(ValueError, 'user_trial_passed'):
                readiness.validate(root, '0.1.0')
            record['user_trial_passed'] = {'passed': True, 'evidence': '../outside.md'}
            save()
            with self.assertRaisesRegex(ValueError, 'Missing repository evidence'):
                readiness.validate(root, '0.1.0')
            record['user_trial_passed']['evidence'] = 'evidence.md'
            record['benchmark']['warm_p95_seconds'] = 0.8
            save()
            with self.assertRaisesRegex(ValueError, 'benchmark'):
                readiness.validate(root, '0.1.0')
            record['benchmark']['warm_p95_seconds'] = 0.79
            for invalid_fraction in (95, True):
                record['benchmark']['correct_fraction'] = invalid_fraction
                save()
                with self.assertRaisesRegex(ValueError, 'benchmark'):
                    readiness.validate(root, '0.1.0')
            record['benchmark']['correct_fraction'] = 0.95
            for field in ('warm_p95_seconds', 'first_capture_seconds'):
                for value in (0.8, 0.801, 0, float('nan'), float('inf')):
                    with self.subTest(field=field, value=value):
                        record['benchmark'][field] = value
                        save()
                        with self.assertRaises(ValueError):
                            readiness.validate(root, '0.1.0')
                record['benchmark'][field] = 0.799999
                save()
                readiness.validate(root, '0.1.0')
            # Legacy reports may have passing warm timings but no first-capture
            # or cold-readiness observations. They must be measured again.
            for field in ('first_capture_seconds', 'first_capture_evidence',
                          'cold_start_ready_seconds', 'cold_start_evidence', 'timing_scope'):
                with self.subTest(missing_legacy_field=field):
                    value = record['benchmark'].pop(field)
                    save()
                    with self.assertRaises(ValueError):
                        readiness.validate(root, '0.1.0')
                    record['benchmark'][field] = value
            record['benchmark']['first_capture_evidence'] = '../outside.md'
            save()
            with self.assertRaisesRegex(ValueError, 'first capture evidence'):
                readiness.validate(root, '0.1.0')
            record['benchmark']['first_capture_evidence'] = 'evidence.md'
            for model in ('PaddlePaddle/PP-FormulaNet-S', 'PP-FormulaNet_plus-S', '', ' ', None):
                with self.subTest(model=model):
                    record['benchmark']['model'] = model
                    save()
                    with self.assertRaisesRegex(ValueError, 'requires benchmark.model'):
                        readiness.validate(root, '0.1.0')
            del record['benchmark']['model']
            save()
            with self.assertRaisesRegex(ValueError, 'requires benchmark.model'):
                readiness.validate(root, '0.1.0')
            record['benchmark']['model'] = readiness.PLUS_S
            record['benchmark']['printed_crops'] = 60
            save()
            with self.assertRaisesRegex(ValueError, 'frozen 66-crop benchmark'):
                readiness.validate(root, '0.1.0')
            record['benchmark']['printed_crops'] = 66
            record['benchmark']['correct_fraction'] = 63 / 66
            record['benchmark']['cube_root_exact_repeats'] = 47
            save()
            with self.assertRaisesRegex(ValueError, '48 exact cube-root recaptures'):
                readiness.validate(root, '0.1.0')
            record['benchmark']['cube_root_exact_repeats'] = 48
            for field, label in (('decoder_fix_evidence', 'decoder fix'),
                                 ('repeat_capture_evidence', 'repeat-capture')):
                del record['benchmark'][field]
                save()
                with self.assertRaisesRegex(ValueError, label):
                    readiness.validate(root, '0.1.0')
                record['benchmark'][field] = 'evidence.md'
            save()
            readiness.validate(root, '0.1.0')

    def test_v1_rejects_wrong_model_failed_accuracy_and_unpinned_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version = readiness.PIX2TEXT_VERSION
            for file in (f'docs/releases/v{version}.json', 'evidence.md',
                         'Assets/Icon/LaTeXShot.icns', 'Assets/Icon/LaTeXShot.png',
                         'Assets/Icon/LaTeXShotMenuBar.pdf', f'.github/release-notes/v{version}.md',
                         'Package.resolved', readiness.PIX2TEXT_LOCK):
                path = root / file
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
            record = {'version': version, 'distribution_signing': 'adhoc-unnotarized'}
            for check in readiness.CHECKS:
                record[check] = {'passed': True, 'evidence': 'evidence.md'}
            benchmark = {'model': readiness.PIX2TEXT, 'model_revision': readiness.PIX2TEXT_REVISION,
                         'printed_crops': 66, 'correct_fraction': 63 / 66, 'warm_p95_seconds': 0.79,
                         'first_capture_seconds': 0.79, 'cold_start_ready_seconds': 3,
                         'timing_scope': 'mouse-up-to-clipboard-including-readiness-wait',
                         'evidence': 'evidence.md', 'first_capture_evidence': 'evidence.md',
                         'cold_start_evidence': 'evidence.md'}
            record['benchmark'] = benchmark
            record['recognition_archives'] = {'runtime_sha256': 'a' * 64, 'model_sha256': 'b' * 64}

            def save():
                (root / f'docs/releases/v{version}.json').write_text(json.dumps(record))

            save()
            readiness.validate(root, version)
            for field, wrong, message in (('model', readiness.PLUS_S, 'requires breezedeus'),
                                          ('model_revision', 'main', 'revision'),
                                          ('correct_fraction', 60 / 66, '>=95%')):
                with self.subTest(field=field):
                    previous = benchmark[field]
                    benchmark[field] = wrong
                    save()
                    with self.assertRaisesRegex(ValueError, message):
                        readiness.validate(root, version)
                    benchmark[field] = previous
            record['recognition_archives']['model_sha256'] = ''
            save()
            with self.assertRaisesRegex(ValueError, 'model archive SHA-256'):
                readiness.validate(root, version)

    def test_release_asset_archives_must_match_the_reviewed_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archives = root / 'archives'
            archives.mkdir()
            record = {'recognition_archives': {}}
            for kind in readiness.ARCHIVES:
                data = f'fixture {kind}'.encode()
                archive_path = archives / f'{kind}.tar.gz'
                with tarfile.open(archive_path, 'w:gz') as archive:
                    file = tarfile.TarInfo('fixture')
                    file.size = len(data)
                    archive.addfile(file, io.BytesIO(data))
                digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
                record['recognition_archives'][f'{kind}_sha256'] = digest
            with patch.dict(os.environ, {'RECOGNITION_RUNTIME_SHA256': 'a' * 64}):
                with self.assertRaisesRegex(ValueError, 'RECOGNITION_RUNTIME_SHA256'):
                    readiness.check_archive_configuration(record)
            with patch.dict(os.environ, {
                f'RECOGNITION_{kind.upper()}_SHA256': digest
                for kind, digest in readiness.archive_checksums(record).items()
            }):
                readiness.check_archive_configuration(record)
            readiness.stage_release_assets(record, archives, root / 'staged')
            self.assertEqual((root / 'staged/runtime/fixture').read_text(), 'fixture runtime')
            self.assertEqual((root / 'staged/model/fixture').read_text(), 'fixture model')
            (archives / 'model.tar.gz').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'model archive checksum mismatch'):
                readiness.stage_release_assets(record, archives, root / 'tampered')

    def test_v1_packaged_pix2text_model_checks_both_digest_types_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_lock = root / readiness.PIX2TEXT_LOCK
            source_lock.parent.mkdir(parents=True)
            resources = root / 'Contents/Resources'
            bundle = resources / 'LaTeXShot_EquationRecognition.bundle/Contents/Resources/Resources'
            bundle.mkdir(parents=True)
            packaged_lock = bundle / source_lock.name
            model = resources / 'RecognitionModel'
            model.mkdir()
            config = b'{}'
            weights = b'pinned weights'
            lock = {
                'config.json': hashlib.sha1(b'blob 2\0' + config).hexdigest(),
                'encoder_model.onnx': hashlib.sha256(weights).hexdigest(),
            }
            source_lock.write_text(json.dumps(lock))
            packaged_lock.write_bytes(source_lock.read_bytes())
            (model / 'config.json').write_bytes(config)
            (model / 'encoder_model.onnx').write_bytes(weights)
            readiness.validate_staged_pix2text(root, resources)
            packaged_lock.write_text('{}')
            with self.assertRaisesRegex(ValueError, 'model lock differs'):
                readiness.validate_staged_pix2text(root, resources)
            packaged_lock.write_bytes(source_lock.read_bytes())
            (model / 'config.json').write_bytes(b'[]')
            with self.assertRaisesRegex(ValueError, 'model checksum mismatch: config.json'):
                readiness.validate_staged_pix2text(root, resources)
            (model / 'config.json').write_bytes(config)
            (model / 'unexpected').touch()
            with self.assertRaisesRegex(ValueError, 'exactly the pinned files'):
                readiness.validate_staged_pix2text(root, resources)
            (model / 'unexpected').unlink()
            external = root / 'encoder_model.onnx'
            (model / external.name).rename(external)
            (model / external.name).symlink_to(external)
            with self.assertRaisesRegex(ValueError, 'Invalid staged Pix2Text model file'):
                readiness.validate_staged_pix2text(root, resources)

    def test_staged_model_must_match_plus_s_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock_path = root / readiness.PLUS_S_LOCK
            lock_path.parent.mkdir(parents=True)
            model = root / 'RecognitionModel'
            model.mkdir()
            weights = model / 'inference.pdiparams'
            expected = b'plus-s'
            lock = {'repository': readiness.PLUS_S, 'files': [{
                'name': weights.name, 'bytes': len(expected),
                'sha256': hashlib.sha256(expected).hexdigest(),
            }]}
            lock_path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, 'Missing or invalid pinned model file'):
                readiness.validate_staged_plus_s(root, model)
            weights.write_bytes(b'base-s')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                readiness.validate_staged_plus_s(root, model)
            weights.write_bytes(expected)
            readiness.validate_staged_plus_s(root, model)
            alternate = model / 'inference.pdmodel'
            alternate.write_bytes(expected)
            with self.assertRaisesRegex(ValueError, 'Unexpected staged model files'):
                readiness.validate_staged_plus_s(root, model)
            alternate.unlink()
            external = root / weights.name
            weights.rename(external)
            weights.symlink_to(external)
            with self.assertRaisesRegex(ValueError, 'Missing or invalid pinned model file'):
                readiness.validate_staged_plus_s(root, model)
            weights.unlink()
            external.rename(weights)
            lock['repository'] = 'PaddlePaddle/PP-FormulaNet-S'
            lock_path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, 'Expected a populated model lock'):
                readiness.validate_staged_plus_s(root, model)

    def test_missing_and_placeholder_public_key_rejected(self):
        for value in ('', 'not-base64', base64.b64encode(bytes(32)).decode()):
            with self.assertRaises(ValueError): readiness.public_key(value)

    def test_signed_archive_tamper_recovery_and_feed_url(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'LaTeXShot-0.1.0.zip'
            archive.write_bytes(b'ephemeral test archive bytes')
            # This test key exists only in process memory; no private key is exported.
            generator = root / 'fixture.swift'
            generator.write_text('''import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let bytes = try Data(contentsOf: root.appendingPathComponent("LaTeXShot-0.1.0.zip"))
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public"), atomically: true, encoding: .utf8)
try key.signature(for: bytes).base64EncodedString().write(to: root.appendingPathComponent("signature"), atomically: true, encoding: .utf8)
''')
            subprocess.run(['swift', str(generator), str(root)], check=True)
            public = (root / 'public').read_text()
            signature = (root / 'signature').read_text()
            app = root / 'LaTeXShot.app'
            (app / 'Contents').mkdir(parents=True)
            with (app / 'Contents/Info.plist').open('wb') as stream:
                plistlib.dump({'CFBundleVersion': '0.1.0', 'SUPublicEDKey': public}, stream)
            feed = root / 'appcast.xml'
            def save(url=None):
                feed.write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>0.1.0</sparkle:version><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{url or 'https://github.com/exploringtruth/latexshot/releases/download/v0.1.0/LaTeXShot-0.1.0.zip'}" length="{archive.stat().st_size}" sparkle:edSignature="{signature}"/>
</item></channel></rss>''')
            previous = os.environ.get('SPARKLE_PUBLIC_ED_KEY')
            os.environ['SPARKLE_PUBLIC_ED_KEY'] = public
            try:
                save()
                appcast.verify(feed, archive, app, '0.1.0')
                original = archive.read_bytes()
                archive.write_bytes(b'X' + original[1:])  # same length; crypto must reject
                with self.assertRaises(subprocess.CalledProcessError):
                    appcast.verify(feed, archive, app, '0.1.0')
                archive.write_bytes(original)
                appcast.verify(feed, archive, app, '0.1.0')
                save('https://example.com/substituted.zip')
                with self.assertRaisesRegex(ValueError, 'URL'):
                    appcast.verify(feed, archive, app, '0.1.0')
            finally:
                if previous is None: os.environ.pop('SPARKLE_PUBLIC_ED_KEY', None)
                else: os.environ['SPARKLE_PUBLIC_ED_KEY'] = previous

    def test_disposable_sparkle_updater_cycle(self):
        result = updater.run_smoke_test()
        self.assertTrue(result['success'], f"Updater smoke test failed: {result.get('error')}")
        self.assertEqual(result['final_version'], '2.0')
        self.assertEqual(result['config']['update_interval'], 86400)
        self.assertTrue(result['config']['automatically_checks'])
        for expected in ('manualCheck', 'updateFound', 'downloadStarted', 'extracting', 'readyToInstall', 'willInstall', 'installing'):
            self.assertIn(expected, result['event_names'])


if __name__ == '__main__':
    unittest.main()
