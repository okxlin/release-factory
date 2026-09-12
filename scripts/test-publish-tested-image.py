#!/usr/bin/env python3
"""Publication must reject untested, mixed-run or incomplete image sets."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("publish_tested", Path(__file__).with_name("publish-tested-image.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.expected = {"variant": "opencode", "repository": "ghcr.io/okxlin/opencode-workstation",
                         "revision": "a" * 40, "run_id": "123", "run_attempt": "1"}
        self.image_id = "sha256:" + "b" * 64
        self.digest = "sha256:" + "c" * 64
        self.manifest = {"schemaVersion": 2, "mediaType": next(iter(MODULE.IMAGE_TYPES)),
                         "config": {"digest": self.image_id}}

    def receipt(self, platform="linux/amd64"):
        return {"schema_version": 1, **self.expected, "platform": platform,
                "image_id": self.image_id if platform == "linux/amd64" else "sha256:" + "d" * 64,
                "manifest_digest": self.digest if platform == "linux/amd64" else "sha256:" + "e" * 64}

    def write_receipt(self, root, receipt, name="amd64"):
        directory = root / name
        directory.mkdir()
        (directory / "receipt.json").write_text(json.dumps(receipt))

    def test_stage_tags_the_recorded_id_and_checks_remote_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(**self.expected, image="mutable:tag", image_id=self.image_id,
                                   platform="linux/amd64", receipt=Path(tmp) / "receipt.json")
            image = {"Id": self.image_id, "Os": "linux", "Architecture": "amd64",
                     "Config": {"Labels": {"org.opencontainers.image.revision": self.expected["revision"]}}}
            calls = []
            def docker(*argv, **kwargs):
                calls.append(argv)
                return json.dumps([image]).encode() if kwargs.get("capture") else None
            with patch.object(MODULE, "docker", docker), patch.object(MODULE, "remote_manifest", return_value=(self.manifest, self.digest)):
                MODULE.stage(args, self.expected)
            self.assertEqual(calls[1][0:3], ("image", "tag", self.image_id))
            self.assertEqual(json.loads(args.receipt.read_text())["image_id"], self.image_id)

    def test_changed_image_or_platform_never_reaches_registry_write(self):
        for field, value in (("Id", "sha256:" + "d" * 64), ("Architecture", "arm64")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                args = SimpleNamespace(**self.expected, image="mutable:tag", image_id=self.image_id,
                                       platform="linux/amd64", receipt=Path(tmp) / "receipt.json")
                image = {"Id": self.image_id, "Os": "linux", "Architecture": "amd64"}
                image[field] = value
                with patch.object(MODULE, "docker", return_value=json.dumps([image]).encode()) as docker:
                    with self.assertRaises(ValueError):
                        MODULE.stage(args, self.expected)
                self.assertEqual(docker.call_count, 1)

    def test_missing_or_mixed_receipts_fail_before_remote_lookup(self):
        for mutation in ({"run_id": "124"}, {"revision": "e" * 40}, {"run_attempt": "2"}, {"variant": "codex"}):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self.write_receipt(root, {**self.receipt(), **mutation})
                with patch.object(MODULE, "remote_manifest") as remote:
                    with self.assertRaises(ValueError):
                        MODULE.check_receipts(root, self.expected, ["linux/amd64"])
                    remote.assert_not_called()
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            MODULE.check_receipts(Path(tmp), self.expected, list(MODULE.PLATFORMS))

    def test_tampered_second_image_prevents_all_release_tag_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_receipt(root, self.receipt())
            self.write_receipt(root, self.receipt("linux/arm64"), "arm64")
            args = SimpleNamespace(**self.expected, directory=root, platforms=",".join(MODULE.PLATFORMS),
                                   image_tag="release", latest_tag="latest", dry_run=False)
            wrong = {**self.manifest, "config": {"digest": "sha256:" + "d" * 64}}
            with patch.object(MODULE, "remote_manifest", side_effect=[(self.manifest, self.digest), (wrong, self.digest)]), patch.object(MODULE, "docker") as docker:
                with self.assertRaises(ValueError):
                    MODULE.publish(args, self.expected)
                docker.assert_not_called()

    def test_complete_set_passes_remote_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_receipt(root, self.receipt())
            self.write_receipt(root, self.receipt("linux/arm64"), "arm64")
            arm = self.receipt("linux/arm64")
            arm_manifest = {**self.manifest, "config": {"digest": arm["image_id"]}}
            with patch.object(MODULE, "remote_manifest", side_effect=[(self.manifest, self.digest), (arm_manifest, arm["manifest_digest"])]):
                receipts = MODULE.check_receipts(root, self.expected, list(MODULE.PLATFORMS))
            self.assertEqual(set(receipts), set(MODULE.PLATFORMS))

    def test_duplicate_image_cannot_claim_two_architectures(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_receipt(root, self.receipt())
            self.write_receipt(root, {**self.receipt(), "platform": "linux/arm64"}, "arm64")
            with patch.object(MODULE, "remote_manifest") as remote, self.assertRaisesRegex(ValueError, "share"):
                MODULE.check_receipts(root, self.expected, list(MODULE.PLATFORMS))
            remote.assert_not_called()

    def test_published_index_must_match_the_verified_platform_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_receipt(root, self.receipt())
            args = SimpleNamespace(**self.expected, directory=root, platforms="linux/amd64",
                                   image_tag="release", latest_tag="", dry_run=False)
            index = {"schemaVersion": 2, "mediaType": next(iter(MODULE.INDEX_TYPES)), "manifests": [
                {"platform": {"os": "linux", "architecture": "amd64"}, "digest": self.digest}]}
            with patch.object(MODULE, "remote_manifest", side_effect=[(self.manifest, self.digest), (index, "sha256:" + "f" * 64)]), patch.object(MODULE, "docker") as docker:
                MODULE.publish(args, self.expected)
            self.assertIn(self.expected["repository"] + "@" + self.digest, docker.call_args.args)


if __name__ == "__main__":
    unittest.main()
