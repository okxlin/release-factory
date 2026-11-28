#!/usr/bin/env python3
"""Replay the source builder's package rejection commands with real inventories."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = (
    ROOT / "codex-claude-workstation-builder/image/build-workstation-go-tools.sh",
    ROOT / "opencode-workstation-builder/image/build-workstation-go-tools.sh",
    ROOT / "gemini-skill-browser-builder/image/runtime/build-workstation-go-tools.sh",
)
GUARDS = (
    (r"'^golang\.org/x/crypto/openpgp(/|$)'", "GITHUB_CLI_GO_PACKAGES.txt",
     "golang.org/x/crypto/openpgp\n"),
    ("'^github.com/docker/docker(/|$)'", "DOCKER_CLI_GO_PACKAGES.txt",
     "github.com/docker/docker/daemon\n"),
    ("pkg/authorization|daemon", '"$inventory"',
     "github.com/moby/moby/v3/daemon\n"),
    (r"'^golang\.org/x/crypto/openpgp(/|$)'", '"$inventory"',
     "golang.org/x/crypto/openpgp/packet\n"),
)


def run_guard(script, pattern, target, contents):
    lines = script.read_text(encoding="utf-8").splitlines()
    setup = next(line for line in lines if line.startswith("set -"))
    matches = [line.strip() for line in lines
               if "grep -" in line and pattern in line and target in line]
    if len(matches) != 1:
        raise AssertionError(f"expected one package rejection command in {script}: {pattern}")
    with tempfile.TemporaryDirectory(prefix="workstation-package-guard-") as temporary:
        root = Path(temporary)
        licenses = root / "licenses"
        licenses.mkdir()
        filename = "PACKAGE_LIST.txt" if target == '"$inventory"' else target
        inventory = licenses / filename
        if contents is not None:
            inventory.write_text(contents, encoding="utf-8")
        env = {**os.environ, "tools_out": str(root), "inventory": str(inventory)}
        command = setup + "\n" + matches[0] + '\nprintf "GUARD_CONTINUED\\n"\n'
        return subprocess.run(["bash", "-c", command], env=env, capture_output=True,
                              text=True, timeout=10)


class PackageRejectionTests(unittest.TestCase):
    def test_allowed_packages_continue(self):
        for script in SCRIPTS:
            for pattern, target, _ in GUARDS:
                with self.subTest(script=script, pattern=pattern, target=target):
                    result = run_guard(script, pattern, target, "example.org/allowed/package\n")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("GUARD_CONTINUED", result.stdout)

    def test_forbidden_packages_stop_the_build(self):
        for script in SCRIPTS:
            for pattern, target, forbidden in GUARDS:
                with self.subTest(script=script, pattern=pattern, target=target):
                    result = run_guard(script, pattern, target, forbidden)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertNotIn("GUARD_CONTINUED", result.stdout)

    def test_missing_inventory_stops_the_build(self):
        for script in SCRIPTS:
            for pattern, target, _ in GUARDS:
                with self.subTest(script=script, pattern=pattern, target=target):
                    result = run_guard(script, pattern, target, None)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertNotIn("GUARD_CONTINUED", result.stdout)


if __name__ == "__main__":
    unittest.main()
