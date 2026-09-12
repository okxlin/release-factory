#!/usr/bin/env python3
"""Exercise offline baseline startup, persisted installs, and explicit upgrades."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "image/scripts/bootstrap-opencode-userland.sh"


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="opencode-bootstrap-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.baseline = self.root / "baseline"
        self.baseline.mkdir()
        (self.baseline / "package.json").write_text(json.dumps({"version": "1.18.30"}))
        self.binary(self.baseline / "bin/opencode", "baseline-1.18.30")
        self.npm_log = self.root / "npm.log"
        self.stub = self.root / "tools"
        self.stub.mkdir()
        npm = self.stub / "npm"
        npm.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$NPM_TEST_LOG"\n[ "$1" = pkg ] && exit 0\nexit 73\n')
        npm.chmod(0o755)
        self.bindir = self.root / "home/.local/bin"
        self.install = self.root / "home/.local/share/opencode"
        self.env = {
            **os.environ, "HOME": str(self.root / "home"),
            "PATH": f"{self.bindir}:{self.stub}:/usr/bin:/bin",
            "OPENCODE_BASELINE_DIR": str(self.baseline),
            "OPENCODE_INSTALL_DIR": str(self.install),
            "OPENCODE_NPM_BIN_DIR": str(self.bindir),
            "OPENCODE_FORCE_INSTALL": "0", "NPM_TEST_LOG": str(self.npm_log),
        }
        self.env.pop("OPENCODE_NPM_PACKAGE", None)

    def binary(self, path, version):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\n")
        path.chmod(0o755)

    def run_bootstrap(self, **env):
        return subprocess.run(["bash", str(SCRIPT)], env={**self.env, **env},
                              capture_output=True, text=True)

    def test_fresh_home_uses_baseline_without_network(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("baseline-1.18.30", result.stdout)
        self.assertEqual((self.bindir / "opencode").resolve(), self.baseline / "bin/opencode")
        self.assertFalse(self.npm_log.exists())

    def test_restores_persisted_install_when_bin_directory_is_new(self):
        saved = self.install / "node_modules/.bin/opencode"
        self.binary(saved, "user-saved-version")
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("user-saved-version", result.stdout)
        self.assertEqual((self.bindir / "opencode").resolve(), saved)
        self.assertFalse(self.npm_log.exists())

    def test_existing_user_command_wins(self):
        self.binary(self.bindir / "opencode", "custom-global-version")
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("custom-global-version", result.stdout)
        self.assertFalse(self.npm_log.exists())

    def test_explicit_version_requests_install(self):
        result = self.run_bootstrap(OPENCODE_NPM_PACKAGE="opencode-ai@1.18.31")
        self.assertEqual(result.returncode, 73)
        self.assertIn("opencode-ai@1.18.31", self.npm_log.read_text().splitlines())

    def test_force_requests_install_even_with_baseline_link(self):
        self.bindir.mkdir(parents=True)
        (self.bindir / "opencode").symlink_to(self.baseline / "bin/opencode")
        result = self.run_bootstrap(OPENCODE_FORCE_INSTALL="1")
        self.assertEqual(result.returncode, 73)
        self.assertIn("opencode-ai@1.18.30", self.npm_log.read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
