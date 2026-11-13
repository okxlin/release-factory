#!/usr/bin/env python3
"""Replay scanner findings through the Caddy image/receipt validation gate."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / "image/components.lock.json").read_text())["build_args"]


class CaddyVulnerabilityTests(unittest.TestCase):
    def run_gate(self, saml_version="v0.5.2", findings=("GO-2026-6909", "GO-2026-5932"),
                 receipt_valid=True, openpgp=False, symbols=False, scan_status=None):
        with tempfile.TemporaryDirectory(prefix="caddy-gate-test-") as temporary:
            root = Path(temporary)
            fixtures = root / "fixtures"
            tools = root / "bin"
            fixtures.mkdir()
            tools.mkdir()
            (fixtures / "caddy").write_bytes(b"controlled scanner-boundary fixture")
            packages = ["golang.org/x/crypto/ssh", "github.com/crewjam/saml"]
            if openpgp:
                packages.append("golang.org/x/crypto/openpgp")
            (fixtures / "CADDY_GO_PACKAGES.txt").write_text("\n".join(packages) + "\n")
            patch = ROOT / "image/patches/go-jose-v3-rsa-bounds.patch"
            (fixtures / "GO_JOSE_V3_PATCH.txt").write_text(
                f"{PINS['GO_JOSE_V3_SOURCE_SHA256']}  go-jose-v{PINS['GO_JOSE_V3_VERSION']}-source.tar.gz\n"
                f"{hashlib.sha256(patch.read_bytes()).hexdigest()}  go-jose-v3-rsa-bounds.patch\n")
            assertion_test = ROOT / "image/tests/saml-assertions_test.go"
            test_hash = hashlib.sha256(assertion_test.read_bytes()).hexdigest() if receipt_valid else "0" * 64
            (fixtures / "SAML_SECURITY_CHECK.txt").write_text(
                f"github.com/crewjam/saml {saml_version}\n{test_hash}  saml-assertions_test.go\n")
            (fixtures / "modules.txt").write_text(
                f"dep github.com/go-jose/go-jose/v3 v{PINS['GO_JOSE_V3_VERSION']} h1:fixture\n"
                f"=> /usr/src/go-jose-{PINS['GO_JOSE_V3_VERSION']} (devel)\n"
                f"dep github.com/go-jose/go-jose/v4 v{PINS['GO_JOSE_VERSION']} h1:fixture\n"
                f"dep github.com/crewjam/saml v0.5.1 h1:original\n"
                f"=> github.com/crewjam/saml {saml_version} h1:replacement\n")
            (fixtures / "scan.txt").write_text("\n".join(
                f"Vulnerability #{index}: {finding}\n    More info: https://pkg.go.dev/vuln/{finding}"
                for index, finding in enumerate(findings, 1)) + "\n")
            docker = '''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
args = sys.argv[1:]
if args[0] == "create":
    print("controlled-caddy-container")
elif args[0] == "cp":
    name = args[1].rsplit("/", 1)[-1]
    shutil.copyfile(Path(os.environ["CADDY_TEST_FIXTURES"]) / name, args[2])
elif args[0] not in ("image", "rm"):
    raise SystemExit("unexpected docker operation")
'''
            go = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
if sys.argv[1:3] == ["version", "-m"]:
    print((Path(os.environ["CADDY_TEST_FIXTURES"]) / "modules.txt").read_text())
elif sys.argv[1:3] == ["tool", "nm"]:
    raise SystemExit(0 if os.environ["CADDY_TEST_SYMBOLS"] == "true" else 1)
else:
    raise SystemExit("unexpected go operation")
'''
            scanner = '''#!/usr/bin/env python3
import os
from pathlib import Path
print((Path(os.environ["CADDY_TEST_FIXTURES"]) / "scan.txt").read_text())
raise SystemExit(int(os.environ["CADDY_TEST_SCAN_STATUS"]))
'''
            for name, content in {"docker": docker, "go": go, "govulncheck": scanner}.items():
                path = tools / name
                path.write_text(content)
                path.chmod(0o755)
            env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                   "CADDY_TEST_FIXTURES": str(fixtures), "CADDY_TEST_SYMBOLS": str(symbols).lower(),
                   "CADDY_TEST_SCAN_STATUS": str(scan_status if scan_status is not None else (3 if findings else 0))}
            return subprocess.run(["bash", str(ROOT / "scripts/check-caddy-vulnerabilities.sh"),
                                   "--image", "controlled:caddy"], env=env,
                                  capture_output=True, text=True, timeout=10)

    def test_reviewed_saml_fix_and_stripped_openpgp_fallback_are_accepted(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GO-2026-6909", result.stdout)
        self.assertIn("v0.5.2", result.stdout)

    def test_unreviewed_versions_and_changed_receipts_fail(self):
        for options in ({"saml_version": "v0.5.1"}, {"saml_version": "v0.6.3"},
                        {"receipt_valid": False}):
            with self.subTest(options=options):
                result = self.run_gate(**options)
                self.assertNotEqual(result.returncode, 0)

    def test_unknown_findings_linked_openpgp_and_scanner_errors_still_fail(self):
        for options in ({"findings": ("GO-2026-9999",)}, {"openpgp": True},
                        {"symbols": True}, {"scan_status": 1}):
            with self.subTest(options=options):
                result = self.run_gate(**options)
                self.assertNotEqual(result.returncode, 0)

    def test_clean_scan_is_accepted(self):
        result = self.run_gate(findings=())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
