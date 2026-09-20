"""Publish verified Docker-save images without creating staging tags."""

import base64
import gzip
import hashlib
import http.client
import json
import os
import re
import shutil
import subprocess
import tarfile
import urllib.error
import urllib.parse
import urllib.request

DIGEST = re.compile(r"sha256:[a-f0-9]{64}")
IMAGE_TYPES = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}
INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}
REGISTRY_CONFIG = {
    "ghcr.io": {
        "registry_host": "ghcr.io",
        "token_url": "https://ghcr.io/token",
        "service": "ghcr.io",
        "upload_hosts": {"ghcr.io"},
    },
    "docker.io": {
        "registry_host": "registry-1.docker.io",
        "token_url": "https://auth.docker.io/token",
        "service": "registry.docker.io",
        "upload_hosts": {"registry-1.docker.io", "docker.io"},
    },
}
BLOB_CHUNK_SIZE = 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def save_image(image_id, archive):
    """Save one local image as the gzip-wrapped Docker archive format."""
    with archive.open("xb") as target, subprocess.Popen(
        ["docker", "image", "save", image_id], stdout=subprocess.PIPE
    ) as saved, gzip.GzipFile(filename="", mode="wb", fileobj=target,
                               compresslevel=1, mtime=0) as zipped:
        shutil.copyfileobj(saved.stdout, zipped, BLOB_CHUNK_SIZE)
        require(saved.wait() == 0, "docker image save failed")


def archive_metadata(archive, image_id):
    digest = image_id.removeprefix("sha256:")
    config_names = {f"{digest}.json", f"blobs/sha256/{digest}"}
    metadata = {}
    with tarfile.open(archive, "r|gz") as saved:
        for member in saved:
            if member.name not in config_names | {"manifest.json"}:
                continue
            require(member.isfile() and member.size <= 4 * 1024 * 1024,
                    "invalid image archive metadata member")
            require(member.name not in metadata, "duplicate image archive metadata")
            source = saved.extractfile(member)
            require(source is not None, f"cannot read image archive metadata: {member.name}")
            with source:
                metadata[member.name] = source.read()
    manifest = json.loads(metadata.get("manifest.json", b"null"))
    require(isinstance(manifest, list) and len(manifest) == 1
            and isinstance(manifest[0], dict), "archive must contain exactly one image")
    config_name = manifest[0].get("Config")
    require(isinstance(config_name, str) and config_name in config_names and config_name in metadata,
            "archive config does not match tested image ID")
    config_bytes = metadata[config_name]
    require(hashlib.sha256(config_bytes).hexdigest() == digest, "archive image config digest mismatch")
    return config_bytes, manifest[0]


def prepare_platform_manifest(archive, image_id, destination):
    """Convert one Docker-save archive into a digest-addressed platform manifest."""
    require(DIGEST.fullmatch(image_id), "invalid image ID")
    config_bytes, saved_manifest = archive_metadata(archive, image_id)
    layer_names = saved_manifest.get("Layers")
    require(isinstance(layer_names, list) and all(isinstance(name, str) for name in layer_names),
            "archive image layers are invalid")
    require(len(layer_names) == len(set(layer_names)), "duplicate image archive layer")

    destination.mkdir(parents=True, exist_ok=True)
    config_path = destination / "config.json"
    config_path.write_bytes(config_bytes)
    blobs = {image_id: config_path}
    layers = []
    found_layers = set()
    with tarfile.open(archive, "r|gz") as saved:
        for member in saved:
            if member.name not in layer_names:
                continue
            require(member.isfile(), f"image archive layer is not a regular file: {member.name}")
            require(member.name not in found_layers, f"duplicate image archive layer member: {member.name}")
            found_layers.add(member.name)
            source = saved.extractfile(member)
            require(source is not None, f"cannot read image archive layer: {member.name}")
            require(member.size >= 0 and member.size <= shutil.disk_usage(destination).free,
                    f"image archive layer exceeds available staging space: {member.name}")
            raw_layer = destination / f"layer-{len(layers)}.tar"
            with source, raw_layer.open("wb") as target:
                shutil.copyfileobj(source, target, BLOB_CHUNK_SIZE)
            require(raw_layer.stat().st_size == member.size,
                    f"image archive layer size changed while reading: {member.name}")
            compressed_layer = destination / f"layer-{len(layers)}.tar.gz"
            with raw_layer.open("rb") as source:
                magic = source.read(2)
            if magic == b"\x1f\x8b":
                shutil.copyfile(raw_layer, compressed_layer)
            else:
                with raw_layer.open("rb") as source, compressed_layer.open("wb") as target, \
                     gzip.GzipFile(filename="", mode="wb", fileobj=target,
                                   compresslevel=1, mtime=0) as zipped:
                    shutil.copyfileobj(source, zipped, BLOB_CHUNK_SIZE)
            raw_layer.unlink()
            digest = "sha256:" + sha256(compressed_layer)
            blobs[digest] = compressed_layer
            layers.append({
                "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
                "size": compressed_layer.stat().st_size,
                "digest": digest,
            })
    require(found_layers == set(layer_names), "image archive is missing a declared layer")

    manifest = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
        "config": {
            "mediaType": "application/vnd.docker.container.image.v1+json",
            "size": len(config_bytes),
            "digest": image_id,
        },
        "layers": layers,
    }
    raw_manifest = json.dumps(manifest, separators=(",", ":")).encode()
    manifest_path = destination / "manifest.json"
    manifest_path.write_bytes(raw_manifest)
    return {
        "path": manifest_path,
        "digest": "sha256:" + hashlib.sha256(raw_manifest).hexdigest(),
        "manifest": manifest,
        "blobs": blobs,
    }


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, new_url):
        return None


class RegistryClient:
    """Minimal Registry V2 client for digest-only platform publication."""

    def __init__(self, repository, username, password):
        registry, name = repository.split("/", 1)
        settings = REGISTRY_CONFIG[registry]
        self.repository = name
        self.registry_host = settings["registry_host"]
        self.token_url = settings["token_url"]
        self.service = settings["service"]
        self.upload_hosts = settings["upload_hosts"]
        self.username = username
        self.password = password
        self.token = None

    def _get_token(self):
        query = urllib.parse.urlencode({
            "service": self.service,
            "scope": f"repository:{self.repository}:pull,push",
        })
        credentials = base64.b64encode(f"{self.username}:{self.password}".encode()).decode()
        request = urllib.request.Request(
            f"{self.token_url}?{query}",
            headers={"Accept": "application/json", "Authorization": f"Basic {credentials}"},
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
        try:
            with opener.open(request, timeout=60) as response:
                payload = json.loads(response.read(4 * 1024 * 1024))
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"registry token request failed for {self.repository}: {type(exc).__name__}") from None
        require(isinstance(payload, dict), "registry token response is invalid")
        token = payload.get("token") or payload.get("access_token")
        require(isinstance(token, str) and token and not any(char.isspace() for char in token),
                "registry token response is invalid")
        self.token = token
        return token

    def _request(self, method, url, expected, *, body=None, body_path=None, content_type=None):
        require(body is None or body_path is None, "registry request body is ambiguous")
        for attempt in range(2):
            headers = {"Authorization": f"Bearer {self.token or self._get_token()}"}
            if body is not None:
                headers["Content-Length"] = str(len(body))
            if body_path is not None:
                headers["Content-Length"] = str(body_path.stat().st_size)
            if content_type:
                headers["Content-Type"] = content_type
            status, response_headers = self._send(method, url, headers, body=body, body_path=body_path)
            if status != 401:
                require(status in expected,
                        f"registry {method} failed for {self.repository}: HTTP {status}")
                return status, response_headers
            self.token = None
            if attempt == 1:
                raise RuntimeError(f"registry authorization failed for {self.repository}")
        raise RuntimeError("registry request retry failed")

    @staticmethod
    def _send(method, url, headers, *, body=None, body_path=None):
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == "https" and parsed.hostname, "registry URL must use HTTPS")
        target = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
        connection = http.client.HTTPSConnection(parsed.hostname, parsed.port, timeout=120)
        try:
            connection.putrequest(method, target)
            for key, value in headers.items():
                connection.putheader(key, value)
            connection.endheaders()
            if body is not None:
                connection.send(body)
            elif body_path is not None:
                with body_path.open("rb") as source:
                    while chunk := source.read(BLOB_CHUNK_SIZE):
                        connection.send(chunk)
            response = connection.getresponse()
            response_headers = {key.lower(): value for key, value in response.getheaders()}
            response.read(4 * 1024 * 1024 + 1)
            return response.status, response_headers
        finally:
            connection.close()

    def _upload_url(self, location):
        upload_url = urllib.parse.urljoin(f"https://{self.registry_host}", location)
        parsed = urllib.parse.urlsplit(upload_url)
        require(parsed.scheme == "https" and parsed.hostname in self.upload_hosts
                and not parsed.username and not parsed.password,
                "registry upload location is not an allowed registry host")
        return upload_url

    def _path(self, suffix):
        return f"https://{self.registry_host}/v2/{self.repository}/{suffix}"

    def _upload_blob(self, digest, path):
        blob_url = self._path(f"blobs/{digest}")
        status, _ = self._request("HEAD", blob_url, (200, 404))
        if status == 200:
            return
        _, headers = self._request("POST", self._path("blobs/uploads/"), (202,))
        location = headers.get("location")
        require(location, "registry did not return a blob upload location")
        upload_url = self._upload_url(location)
        parsed = urllib.parse.urlsplit(upload_url)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        query["digest"] = [digest]
        upload_url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path,
                                               urllib.parse.urlencode(query, doseq=True), ""))
        self._request("PUT", upload_url, (201, 202), body_path=path,
                      content_type="application/octet-stream")

    def publish_platform_manifest(self, prepared):
        raw_manifest = prepared["path"].read_bytes()
        digest = prepared["digest"]
        require("sha256:" + hashlib.sha256(raw_manifest).hexdigest() == digest,
                "prepared platform manifest digest changed")
        manifest = prepared["manifest"]
        descriptors = [manifest["config"], *manifest.get("layers", [])]
        for descriptor in descriptors:
            blob_digest = descriptor["digest"]
            blob_path = prepared["blobs"].get(blob_digest)
            require(blob_path is not None and blob_path.is_file(),
                    f"missing prepared image blob: {blob_digest}")
            self._upload_blob(blob_digest, blob_path)
        self._request("PUT", self._path(f"manifests/{digest}"), (201,), body=raw_manifest,
                      content_type=manifest["mediaType"])
        return digest


def create_registry_client(repository):
    registry = repository.split("/", 1)[0]
    credentials = {
        "ghcr.io": (os.environ.get("GHCR_USERNAME"), os.environ.get("GHCR_TOKEN")),
        "docker.io": (os.environ.get("DOCKERHUB_USERNAME"), os.environ.get("DOCKERHUB_TOKEN")),
    }[registry]
    require(all(isinstance(value, str) and value for value in credentials),
            f"credentials are not configured for {registry}")
    return RegistryClient(repository, *credentials)
