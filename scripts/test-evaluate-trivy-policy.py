#!/usr/bin/env python3
"""Exercise policy decisions using Trivy-shaped reports, without network access."""

import copy
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EVALUATOR = ROOT / "scripts/evaluate-trivy-policy.py"
POLICY = ROOT / "deepseek-harness-builder/configs/trivy-policy.json"


def report(severity="HIGH", fixed="2.0.0", path="usr/local/bin/tool", **fields):
    vulnerability = {
        "VulnerabilityID": "CVE-2026-12345",
        "PkgName": "example.org/tool",
        "InstalledVersion": "1.0.0",
        "Severity": severity,
        "FixedVersion": fixed,
        **fields,
    }
    return {"SchemaVersion": 2, "Results": [{
        "Target": path, "Class": "lang-pkgs", "Type": "gobinary",
        "Vulnerabilities": [vulnerability],
    }]}


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads(POLICY.read_text())
        self.exception = {
            "id": "CVE-2026-12345", "package": "example.org/tool",
            "installed_version": "1.0.0", "path": "usr/local/bin/tool",
            "type": "gobinary", "profiles": ["runtime", "workstation"],
            "reason": "Fixture: affected package is absent from the linked graph.",
            "reference": "https://example.org/advisory",
            "expires": (datetime.date.today() + datetime.timedelta(days=30)).isoformat(),
        }

    def evaluate(self, data, profile="workstation"):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "report.json").write_text(json.dumps(data))
            (base / "policy.json").write_text(json.dumps(self.policy))
            return subprocess.run(
                [sys.executable, str(EVALUATOR), "--report", str(base / "report.json"),
                 "--policy", str(base / "policy.json"), "--profile", profile],
                capture_output=True, text=True, check=False,
            )

    def test_workstation_warns_on_tool_high(self):
        result = self.evaluate(report())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN", result.stdout)

    def test_runtime_blocks_fixable_high(self):
        self.assertEqual(self.evaluate(report(), "runtime").returncode, 1)

    def test_fixable_critical_blocks_both_profiles(self):
        for profile in ("runtime", "workstation"):
            with self.subTest(profile=profile):
                self.assertEqual(self.evaluate(report("CRITICAL"), profile).returncode, 1)

    def test_core_findings_block_even_without_a_fix(self):
        for path in ("usr/bin/caddy", "/opt/dsh/node_modules/a/package.json"):
            for fixed in ("", "2.0.0"):
                with self.subTest(path=path, fixed=fixed):
                    self.assertEqual(self.evaluate(report(path=path, fixed=fixed)).returncode, 1)

    def test_node_findings_use_package_path(self):
        data = report(path="Node.js", fixed="", PkgPath="opt/dsh/node_modules/a/package.json")
        data["Results"][0]["Type"] = "node-pkg"
        self.assertEqual(self.evaluate(data).returncode, 1)

    def test_protected_os_services_do_not_match_development_tools(self):
        self.policy["protected_os_packages"] = ["nginx", "google-chrome-stable"]
        data = report(fixed="", PkgName="nginx")
        self.assertEqual(self.evaluate(data).returncode, 0)
        data["Results"][0].update(Class="os-pkgs", Type="debian", Target="Debian 13")
        self.assertEqual(self.evaluate(data).returncode, 1)
        data["Results"][0]["Vulnerabilities"][0]["PkgName"] = "other-tool"
        self.assertEqual(self.evaluate(data).returncode, 0)

    def test_protected_os_packages_require_exact_names(self):
        for package in ("", "nginx*", " ../nginx"):
            self.policy["protected_os_packages"] = [package]
            self.assertEqual(self.evaluate(report()).returncode, 2)

    def test_exact_exception_is_visible(self):
        self.policy["exceptions"] = [self.exception]
        result = self.evaluate(report("CRITICAL"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("EXCEPTED", result.stdout)
        self.assertIn(self.exception["reason"], result.stdout)

    def test_exception_cannot_match_another_finding(self):
        self.policy["exceptions"] = [self.exception]
        for key, value in (("id", "CVE-2026-99999"), ("package", "other"),
                           ("installed_version", "1.0.1"), ("path", "usr/bin/caddy"),
                           ("type", "node-pkg"), ("profiles", ["runtime"])):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.exception)
                changed[key] = value
                self.policy["exceptions"] = [changed]
                self.assertEqual(self.evaluate(report("CRITICAL")).returncode, 1)

    def test_expired_exception_does_not_suppress(self):
        self.exception["expires"] = "2000-01-01"
        self.policy["exceptions"] = [self.exception]
        self.assertEqual(self.evaluate(report("CRITICAL")).returncode, 1)

    def test_unfixed_tool_finding_is_reported(self):
        result = self.evaluate(report("CRITICAL", fixed=""))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN", result.stdout)

    def test_malformed_report_and_unknown_profile_fail_closed(self):
        for data in ({}, {"SchemaVersion": 2, "Results": {}}, report(Severity=None)):
            with self.subTest(data=data):
                self.assertEqual(self.evaluate(data).returncode, 2)
        self.assertEqual(self.evaluate(report(), "typo").returncode, 2)

    def test_malformed_or_broad_exception_fails_closed(self):
        for key, value in (("path", "*"), ("reason", ""), ("expires", "forever")):
            with self.subTest(key=key):
                self.policy["exceptions"] = [{**self.exception, key: value}]
                self.assertEqual(self.evaluate(report()).returncode, 2)

    def test_unclassified_node_finding_fails_closed(self):
        data = report(path="Node.js")
        data["Results"][0]["Type"] = "node-pkg"
        self.assertEqual(self.evaluate(data).returncode, 2)

    def run_gate(self, data, arguments=(), scanner_status=0, filesystem=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "input.json").write_text(json.dumps(data))
            scanner = base / "trivy"
            scanner.write_text(
                f"#!{sys.executable}\n"
                "import json, os, pathlib, sys\n"
                "root = pathlib.Path(__file__).parent\n"
                "(root / 'argv.json').write_text(json.dumps(sys.argv[1:]))\n"
                "pathlib.Path(sys.argv[sys.argv.index('--output') + 1]).write_bytes((root / 'input.json').read_bytes())\n"
                f"sys.exit({scanner_status})\n"
            )
            scanner.chmod(0o700)
            target = base / "userland"
            target.mkdir()
            selector = ["--filesystem", str(target)] if filesystem else ["--image", "fixture:test"]
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/trivy-image-gate.sh"), *selector,
                 "--output", str(base / "scan.json"), *arguments],
                env={**os.environ, "PATH": f"{base}:{os.environ['PATH']}", "TRIVY_SEVERITY": "LOW"},
                capture_output=True, text=True, check=False,
            )
            return result, json.loads((base / "argv.json").read_text())

    def test_policy_scans_all_high_critical_without_implicit_ignores(self):
        result, argv = self.run_gate(report(), ["--policy", str(POLICY), "--profile", "workstation"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(argv[argv.index("--severity") + 1], "HIGH,CRITICAL")
        self.assertEqual(argv[argv.index("--ignorefile") + 1], "/dev/null")
        self.assertIn("--ignore-unfixed=false", argv)

    def test_legacy_thresholds_are_preserved(self):
        for severity, status in (("HIGH", 0), ("CRITICAL", 1)):
            with self.subTest(severity=severity):
                result, _ = self.run_gate(report(severity))
                self.assertEqual(result.returncode, status, result.stderr)
        result, _ = self.run_gate(report(), ["--max-fixable-high", "0"])
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_scanner_failure_cannot_pass_the_gate(self):
        result, _ = self.run_gate(report(), ["--policy", str(POLICY), "--profile", "workstation"], 7)
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_userland_scan_uses_the_same_policy(self):
        for path, expected in (("usr/local/bin/tool", 0), ("opt/dsh/node_modules/a/package.json", 1)):
            with self.subTest(path=path):
                result, argv = self.run_gate(report(path=path), ["--policy", str(POLICY), "--profile", "workstation"], filesystem=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(argv[0], "fs")
                self.assertTrue(argv[-1].endswith("/userland"))
                self.assertIn("--ignore-unfixed=false", argv)


if __name__ == "__main__":
    unittest.main()
