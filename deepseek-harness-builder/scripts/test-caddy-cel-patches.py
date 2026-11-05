#!/usr/bin/env python3
"""Exercise the reviewed relocation patch against Caddy's import layouts."""

from pathlib import Path
import subprocess
import tempfile
import unittest


PATCH = Path(__file__).resolve().parents[1] / "image/patches/caddy-cel-go-module-relocation.patch"
MATCHERS = "modules/caddyhttp/matchers.go"
# https://github.com/caddyserver/caddy/blob/v2.11.7/modules/caddyhttp/matchers.go
CONTIGUOUS = '''package caddyhttp

import (
	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"golang.org/x/net/idna"
)
'''
# https://github.com/caddyserver/caddy/blob/v2.11.9/modules/caddyhttp/matchers.go
EXPANDED = '''package caddyhttp

import (
	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common"
	"cel.dev/cel-go/common/ast"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"
	"cel.dev/cel-go/parser"
	"golang.org/x/net/idna"
)
'''


class CaddyCelPatchTests(unittest.TestCase):
    def run_patch(self, root, *options):
        return subprocess.run(
            ["git", "apply", "--unidiff-zero", f"--include={MATCHERS}", *options, str(PATCH)],
            cwd=root, capture_output=True, text=True, check=False,
        )

    def test_reviewed_import_layouts_roundtrip(self):
        for original in [CONTIGUOUS, EXPANDED]:
            with self.subTest(imports=original), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / MATCHERS
                source.parent.mkdir(parents=True)
                source.write_text(original, encoding="utf-8")
                result = self.run_patch(root, "--reverse", "--check")
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.run_patch(root, "--reverse")
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.run_patch(root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(source.read_text(encoding="utf-8"), original)

    def test_unreviewed_import_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / MATCHERS
            source.parent.mkdir(parents=True)
            source.write_text(EXPANDED.replace('"cel.dev/cel-go/common/types/ref"',
                                               '"example.invalid/cel/types/ref"'), encoding="utf-8")
            result = self.run_patch(root, "--reverse", "--check")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("patch does not apply", result.stderr)


if __name__ == "__main__":
    unittest.main()
