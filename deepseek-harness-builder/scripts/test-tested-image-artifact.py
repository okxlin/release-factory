#!/usr/bin/env python3
"""Publication must fail closed when a verified image or release input changes."""

from argparse import Namespace
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("artifacts", Path(__file__).with_name("tested-image-artifact.py"))
artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifacts)


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode()


class TestedImageArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.expected = {"variant": "runtime", "revision": "a" * 40,
                         "dsh_version": "0.1.5-rc.1", "run_id": "123"}
        self.options = Namespace(directory=self.root, platforms="linux/amd64,linux/arm64",
                                 repository=["ghcr.io/okxlin/deepseek-harness", "docker.io/okxlin/deepseek-harness"],
                                 image_tag="0.1.5-rc.1", latest_tag="latest", run_attempt="2",
                                 dry_run=False, summary=None)
        self.configs = {}
        self.calls = []
        self.remote = {}
        self.tagged = {}
        self.write_artifact("amd64")
        self.write_artifact("arm64")

    def directory(self, arch):
        return self.root / f"deepseek-harness-{self.expected['variant']}-image-{arch}"

    def write_artifact(self, arch, *, config_changes=None, docker_layout=False):
        config = {"os": "linux", "architecture": arch,
                  "config": {"Env": [f"DSH_IMAGE_VARIANT={self.expected['variant']}"], "Labels": {
                      "org.opencontainers.image.revision": self.expected["revision"],
                      "org.opencontainers.image.version": self.expected["dsh_version"]}}}
        if config_changes:
            config_changes(config)
        config_bytes = encode(config)
        digest = hashlib.sha256(config_bytes).hexdigest()
        image_id = "sha256:" + digest
        self.configs[image_id] = config
        config_name = f"{digest}.json" if docker_layout else f"blobs/sha256/{digest}"
        manifest = [{"Config": config_name, "RepoTags": None, "Layers": []}]
        directory = self.directory(arch)
        directory.mkdir(exist_ok=True)
        with tarfile.open(directory / "image.tar.gz", "w:gz") as saved:
            for name, content in [(config_name, config_bytes), ("manifest.json", encode(manifest))]:
                member = tarfile.TarInfo(name)
                member.size = len(content)
                saved.addfile(member, io.BytesIO(content))
        receipt = {"schema_version": 1, **self.expected, "platform": f"linux/{arch}",
                   "image_id": image_id, "archive_sha256": artifacts.sha256(directory / "image.tar.gz")}
        (directory / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
        return receipt

    def edit_receipt(self, arch, **changes):
        path = self.directory(arch) / "receipt.json"
        receipt = json.loads(path.read_text())
        receipt.update(changes)
        path.write_text(json.dumps(receipt), encoding="utf-8")

    def docker(self, *args, capture=False):
        self.calls.append(args)
        if args[:2] == ("image", "load"):
            return None
        if args[:2] == ("image", "inspect"):
            image_id = args[2]
            config = self.configs[image_id]
            return encode([{"Id": image_id, "Os": config["os"], "Architecture": config["architecture"],
                            "Config": config["config"]}])
        if args[:2] == ("image", "tag"):
            self.tagged[args[3]] = args[2]
            return None
        if args[:2] == ("image", "push"):
            reference = args[2]
            manifest = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "config": {"digest": self.tagged[reference]}}
            self.remote[reference] = encode(manifest)
            return None
        if args[:4] == ("buildx", "imagetools", "inspect", "--raw"):
            return self.remote[args[4]]
        if args[:3] == ("buildx", "imagetools", "create"):
            reference = args[5]
            entries = []
            for source in args[6:]:
                digest = source.split("@")[1]
                raw = next(raw for raw in self.remote.values()
                           if "sha256:" + hashlib.sha256(raw).hexdigest() == digest)
                image_id = json.loads(raw)["config"]["digest"]
                entries.append({"digest": digest, "platform": {
                    "os": "linux", "architecture": self.configs[image_id]["architecture"]}})
            self.remote[reference] = encode({"schemaVersion": 2,
                                            "mediaType": "application/vnd.oci.image.index.v1+json",
                                            "manifests": entries})
            return None
        self.fail(f"unexpected Docker operation (especially a rebuild): {args}")

    def publish(self, docker=None):
        with patch.object(artifacts, "docker", docker or self.docker), contextlib.redirect_stdout(io.StringIO()):
            artifacts.publish_images(self.options, self.expected)

    def assert_rejected_without_registry_writes(self):
        with self.assertRaises((ValueError, tarfile.TarError)):
            self.publish()
        self.assertFalse(any(call[:2] in (("image", "push"), ("image", "tag"))
                             or call[:3] == ("buildx", "imagetools", "create") for call in self.calls))

    def test_publishes_tested_config_ids_to_both_registries_before_floating_tags(self):
        self.publish()
        pushes = [call for call in self.calls if call[:2] == ("image", "push")]
        self.assertEqual(len(pushes), 4)
        first_manifest = next(i for i, call in enumerate(self.calls) if call[:3] == ("buildx", "imagetools", "create"))
        self.assertEqual(sum(call[:2] == ("image", "push") for call in self.calls[:first_manifest]), 4)
        creates = [call for call in self.calls if call[:3] == ("buildx", "imagetools", "create")]
        self.assertEqual([call[5].rsplit(":", 1)[1] for call in creates],
                         ["0.1.5-rc.1", "0.1.5-rc.1", "latest", "latest"])
        self.assertEqual(set(self.tagged.values()), set(self.configs))
        self.assertTrue(all("@sha256:" in source for call in creates for source in call[6:]))

    def test_supports_both_docker_archive_config_layouts(self):
        self.write_artifact("amd64", docker_layout=True)
        self.publish()

    def test_workstation_arm_only_publishes_only_the_requested_platform(self):
        self.root = self.root / "arm-only"
        self.root.mkdir()
        self.options.directory = self.root
        self.options.platforms = "linux/arm64"
        self.expected["variant"] = "workstation"
        self.options.image_tag = "0.1.5-rc.1-workstation"
        self.options.latest_tag = "workstation"
        receipt = self.write_artifact("arm64")
        self.publish()
        self.assertEqual(set(self.tagged.values()), {receipt["image_id"]})
        self.assertEqual(len(self.tagged), 2)

    def test_dry_run_checks_artifacts_without_docker_or_registry_access(self):
        self.options.dry_run = True
        self.publish()
        self.assertEqual(self.calls, [])

    def test_rejects_corrupted_last_architecture_before_pushing_first(self):
        with (self.directory("arm64") / "image.tar.gz").open("ab") as archive:
            archive.write(b"tampered")
        self.assert_rejected_without_registry_writes()
        self.assertEqual(self.calls, [])

    def test_rejects_receipt_from_another_run_revision_version_variant_or_platform(self):
        for key, value in {"run_id": "122", "revision": "b" * 40, "dsh_version": "0.1.5",
                           "variant": "workstation", "platform": "linux/amd64"}.items():
            with self.subTest(field=key):
                self.write_artifact("arm64")
                self.edit_receipt("arm64", **{key: value})
                self.assert_rejected_without_registry_writes()

    def test_rejects_missing_platform(self):
        (self.directory("arm64") / "receipt.json").unlink()
        self.assert_rejected_without_registry_writes()

    def test_rejects_extra_platform_or_artifact(self):
        (self.root / "unrequested-image").mkdir()
        self.assert_rejected_without_registry_writes()

    def test_rejects_symlinked_archive(self):
        archive = self.directory("arm64") / "image.tar.gz"
        archive.unlink()
        archive.symlink_to(self.directory("amd64") / "image.tar.gz")
        self.assert_rejected_without_registry_writes()

    def test_rejects_config_id_substitution_even_with_valid_archive_checksum(self):
        amd64 = json.loads((self.directory("amd64") / "receipt.json").read_text())
        self.edit_receipt("arm64", image_id=amd64["image_id"])
        self.assert_rejected_without_registry_writes()

    def test_rejects_wrong_image_labels_or_platform_even_with_valid_config_digest(self):
        changes = [lambda config: config.update(architecture="amd64"),
                   lambda config: config["config"].update(Env=["DSH_IMAGE_VARIANT=workstation"]),
                   lambda config: config["config"]["Labels"].update({"org.opencontainers.image.revision": "b" * 40}),
                   lambda config: config["config"]["Labels"].update({"org.opencontainers.image.version": "0.1.5"})]
        for change in changes:
            with self.subTest(change=change):
                self.write_artifact("arm64", config_changes=change)
                self.assert_rejected_without_registry_writes()

    def test_checks_loaded_image_again_before_any_push(self):
        def replaced_image(*args, **kwargs):
            result = self.docker(*args, **kwargs)
            if args[:2] == ("image", "inspect"):
                result = json.loads(result)
                result[0]["Id"] = "sha256:" + "f" * 64
                return encode(result)
            return result
        with self.assertRaisesRegex(ValueError, "image ID changed"):
            self.publish(replaced_image)
        self.assertFalse(any(call[:2] == ("image", "push") for call in self.calls))

    def test_registry_push_failure_never_updates_release_tags(self):
        def failed_push(*args, **kwargs):
            if args[:2] == ("image", "push") and args[2].startswith("docker.io/"):
                raise subprocess.CalledProcessError(1, "docker push")
            return self.docker(*args, **kwargs)
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish(failed_push)
        self.assertFalse(any(call[:3] == ("buildx", "imagetools", "create") for call in self.calls))

    def test_registry_config_mismatch_never_updates_release_tags(self):
        def wrong_config(*args, **kwargs):
            result = self.docker(*args, **kwargs)
            if args[:4] == ("buildx", "imagetools", "inspect", "--raw"):
                manifest = json.loads(result)
                manifest["config"]["digest"] = "sha256:" + "e" * 64
                return encode(manifest)
            return result
        with self.assertRaisesRegex(ValueError, "pushed image does not match"):
            self.publish(wrong_config)
        self.assertFalse(any(call[:3] == ("buildx", "imagetools", "create") for call in self.calls))

    def test_incomplete_version_manifest_never_updates_floating_tags(self):
        def wrong_index(*args, **kwargs):
            result = self.docker(*args, **kwargs)
            if args[:4] == ("buildx", "imagetools", "inspect", "--raw"):
                manifest = json.loads(result)
                if "manifests" in manifest:
                    manifest["manifests"].pop()
                    return encode(manifest)
            return result
        with self.assertRaisesRegex(ValueError, "index does not match"):
            self.publish(wrong_index)
        self.assertFalse(any(call[:3] == ("buildx", "imagetools", "create")
                             and call[5].endswith(":latest") for call in self.calls))

    def test_rejects_unsupported_duplicate_or_empty_platform_before_docker(self):
        for platforms in ["linux/386", "linux/amd64,linux/amd64", "linux/amd64,", ""]:
            with self.subTest(platforms=platforms):
                self.options.platforms = platforms
                self.assert_rejected_without_registry_writes()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
