#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("resolve-proxy-core-versions.py")
SPEC = importlib.util.spec_from_file_location("resolve_proxy_core_versions", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT_PATH}")
RESOLVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOLVER)


class FakeClient:
    def __init__(self, json_responses=None, text_responses=None, bytes_responses=None):
        self.json_responses = json_responses or {}
        self.text_responses = text_responses or {}
        self.bytes_responses = bytes_responses or {}

    def get_json(self, _fixture, url, **_kwargs):
        return self.json_responses[url]

    def get_text(self, _fixture, url, **_kwargs):
        return self.text_responses[url]

    def get_bytes(self, _fixture, url, **_kwargs):
        return self.bytes_responses[url]


class ProxyCoreResolverTests(unittest.TestCase):
    def test_latest_stable_ignores_prereleases_and_sorts_numeric_parts(self):
        self.assertEqual(
            RESOLVER.latest_stable(
                ["v1.9.0", "v1.10.0", "v1.11.0-rc.1", "v1.2.0"]
            ),
            "1.10.0",
        )

    def test_resolves_lightweight_git_tag_to_commit(self):
        url = "https://api.github.com/repos/example/project/git/ref/tags/v1.2.3"
        client = FakeClient(
            json_responses={url: {"object": {"sha": "a" * 40, "type": "commit"}}}
        )
        self.assertEqual(
            RESOLVER.resolve_git_tag(client, "example/project", "v1.2.3"),
            "a" * 40,
        )

    def test_resolves_annotated_git_tag_to_commit(self):
        ref_url = "https://api.github.com/repos/example/project/git/ref/tags/v1.2.3"
        tag_url = "https://api.github.com/repos/example/project/git/tags/" + "b" * 40
        client = FakeClient(
            json_responses={
                ref_url: {"object": {"sha": "b" * 40, "type": "tag"}},
                tag_url: {"object": {"sha": "c" * 40, "type": "commit"}},
            }
        )
        self.assertEqual(
            RESOLVER.resolve_git_tag(client, "example/project", "v1.2.3"),
            "c" * 40,
        )

    def test_selects_highest_release_and_can_include_xray_style_prereleases(self):
        url = "https://api.github.com/repos/example/project/releases?per_page=30"
        client = FakeClient(
            json_responses={
                url: [
                    {"tag_name": "v26.3.27", "prerelease": False},
                    {"tag_name": "v26.7.28", "prerelease": True},
                    {"tag_name": "v26.8.0-rc.1", "prerelease": True},
                ]
            }
        )
        tag, version = RESOLVER.latest_release(
            client,
            {"repository": "example/project", "include_prereleases": True},
        )
        self.assertEqual((tag, version), ("v26.8.0-rc.1", "26.8.0-rc.1"))
        stable_tag, stable_version = RESOLVER.latest_release(
            client,
            {"repository": "example/project", "include_prereleases": False},
        )
        self.assertEqual((stable_tag, stable_version), ("v26.3.27", "26.3.27"))

    def test_selects_latest_go_module_compatible_with_builder(self):
        list_url = "https://proxy.golang.org/golang.org/x/crypto/@v/list"
        mod_56_url = "https://proxy.golang.org/golang.org/x/crypto/@v/v0.56.0.mod"
        mod_55_url = "https://proxy.golang.org/golang.org/x/crypto/@v/v0.55.0.mod"
        client = FakeClient(
            text_responses={
                list_url: "v0.55.0\nv0.56.0\nv0.57.0-rc.1\n",
                mod_56_url: "module golang.org/x/crypto\n\ngo 1.28.0\n",
                mod_55_url: "module golang.org/x/crypto\n\ngo 1.24.0\n",
            }
        )
        self.assertEqual(
            RESOLVER.latest_compatible_module_version(
                client, "golang.org/x/crypto", (1, 27, 0)
            ),
            "0.55.0",
        )

    def test_rendered_build_args_are_safe_and_complete(self):
        values = {
            "MIHOMO_VERSION": "1.2.3",
            "MIHOMO_SOURCE_REF": "a" * 40,
            "MIHOMO_SOURCE_SHA256": "b" * 64,
        }
        rendered = RESOLVER.render_build_args(values)
        self.assertEqual(
            rendered,
            "MIHOMO_VERSION=1.2.3\n"
            + "MIHOMO_SOURCE_REF="
            + "a" * 40
            + "\n"
            + "MIHOMO_SOURCE_SHA256="
            + "b" * 64,
        )
        with self.assertRaises(RESOLVER.ResolveError):
            RESOLVER.render_build_args({"MIHOMO_VERSION": "1.2.3\nBAD=1"})

    def test_policy_is_the_single_component_identity_source(self):
        policy_path = SCRIPT_PATH.parent.parent / "configs" / "proxy-core-update-policy.json"
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
        self.assertEqual(policy["version"], 1)
        self.assertEqual(
            [item["name"] for item in policy["github_releases"]],
            ["mihomo", "sing-box", "Xray"],
        )
        self.assertEqual(len(policy["go_modules"]), 4)


if __name__ == "__main__":
    unittest.main()
