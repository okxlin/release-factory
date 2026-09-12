#!/usr/bin/env python3
"""Registry failures must not be mistaken for a missing or fresh release."""
import datetime as dt
import hashlib
import importlib.util
import json
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
                self.registry.labels("latest")

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

    def test_config_platform_is_checked(self):
        config = {"os": "linux", "architecture": "amd64", "config": {"Labels": {"test": "ok"}}}
        body = json.dumps(config).encode()
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        manifest = json.dumps({"config": {"digest": digest}}).encode()
        with patch.object(MODULE, "http", side_effect=[(200, {}, manifest), (200, {}, body)]):
            self.assertEqual(self.registry.labels("latest"), {"test": "ok"})
        with patch.object(self.registry, "get", side_effect=[{"config": {"digest": digest}}, {**config, "architecture": "arm64"}]):
            with self.assertRaisesRegex(ValueError, "platform"):
                self.registry.labels("latest")


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


if __name__ == "__main__":
    unittest.main()
