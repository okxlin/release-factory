#!/usr/bin/env python3
"""Registry failures must not be mistaken for a missing or fresh release."""
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("openclaw_inputs", Path(__file__).with_name("resolve-openclaw-inputs.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.registry = MODULE.Registry("ghcr.io/okxlin/openclaw-sandbox")
        self.challenge = 'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:okxlin/openclaw-sandbox:pull"'

    def test_bearer_challenge_then_pull(self):
        replies = [(401, {"www-authenticate": self.challenge}, b""),
                   (200, {}, b'{"token":"test-token"}'), (200, {}, b'{"schemaVersion":2}')]
        with patch.object(MODULE, "http", side_effect=replies) as http:
            self.assertEqual(self.registry.get("manifests", "latest"), {"schemaVersion": 2})
        self.assertEqual(http.call_args_list[-1].args[1]["Authorization"], "Bearer test-token")
        self.assertTrue(http.call_args_list[1].args[0].startswith("https://ghcr.io/token?"))

    def test_only_404_can_mean_missing(self):
        for status in (403, 429, 500):
            with self.subTest(status=status), patch.object(MODULE, "http", return_value=(status, {}, b"")):
                with self.assertRaises(ValueError):
                    self.registry.get("manifests", "latest", missing_ok=True)
        with patch.object(MODULE, "http", return_value=(404, {}, b"")):
            self.assertIsNone(self.registry.get("manifests", "latest", missing_ok=True))
            with self.assertRaises(ValueError):
                self.registry.get("blobs", "sha256:" + "a" * 64)

    def test_failed_bearer_auth_is_fatal(self):
        for replies in (
            [(401, {"www-authenticate": self.challenge}, b""), (403, {}, b"")],
            [(401, {"www-authenticate": self.challenge}, b""), (200, {}, b'{"token":"test-token"}'), (401, {}, b"")],
        ):
            self.registry.token = None
            with self.subTest(replies=replies), patch.object(MODULE, "http", side_effect=replies):
                with self.assertRaises(ValueError):
                    self.registry.get("manifests", "latest", missing_ok=True)

    def test_network_failure_is_fatal(self):
        with patch.object(MODULE, "http", side_effect=TimeoutError("network unavailable")):
            with self.assertRaises(TimeoutError):
                self.registry.image("latest")

    def test_docker_hub_auth_never_receives_github_credentials(self):
        registry = MODULE.Registry("docker.io/okxlin/openclaw-sandbox")
        challenge = 'Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:okxlin/openclaw-sandbox:pull"'
        replies = [(401, {"www-authenticate": challenge}, b""),
                   (200, {}, b'{"token":"hub-token"}'), (404, {}, b"")]
        with patch.dict(os.environ, {"GH_TOKEN": "github-credential"}), patch.object(MODULE, "http", side_effect=replies) as http:
            self.assertIsNone(registry.image("latest"))
        self.assertTrue(http.call_args_list[0].args[0].startswith("https://registry-1.docker.io/v2/"))
        self.assertTrue(http.call_args_list[1].args[0].startswith("https://auth.docker.io/token?"))
        self.assertEqual(http.call_args_list[1].args[1], {})
        self.assertEqual(http.call_args_list[-1].args[1]["Authorization"], "Bearer hub-token")
        with patch.object(MODULE, "http") as http:
            with self.assertRaisesRegex(ValueError, "challenge"):
                registry.authorize(self.challenge)
            http.assert_not_called()

    def test_challenge_cannot_retarget_credentials(self):
        for challenge in (self.challenge.replace("https://ghcr.io/token", "https://example.org/token"),
                          self.challenge.replace(":pull", ":pull,push"), "Basic realm=ghcr.io"):
            with self.subTest(challenge=challenge), patch.object(MODULE, "http") as http:
                with self.assertRaises(ValueError):
                    self.registry.authorize(challenge)
                http.assert_not_called()

    def test_signed_blob_redirect_strips_auth_and_checks_digest(self):
        body = b'{"os":"linux"}'
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        self.registry.token = "test-token"
        with patch.object(MODULE, "http", side_effect=[
            (307, {"location": "https://pkg-containers.githubusercontent.com/config"}, b""), (200, {}, body)
        ]) as http:
            self.assertEqual(self.registry.get("blobs", digest), {"os": "linux"})
        self.assertEqual(http.call_args_list[-1].args[1], {})
        with patch.object(MODULE, "http", return_value=(200, {}, b"{}")):
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                self.registry.get("blobs", digest)

    def test_docker_hub_blob_redirect_is_bounded_and_strips_auth(self):
        registry = MODULE.Registry("docker.io/okxlin/openclaw-sandbox")
        registry.token = "hub-token"
        body = b'{"os":"linux"}'
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        with patch.object(MODULE, "http", side_effect=[
            (307, {"location": "https://production.cloudfront.docker.com/config"}, b""), (200, {}, body)
        ]) as http:
            self.assertEqual(registry.get("blobs", digest), {"os": "linux"})
        self.assertEqual(http.call_args_list[-1].args[1], {})
        for target in ("https://production.cloudfront.docker.com.evil.example/config",
                       "http://production.cloudfront.docker.com/config", "https://example.org/config",
                       "https://user:pass@production.cloudfront.docker.com/config"):
            with self.subTest(target=target), patch.object(MODULE, "http", return_value=(307, {"location": target}, b"")) as http:
                with self.assertRaisesRegex(ValueError, "redirect"):
                    registry.get("blobs", digest)
                self.assertEqual(http.call_count, 1)

    def test_config_platform_is_checked(self):
        config = {"os": "linux", "architecture": "amd64", "config": {"Labels": {"test": "ok"}}}
        body = json.dumps(config).encode()
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        manifest = json.dumps({"config": {"digest": digest}}).encode()
        with patch.object(MODULE, "http", side_effect=[(200, {}, manifest), (200, {}, body)]):
            self.assertEqual(self.registry.image("latest"), (digest, {"test": "ok"}))
        with patch.object(self.registry, "get", side_effect=[{"config": {"digest": digest}}, {**config, "architecture": "arm64"}]):
            with self.assertRaisesRegex(ValueError, "platform"):
                self.registry.image("latest")


class FreshnessTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 9, 12, tzinfo=dt.UTC)
        self.labels = {"io.release-factory.upstream.revision": "a" * 40,
                       "io.release-factory.recipe": "sha256:" + "b" * 64,
                       "io.release-factory.build.created": self.now.isoformat()}

    def check(self, labels):
        return MODULE.needs_build(labels, "a" * 40, "sha256:" + "b" * 64, self.now, 7)[0]

    def test_only_same_source_recipe_and_fresh_build_can_skip(self):
        self.assertFalse(self.check(self.labels))
        self.assertTrue(self.check(None))
        self.assertTrue(self.check({}))
        for key in ("io.release-factory.upstream.revision", "io.release-factory.recipe"):
            self.assertTrue(self.check({**self.labels, key: "changed"}))

    def test_exact_age_boundary_invalid_and_future_dates_rebuild(self):
        key = "io.release-factory.build.created"
        for value in ("invalid", "2026-09-12", (self.now - dt.timedelta(days=7)).isoformat(),
                      (self.now + dt.timedelta(seconds=1)).isoformat()):
            with self.subTest(value=value):
                self.assertTrue(self.check({**self.labels, key: value}))
        self.assertFalse(self.check({**self.labels, key: (self.now - dt.timedelta(days=6, hours=23)).isoformat()}))

    def test_every_registry_version_and_latest_must_match(self):
        repositories = ["ghcr.io/okxlin/openclaw-sandbox", "docker.io/okxlin/openclaw-sandbox"]
        image = ("sha256:" + "c" * 64, self.labels)
        for position in range(4):
            for replacement in (None, ("sha256:" + "d" * 64, self.labels), (image[0], {})):
                images = [image] * 4
                images[position] = replacement
                with self.subTest(position=position, replacement=replacement), patch.object(MODULE.Registry, "image", side_effect=images):
                    rebuild, _ = MODULE.needs_publication(repositories, "v1-sandbox", "a" * 40,
                                                         "sha256:" + "b" * 64, self.now, 7)
                    self.assertTrue(rebuild)
        with patch.object(MODULE.Registry, "image", return_value=image) as lookup:
            rebuild, _ = MODULE.needs_publication(repositories, "v1-sandbox", "a" * 40,
                                                 "sha256:" + "b" * 64, self.now, 7)
            self.assertFalse(rebuild)
            self.assertEqual([call.args[0] for call in lookup.call_args_list], ["v1-sandbox", "latest"] * 2)

    def test_mirror_auth_failure_is_not_a_missing_tag(self):
        with patch.object(MODULE.Registry, "image", side_effect=[
            ("sha256:" + "c" * 64, self.labels), ("sha256:" + "c" * 64, self.labels), ValueError("HTTP 401")
        ]):
            with self.assertRaisesRegex(ValueError, "401"):
                MODULE.needs_publication(["ghcr.io/okxlin/openclaw-sandbox", "docker.io/okxlin/openclaw-sandbox"],
                                         "v1-sandbox", "a" * 40, "sha256:" + "b" * 64, self.now, 7)


if __name__ == "__main__":
    unittest.main()
