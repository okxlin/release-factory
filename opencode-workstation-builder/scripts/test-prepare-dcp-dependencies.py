#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

SPEC = importlib.util.spec_from_file_location("dcp", Path(__file__).resolve().parents[1]
                                           / "image/scripts/prepare-dcp-dependencies.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PACKAGE = "@tarquinen/opencode-dcp@3.1.15"


class DcpTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dcp-dependencies-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.baseline = self.root / "baseline"
        self.baseline.mkdir()
        (self.baseline / "package.json").write_text(json.dumps({"config": {
            "dcpPackage": PACKAGE, "dcpSerovalVersion": "1.6.9"}}))
        self.cache = self.root / "cache"
        self.directory = self.cache / "opencode/packages" / PACKAGE
        self.run = Mock()

    def prepare(self, package=PACKAGE):
        MODULE.prepare(package, self.baseline, self.cache, self.run)

    def seed(self, serializer, override=None):
        (self.directory / "node_modules/@tarquinen/opencode-dcp").mkdir(parents=True)
        data = {"dependencies": {"@tarquinen/opencode-dcp": "3.1.15"},
                "overrides": {"unrelated": "2.0.0"}, "description": "keep this"}
        if override:
            data["overrides"]["seroval"] = override
        (self.directory / "package.json").write_text(json.dumps(data))
        (self.directory / "package-lock.json").write_text(json.dumps({"packages": {
            "node_modules/seroval": {"version": serializer}}}))

    def test_fresh_cache_seeds_override_for_opencode_install(self):
        self.prepare()
        data = json.loads((self.directory / "package.json").read_text())
        self.assertEqual(data["overrides"], {"seroval": "1.6.9"})
        self.run.assert_not_called()

    def test_existing_vulnerable_cache_is_refreshed_without_lifecycle_scripts(self):
        self.seed("1.5.6")
        self.prepare()
        data = json.loads((self.directory / "package.json").read_text())
        self.assertEqual(data["overrides"], {"unrelated": "2.0.0", "seroval": "1.6.9"})
        self.assertEqual(data["description"], "keep this")
        self.assertEqual(data["dependencies"], {"@tarquinen/opencode-dcp": "3.1.15"})
        self.run.assert_called_once_with(["npm", "install", "--prefix", str(self.directory),
                                         "--ignore-scripts", "--no-audit", "--no-fund"], check=True)

    def test_fixed_cache_avoids_repeated_network_install(self):
        self.seed("1.6.9", "1.6.9")
        self.prepare()
        self.run.assert_not_called()

    def test_stale_lock_is_retried_after_an_interrupted_refresh(self):
        self.seed("1.5.6", "1.6.9")
        self.prepare()
        self.run.assert_called_once()

    def test_custom_plugin_is_untouched(self):
        self.prepare("@tarquinen/opencode-dcp@3.2.0")
        self.assertFalse(self.cache.exists())
        self.run.assert_not_called()

    def test_cache_symlink_cannot_retarget_writes(self):
        self.cache.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (self.cache / "opencode").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.prepare()
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
