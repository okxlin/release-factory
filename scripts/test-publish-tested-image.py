#!/usr/bin/env python3
"""Publication must reject untested, mixed-run or incomplete image sets."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("publish_tested", Path(__file__).with_name("publish-tested-image.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublicationTests(unittest.TestCase):
    def test_only_openclaw_can_publish_to_the_additional_docker_hub_destination(self):
        for variant, name in MODULE.REPOSITORIES.items():
            MODULE.validate_repository(variant, f"ghcr.io/okxlin/{name}")
            if variant != "openclaw":
                with self.subTest(variant=variant), self.assertRaises(ValueError):
                    MODULE.validate_repository(variant, f"docker.io/okxlin/{name}")
        MODULE.validate_repository("openclaw", "docker.io/okxlin/openclaw-sandbox")
        for repository in ("docker.io/okxlin/other", "docker.io/okxlin/openclaw-sandbox:latest",
                           "docker.io/UPPER/openclaw-sandbox", "evil.example/okxlin/openclaw-sandbox",
                           "docker.io/okxlin/../openclaw-sandbox"):
            with self.subTest(repository=repository), self.assertRaises(ValueError):
                MODULE.validate_repository("openclaw", repository)

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

    def test_stage_publishes_the_recorded_id_by_digest_without_a_ci_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(**self.expected, image="mutable:tag", image_id=self.image_id,
                                   platform="linux/amd64", receipt=Path(tmp) / "receipt.json")
            image = {"Id": self.image_id, "Os": "linux", "Architecture": "amd64",
                     "Config": {"Labels": {"org.opencontainers.image.revision": self.expected["revision"]}}}
            calls = []
            def docker(*argv, **kwargs):
                calls.append(argv)
                return json.dumps([image]).encode() if kwargs.get("capture") else None
            class Client:
                def __init__(self, digest):
                    self.digest = digest

                def publish_platform_manifest(self, prepared):
                    return self.digest

            with patch.object(MODULE, "docker", docker), \
                 patch.object(MODULE, "save_image"), \
                 patch.object(MODULE, "prepare_platform_manifest", return_value=object()), \
                 patch.object(MODULE, "create_registry_client", return_value=Client(self.digest)), \
                 patch.object(MODULE, "remote_manifest", return_value=(self.manifest, self.digest)):
                MODULE.stage(args, self.expected)
            self.assertEqual(calls, [("image", "inspect", "mutable:tag")])
            self.assertNotIn(":ci-", str(json.loads(args.receipt.read_text())))
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
        for mutation in ({"run_id": "124"}, {"revision": "e" * 40}, {"run_attempt": "2"}, {"variant": "codex"},
                         {"repository": "docker.io/okxlin/openclaw-sandbox"}):
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


class OpenClawWorkflowTests(unittest.TestCase):
    def test_dual_registry_shell_orders_version_tags_before_latest_and_stops_on_failure(self):
        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/openclaw-upstream-docker.yml"
        step = workflow.read_text().split("      - name: Publish the verified image without rebuilding\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        for fail_at in (0, 2, 4, 5):
            with self.subTest(fail_at=fail_at), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                recorder = root / "python3"
                recorder.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                    import json, os, sys
                    from pathlib import Path
                    path = Path(os.environ["CALL_LOG"])
                    calls = json.loads(path.read_text()) if path.exists() else []
                    calls.append(sys.argv[1:])
                    path.write_text(json.dumps(calls))
                    sys.exit(1 if len(calls) == int(os.environ["FAIL_AT"]) else 0)
                    '''))
                recorder.chmod(0o755)
                env = {**os.environ, "PATH": tmp + os.pathsep + os.environ["PATH"],
                       "CALL_LOG": str(root / "calls.json"), "FAIL_AT": str(fail_at), "RUNNER_TEMP": tmp,
                       "IMAGE": "sha256:" + "a" * 64, "GITHUB_SHA": "b" * 40,
                       "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "IMAGE_TAG": "v1-sandbox",
                       "REPOSITORY": "ghcr.io/okxlin/openclaw-sandbox", "DOCKERHUB_NAMESPACE": "okxlin"}
                result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if fail_at == 0 else 1, result.stderr)
                calls = json.loads((root / "calls.json").read_text())
                self.assertEqual(len(calls), fail_at or 6)
                expected = [(command, registry, tag) for command, tag in
                            (("stage", None), ("publish", "v1-sandbox"), ("publish", "latest"))
                            for registry in ("ghcr.io/okxlin/openclaw-sandbox", "docker.io/okxlin/openclaw-sandbox")]
                for call, (command, registry, tag) in zip(calls, expected):
                    self.assertEqual(call[1], command)
                    self.assertEqual(call[call.index("--repository") + 1], registry)
                    if tag:
                        self.assertEqual(call[call.index("--image-tag") + 1], tag)
                    else:
                        self.assertEqual(call[call.index("--image-id") + 1], env["IMAGE"])


if __name__ == "__main__":
    unittest.main()
