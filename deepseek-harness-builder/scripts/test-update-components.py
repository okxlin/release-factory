#!/usr/bin/env python3
"""Exercise pin refresh and artifact boundaries without network access."""
import copy
import hashlib
import importlib.util
import io
import json
import tarfile
import unittest
import urllib.request
from pathlib import Path
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("updater", HERE / "update-components.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads((HERE.parent / "image/components.lock.json").read_text())
        self.source = json.loads((HERE.parent / "image/dsh-source.json").read_text())
        self.image = lambda image, tag: next(v for k, v in self.lock["build_args"].items()
                                           if k.endswith("_IMAGE") and v.startswith(image + ":"))

    def refresh(self, keys, version, fetch=lambda url: b"archive", image=None):
        policy = [{"name": key, "pin": key} for key in keys]
        with patch.object(updater.checker, "upstream_version", return_value=(version, "https://example.test/release")):
            return updater.refresh(self.lock, self.source, policy, Mock(), fetch, image or self.image)

    def test_no_update_is_idempotent_and_does_not_downgrade(self):
        lock, source, changes = self.refresh(["PNPM_VERSION"], "1.0.0", fetch=Mock(side_effect=AssertionError))
        self.assertEqual((lock, source, changes), (self.lock, self.source, []))

    def test_npm_pin_and_checksum_change_together_without_mutating_input(self):
        original = copy.deepcopy(self.lock)
        lock, _, changes = self.refresh(["PNPM_VERSION"], "99.0.0")
        self.assertEqual(lock["build_args"]["PNPM_VERSION"], "99.0.0")
        self.assertEqual(lock["build_args"]["PNPM_ARCHIVE_SHA256"], hashlib.sha256(b"archive").hexdigest())
        self.assertTrue(changes)
        self.assertEqual(self.lock, original)

    def test_changed_license_rejects_entire_update(self):
        original = copy.deepcopy(self.lock)
        with self.assertRaisesRegex(ValueError, "license changed"):
            self.refresh(["PNPM_VERSION", "CADDY_VERSION"], "99.0.0")
        self.assertEqual(self.lock, original)

    def test_two_architecture_binary_hashes_are_independent(self):
        self.lock["build_args"]["RUFF_LICENSE_SHA256"] = hashlib.sha256(b"license").hexdigest()
        def fetch(url):
            return b"license" if url.endswith("/LICENSE") else url.encode()
        lock, _, _ = self.refresh(["RUFF_VERSION"], "99.0.0", fetch)
        for arch, triple in [("AMD64", "x86_64"), ("ARM64", "aarch64")]:
            url = f"https://github.com/astral-sh/ruff/releases/download/99.0.0/ruff-{triple}-unknown-linux-gnu.tar.gz"
            self.assertEqual(lock["build_args"]["RUFF_SHA256_" + arch], hashlib.sha256(url.encode()).hexdigest())

    def test_same_version_base_image_rebuild_is_detected(self):
        def image(name, tag):
            return f"{name}:{tag}@sha256:" + "a" * 64
        lock, _, changes = self.refresh([], "1.0.0", image=image)
        self.assertEqual(len(changes), 4)
        self.assertNotEqual(lock, self.lock)

    def test_source_archive_is_inspected_without_extraction(self):
        client = Mock()
        client.get_json.return_value = {"sha": "a" * 40}
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w:gz") as archive:
            for name in ["root/package.json", "root/apps/cli/package.json"]:
                data = b'{"version":"0.3.0"}'
                entry = tarfile.TarInfo(name); entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        result = updater.source_metadata("0.3.0", client, lambda url: raw.getvalue())
        self.assertEqual(result["version"], "0.3.0")
        self.assertEqual(result["archiveSha256"], hashlib.sha256(raw.getvalue()).hexdigest())
        with self.assertRaisesRegex(ValueError, "version does not match"):
            updater.source_metadata("0.3.1", client, lambda url: raw.getvalue())

    def test_artifact_redirects_allow_official_cdn_only(self):
        handler = updater.ArtifactRedirect()
        request = urllib.request.Request("https://github.com/astral-sh/uv/releases/download/x/asset")
        good = handler.redirect_request(request, None, 302, "", {}, "https://release-assets.githubusercontent.com/asset")
        self.assertEqual(good.host, "release-assets.githubusercontent.com")
        for target in ["https://attacker.test/asset", "http://github.com/asset", "https://user@github.com/asset"]:
            with self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "", {}, target)


if __name__ == "__main__":
    unittest.main()
