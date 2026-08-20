#!/usr/bin/env python3
"""Offline regression tests for check-component-updates.py."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
CHECKER = SCRIPT_DIR / "check-component-updates.py"
DIGEST = "a" * 64

SPEC = importlib.util.spec_from_file_location("component_update_checker", CHECKER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {CHECKER}")
CHECKER_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER_MODULE)


class ComponentUpdateCheckerTests(unittest.TestCase):
    def run_checker(
        self,
        root: Path,
        policy: dict[str, object],
        dockerfile: str,
        fixtures: dict[str, str],
        *extra_args: str,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        policy_path = root / "policy.json"
        dockerfile_path = root / "Dockerfile"
        fixture_dir = root / "fixtures"
        summary_path = root / "summary.md"
        fixture_dir.mkdir()
        policy_path.write_text(json.dumps(policy), encoding="utf-8")
        dockerfile_path.write_text(dockerfile, encoding="utf-8")
        for name, contents in fixtures.items():
            (fixture_dir / name).write_text(contents, encoding="utf-8")

        command = [
            sys.executable,
            str(CHECKER),
            "--dockerfile",
            str(dockerfile_path),
            "--policy",
            str(policy_path),
            "--fixture-dir",
            str(fixture_dir),
            "--summary",
            str(summary_path),
            *extra_args,
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        return result, summary_path

    @staticmethod
    def npm_policy() -> dict[str, object]:
        return {
            "version": 1,
            "components": [
                {
                    "name": "pnpm",
                    "pin": "PNPM_VERSION",
                    "source": {"type": "npm", "package": "pnpm"},
                }
            ],
        }

    def test_update_is_reported_and_strict_mode_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result, summary_path = self.run_checker(
                Path(temporary),
                self.npm_policy(),
                "ARG PNPM_VERSION=1.2.3\n",
                {"npm-pnpm.json": '{"version":"1.2.4"}\n'},
                "--fail-on-updates",
            )

            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("component_updates=1", result.stdout)
            summary = summary_path.read_text(encoding="utf-8")
            self.assertIn("| pnpm | `1.2.3` |", summary)
            self.assertIn("update available", summary)

    def test_equal_version_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result, summary_path = self.run_checker(
                Path(temporary),
                self.npm_policy(),
                "ARG PNPM_VERSION=1.2.3\n",
                {"npm-pnpm.json": '{"version":"1.2.3"}\n'},
                "--fail-on-updates",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("component_updates=0", result.stdout)
            self.assertIn("current", summary_path.read_text(encoding="utf-8"))

    def test_missing_fixture_is_a_source_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result, summary_path = self.run_checker(
                Path(temporary),
                self.npm_policy(),
                "ARG PNPM_VERSION=1.2.3\n",
                {},
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("Source errors", summary_path.read_text(encoding="utf-8"))
            self.assertIn("component source checks failed", result.stderr)

    def test_invalid_npm_selector_fails_before_source_access(self) -> None:
        policy = self.npm_policy()
        policy["components"][0]["source"]["selector"] = "../latest"

        with tempfile.TemporaryDirectory() as temporary:
            result, summary_path = self.run_checker(
                Path(temporary),
                policy,
                "ARG PNPM_VERSION=1.2.3\n",
                {},
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("invalid npm selector", summary_path.read_text(encoding="utf-8"))

    def test_redirect_policy_rejects_cross_origin_and_credentials(self) -> None:
        handler = CHECKER_MODULE.SameOriginHTTPSRedirectHandler()
        request = urllib.request.Request(
            "https://api.github.com/repos/example/project/releases/latest",
            headers={"Authorization": "Bearer test-token"},
        )

        for redirected_url in (
            "https://example.com/releases/latest",
            "https://user:password@api.github.com/releases/latest",
            "http://api.github.com/releases/latest",
        ):
            with self.subTest(redirected_url=redirected_url):
                with self.assertRaises(CHECKER_MODULE.UpdateCheckError):
                    handler.redirect_request(
                        request,
                        None,
                        302,
                        "Found",
                        {},
                        redirected_url,
                    )

        redirected = handler.redirect_request(
            request,
            None,
            302,
            "Found",
            {},
            "/repositories/example/project/releases/latest",
        )
        self.assertIsNotNone(redirected)
        self.assertEqual(redirected.host, "api.github.com")

    def test_summary_writer_preserves_existing_job_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            summary_path = Path(temporary) / "summary.md"
            summary_path.write_text("## Existing summary\n\n", encoding="utf-8")

            CHECKER_MODULE.write_summary(summary_path, "## Component updates\n")

            self.assertEqual(
                summary_path.read_text(encoding="utf-8"),
                "## Existing summary\n\n## Component updates\n",
            )

    def test_node_base_image_pin_and_workstation_npm_are_independent(self) -> None:
        policy = {
            "version": 1,
            "components": [
                {
                    "name": "Node.js 24 LTS",
                    "pin_from": {
                        "type": "dockerfile_from",
                        "image": "node",
                        "suffix": "-trixie-slim",
                    },
                    "source": {"type": "node_release_line", "major": 24},
                },
                {
                    "name": "npm 11 for workstation",
                    "pin": "NPM_VERSION",
                    "source": {
                        "type": "npm",
                        "package": "npm",
                        "selector": "next-11",
                    },
                },
            ],
        }
        dockerfile = (
            f"FROM node:24.19.0-trixie-slim@sha256:{DIGEST} AS runtime-base\n"
            "ARG NPM_VERSION=11.19.0\n"
        )
        node_index = json.dumps(
            [
                {"version": "v25.0.0", "lts": False, "npm": "11.18.0"},
                {"version": "v24.19.0", "lts": "Krypton", "npm": "11.17.0"},
                {"version": "v24.18.1", "lts": "Krypton", "npm": "11.16.0"},
            ]
        )

        with tempfile.TemporaryDirectory() as temporary:
            result, summary_path = self.run_checker(
                Path(temporary),
                policy,
                dockerfile,
                {
                    "node-index.json": node_index,
                    "npm-npm-next-11.json": '{"version":"11.19.0"}\n',
                },
                "--fail-on-updates",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = summary_path.read_text(encoding="utf-8")
            self.assertIn("Node.js 24 LTS", summary)
            self.assertIn("`24.19.0`", summary)
            self.assertIn("npm 11 for workstation", summary)
            self.assertIn("`11.19.0`", summary)


if __name__ == "__main__":
    unittest.main(verbosity=2)
