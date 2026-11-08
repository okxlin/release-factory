#!/usr/bin/env python3
"""Replay installer download failures through the workstation Dockerfile RUNs."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILDERS = ("codex-claude-workstation-builder", "opencode-workstation-builder")
INSTALLER = r'''#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$BUN_TEST_CALLS"
attempt=$(wc -l < "$BUN_TEST_CALLS")
if (( attempt <= BUN_TEST_FAILURES )); then
    if [[ "$BUN_TEST_STATUS" == 18 ]]; then
        echo 'curl: (18) Transferred a partial file' >&2
    else
        echo 'curl: (22) The requested URL returned error: 504' >&2
    fi
    echo 'error: Failed to download bun from the official release asset' >&2
    exit "$BUN_TEST_STATUS"
fi
touch "$BUN_TEST_SUCCESS"
'''


def install_command(builder):
    blocks = []
    current = ""
    for line in (ROOT / builder / "image/Dockerfile").read_text().splitlines():
        current += line[:-1] + " " if line.endswith("\\") else line
        if not line.endswith("\\"):
            blocks.append(current)
            current = ""
    matches = [line[4:] for line in blocks
               if line.startswith("RUN ") and "https://bun.sh/install" in line]
    if len(matches) != 1:
        raise AssertionError(f"expected one Bun installation RUN in {builder}")
    return matches[0]


class BunInstallTests(unittest.TestCase):
    def run_install(self, builder, failures=0, status=22, version="1.4.0"):
        with tempfile.TemporaryDirectory(prefix="bun-install-test-") as temporary:
            root = Path(temporary)
            tools = root / "bin"
            tools.mkdir()
            installer = root / "installer.sh"
            installer.write_text(INSTALLER)
            curl = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = sys.argv[1:]
if "https://bun.sh/install" not in args:
    raise SystemExit("unexpected network request")
content = Path(os.environ["BUN_TEST_INSTALLER"]).read_bytes()
output = next((args[i + 1] for i, arg in enumerate(args[:-1])
               if arg in ("-o", "--output")), None)
if output:
    Path(output).write_bytes(content)
else:
    sys.stdout.buffer.write(content)
'''
            mocks = {"curl": curl, "sleep": "#!/bin/sh\nexit 0\n",
                     "chown": "#!/bin/sh\nexit 0\n", "mv": "#!/bin/sh\nexit 0\n",
                     "bun": '#!/bin/sh\ntest -f "$BUN_TEST_SUCCESS" || exit 1\necho 1.4.0\n'}
            for name, content in mocks.items():
                path = tools / name
                path.write_text(content)
                path.chmod(0o755)
            calls = root / "calls.txt"
            env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                   "BUN_VERSION": version, "USER_UID": "1000", "USER_GID": "1000",
                   "BUN_TEST_INSTALLER": str(installer), "BUN_TEST_CALLS": str(calls),
                   "BUN_TEST_SUCCESS": str(root / "installed"),
                   "BUN_TEST_FAILURES": str(failures), "BUN_TEST_STATUS": str(status)}
            command = install_command(builder).replace(
                "/tmp/release-factory-bun-install.sh", shlex.quote(str(root / "download.sh")))
            result = subprocess.run(["bash", "-o", "pipefail", "-c", command],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=10)
            attempts = calls.read_text().splitlines() if calls.exists() else []
            return result, attempts

    def test_success_keeps_the_requested_version(self):
        for builder in BUILDERS:
            with self.subTest(builder=builder):
                result, attempts = self.run_install(builder)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(attempts, ["bun-v1.4.0"])
        result, attempts = self.run_install(BUILDERS[0], version="latest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(attempts, [""])

    def test_transient_asset_failures_are_retried(self):
        for builder in BUILDERS:
            for status in (22, 18):
                with self.subTest(builder=builder, status=status):
                    result, attempts = self.run_install(builder, failures=2, status=status)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(attempts, ["bun-v1.4.0"] * 3)

    def test_exhausted_downloads_still_fail_the_build(self):
        for builder in BUILDERS:
            with self.subTest(builder=builder):
                result, attempts = self.run_install(builder, failures=100)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(attempts, ["bun-v1.4.0"] * 3)
                self.assertIn("Failed to download bun", result.stderr)


if __name__ == "__main__":
    unittest.main()
