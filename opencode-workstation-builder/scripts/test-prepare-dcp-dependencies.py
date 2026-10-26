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
            "dcpPackage": PACKAGE, "dcpSerovalVersion": "1.6.9",
            "dcpTomlVersion": "5.0.1", "dcpZodVersion": "4.6.6"}}))
        self.cache = self.root / "cache"
        self.directory = self.cache / "opencode/packages" / PACKAGE
        self.config = self.root / "config/opencode"
        self.run = Mock()

    def prepare(self, package=PACKAGE):
        MODULE.prepare(package, self.baseline, self.cache, self.run, config_dirs=[self.config])

    def seed(self, serializer, override=None, toml="5.0.1", zod="4.6.6"):
        (self.directory / "node_modules/@tarquinen/opencode-dcp").mkdir(parents=True, exist_ok=True)
        data = {"dependencies": {"@tarquinen/opencode-dcp": "3.1.15"},
                "overrides": {"unrelated": "2.0.0"}, "description": "keep this"}
        if override:
            data["overrides"]["seroval"] = override
        if toml:
            data["overrides"]["toml"] = toml
        if zod:
            data["overrides"]["zod"] = zod
        (self.directory / "package.json").write_text(json.dumps(data))
        (self.directory / "package-lock.json").write_text(json.dumps({"packages": {
            "node_modules/seroval": {"version": serializer},
            "node_modules/toml": {"version": toml},
            "node_modules/zod": {"version": zod}}}))

    def seed_config(self, zod="4.6.6", toml="5.0.1", nested=False):
        plugin = "node_modules/@opencode-ai/plugin"
        (self.config / plugin).mkdir(parents=True)
        (self.config / "package.json").write_text(json.dumps({
            "dependencies": {"@opencode-ai/plugin": "1.18.30"},
            "overrides": {"unrelated": "2.0.0", "@opencode-ai/plugin": {
                "unrelated": "3.0.0", "zod": "4.6.6", "effect": {"toml": "5.0.1"}}}}))
        dependency_root = plugin + "/node_modules/" if nested else "node_modules/"
        effect = dependency_root + "effect"
        toml_path = effect + "/node_modules/toml" if nested else "node_modules/toml"
        packages = {plugin: {"version": "1.18.30"}, effect: {"version": "4.0.0-beta.83"},
                    dependency_root + "zod": {"version": zod}, toml_path: {"version": toml}}
        if nested:
            packages["node_modules/zod"] = {"version": "3.25.76"}
        (self.config / "package-lock.json").write_text(json.dumps({"packages": packages}))

    def test_fresh_cache_seeds_override_for_opencode_install(self):
        self.prepare()
        data = json.loads((self.directory / "package.json").read_text())
        self.assertEqual(data["overrides"], {"seroval": "1.6.9", "toml": "5.0.1", "zod": "4.6.6"})
        config = json.loads((self.config / "package.json").read_text())
        self.assertEqual(config["overrides"], {"@opencode-ai/plugin": {
            "zod": "4.6.6", "effect": {"toml": "5.0.1"}}})
        self.run.assert_not_called()

    def test_existing_vulnerable_cache_is_refreshed_without_lifecycle_scripts(self):
        self.seed("1.5.6")
        self.prepare()
        data = json.loads((self.directory / "package.json").read_text())
        self.assertEqual(data["overrides"], {"unrelated": "2.0.0", "seroval": "1.6.9", "toml": "5.0.1", "zod": "4.6.6"})
        self.assertEqual(data["description"], "keep this")
        self.assertEqual(data["dependencies"], {"@tarquinen/opencode-dcp": "3.1.15"})
        self.run.assert_called_once_with(["npm", "install", "--prefix", str(self.directory),
                                         "--ignore-scripts", "--no-audit", "--no-fund"], check=True)

    def test_fixed_cache_avoids_repeated_network_install(self):
        self.seed("1.6.9", "1.6.9")
        self.seed_config()
        self.prepare()
        self.run.assert_not_called()

    def test_stale_lock_is_retried_after_an_interrupted_refresh(self):
        self.seed("1.5.6", "1.6.9")
        self.prepare()
        self.run.assert_called_once()

    def test_stale_toml_or_zod_in_cache_is_refreshed_with_current_overrides(self):
        for name, version in (("toml", "4.3.0"), ("zod", "4.1.8")):
            with self.subTest(package=name):
                self.seed("1.6.9", "1.6.9")
                lock = json.loads((self.directory / "package-lock.json").read_text())
                lock["packages"]["node_modules/" + name]["version"] = version
                (self.directory / "package-lock.json").write_text(json.dumps(lock))
                self.run.reset_mock()
                self.prepare()
                self.run.assert_called_once()

    def test_stale_config_dependencies_are_refreshed_without_changing_other_overrides(self):
        self.seed_config(zod="4.1.8", toml="4.3.0")
        self.prepare()
        self.run.assert_called_once_with(["npm", "install", "--prefix", str(self.config),
                                         "--ignore-scripts", "--no-audit", "--no-fund"], check=True)
        data = json.loads((self.config / "package.json").read_text())
        self.assertEqual(data["dependencies"], {"@opencode-ai/plugin": "1.18.30"})
        self.assertEqual(data["overrides"]["unrelated"], "2.0.0")
        self.assertEqual(data["overrides"]["@opencode-ai/plugin"]["unrelated"], "3.0.0")

    def test_nested_fixed_config_dependencies_preserve_unrelated_zod_major(self):
        self.seed_config(nested=True)
        self.prepare()
        self.run.assert_not_called()

    def test_custom_plugin_is_untouched(self):
        self.prepare("@tarquinen/opencode-dcp@3.2.0")
        self.assertFalse(self.cache.exists())
        self.assertFalse(self.config.exists())
        self.run.assert_not_called()

    def test_cache_symlink_cannot_retarget_writes(self):
        self.cache.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (self.cache / "opencode").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.prepare()
        self.assertEqual(list(outside.iterdir()), [])

    def test_config_symlink_cannot_retarget_writes(self):
        self.config.parent.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        self.config.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.prepare()
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
