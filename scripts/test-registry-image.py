#!/usr/bin/env python3
"""Verify image-layer identity and the Registry V2 digest-only upload contract."""
import gzip
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import registry_image as registry


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def layer(content):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as tar:
        member = tarfile.TarInfo("value.txt")
        member.size = len(content)
        tar.addfile(member, io.BytesIO(content))
    return stream.getvalue()


class LayerTests(unittest.TestCase):
    def prepare(self, *, compressed=False, corrupt=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        data = [layer(b"base"), layer(b"upper")]
        names = ["base/layer.tar", "upper/layer.tar"]
        config = {"rootfs": {"type": "layers", "diff_ids": [digest(b) for b in data]}}
        if corrupt == "count":
            config["rootfs"]["diff_ids"].pop()
        if corrupt == "digest":
            config["rootfs"]["diff_ids"][0] = "invalid"
        if corrupt == "type":
            config["rootfs"]["type"] = "unknown"
        config_bytes = json.dumps(config).encode()
        image_id = digest(config_bytes)
        config_name = image_id[7:] + ".json"
        manifest = [{"Config": config_name, "Layers": names}]
        members = [(config_name, config_bytes), ("manifest.json", json.dumps(manifest).encode())]
        for name, raw in reversed(list(zip(names, data))):
            if corrupt == "missing" and name == names[0]:
                continue
            if corrupt == "bytes" and name == names[0]:
                raw = layer(b"wrong")
            stored = gzip.compress(raw, mtime=0) if compressed else raw
            if corrupt == "gzip" and name == names[0]:
                stored = gzip.compress(raw)[:-8]
            if corrupt == "zstd" and name == names[0]:
                stored = b"\x28\xb5\x2f\xfd" + raw
            members.append((name, stored))
        archive = root / "image.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for name, body in members:
                member = tarfile.TarInfo(name)
                member.size = len(body)
                tar.addfile(member, io.BytesIO(body))
        prepared = registry.prepare_platform_manifest(archive, image_id, root / "prepared")
        return prepared, config

    def test_tar_member_order_does_not_change_filesystem_layer_order(self):
        for compressed in (False, True):
            with self.subTest(compressed=compressed):
                prepared, config = self.prepare(compressed=compressed)
                actual = [digest(gzip.decompress(prepared["blobs"][d["digest"]].read_bytes()))
                          for d in prepared["manifest"]["layers"]]
                self.assertEqual(actual, config["rootfs"]["diff_ids"])

    def test_invalid_layers_fail_before_publication(self):
        for corrupt in ("count", "digest", "type", "missing", "bytes", "gzip", "zstd"):
            with self.subTest(corrupt=corrupt), self.assertRaises((ValueError, EOFError, OSError)):
                self.prepare(corrupt=corrupt)


class RegistryTests(unittest.TestCase):
    def client(self, host="ghcr.io"):
        client = registry.RegistryClient(host + "/owner/image", "user", "test-password")
        client.token = "test-token"
        return client

    def test_upload_preserves_opaque_location_query(self):
        for host in ("ghcr.io", "docker.io"):
            for absolute in (False, True):
                with self.subTest(host=host, absolute=absolute), tempfile.TemporaryDirectory() as tmp:
                    client = self.client(host)
                    path = Path(tmp) / "blob"
                    path.write_bytes(b"blob")
                    location = "/v2/owner/image/blobs/uploads/1?token=a%2fb&space=%20&empty&x=1&x=2"
                    if absolute:
                        location = "https://" + client.registry_host + location
                    with patch.object(client, "_send", side_effect=[
                        (404, {}), (202, {"location": location}), (201, {}),
                    ]) as send:
                        client._upload_blob(digest(b"blob"), path)
                    expected = (location if absolute else "https://" + client.registry_host + location)
                    self.assertEqual(send.call_args.args[1], expected + "&digest=" + digest(b"blob").replace(":", "%3A"))

    def test_incomplete_upload_is_rejected(self):
        client = self.client()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "blob"
            path.write_bytes(b"blob")
            with patch.object(client, "_send", side_effect=[
                (404, {}), (202, {"location": "/v2/owner/image/blobs/uploads/1"}), (202, {}),
            ]), self.assertRaisesRegex(ValueError, "HTTP 202"):
                client._upload_blob(digest(b"blob"), path)

    def test_existing_blob_does_not_start_an_upload(self):
        client = self.client()
        with patch.object(client, "_send", return_value=(200, {})) as send:
            client._upload_blob(digest(b"blob"), Path("unused"))
        self.assertEqual(send.call_count, 1)
        self.assertEqual(send.call_args.args[0], "HEAD")

    def test_untrusted_upload_locations_are_rejected(self):
        client = self.client()
        for url in ("https://evil.example/upload", "http://ghcr.io/upload", "https://user@ghcr.io/upload"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                client._upload_url(url)


if __name__ == "__main__":
    unittest.main()
