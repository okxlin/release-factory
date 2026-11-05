#!/usr/bin/env python3
"""Refresh component pins from the existing upstream policy, without running downloads."""

import argparse
import copy
import hashlib
import importlib.util
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("checker", HERE / "check-component-updates.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def require(condition, message):
    if not condition:
        raise ValueError(message)


class ArtifactRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        source = urllib.parse.urlsplit(request.full_url)
        target = urllib.parse.urlsplit(urllib.parse.urljoin(request.full_url, newurl))
        require(target.scheme == "https" and not target.username and not target.password
                and target.port in (None, 443), "unsafe artifact redirect")
        require(target.hostname == source.hostname or
                (source.hostname == "github.com" and target.hostname in
                 {"release-assets.githubusercontent.com", "codeload.github.com"}),
                "unexpected artifact redirect host")
        return super().redirect_request(request, fp, code, msg, headers, target.geturl())


def download(url, limit=128 * 1024 * 1024):
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == "https" and parsed.hostname in {
        "github.com", "codeload.github.com", "raw.githubusercontent.com", "registry.npmjs.org",
    } and not parsed.username and not parsed.password and parsed.port in (None, 443),
        "unexpected artifact URL")
    # No GitHub credential is sent to archive, npm, raw-content or CDN endpoints.
    with urllib.request.build_opener(ArtifactRedirect()).open(url, timeout=120) as response:
        data = response.read(limit + 1)
    require(len(data) <= limit, "artifact exceeds size limit")
    return data


def image_reference(image, tag):
    require(image in {"node", "python", "golang", "caddy"}
            and re.fullmatch(r"[0-9][A-Za-z0-9_.-]+", tag), "unexpected base image")
    query = urllib.parse.urlencode({"service": "registry.docker.io", "scope": f"repository:library/{image}:pull"})
    opener = urllib.request.build_opener(checker.SameOriginHTTPSRedirectHandler())
    with opener.open("https://auth.docker.io/token?" + query, timeout=30) as response:
        token = json.load(response)["token"]
    request = urllib.request.Request(f"https://registry-1.docker.io/v2/library/{image}/manifests/{tag}", headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json",
    })
    with opener.open(request, timeout=30) as response:
        raw = response.read(4 * 1024 * 1024 + 1)
        advertised = response.headers.get("Docker-Content-Digest")
    require(len(raw) <= 4 * 1024 * 1024, "image index exceeds size limit")
    digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    require(advertised == digest, "registry image digest mismatch")
    platforms = {entry.get("platform", {}).get("architecture") for entry in json.loads(raw).get("manifests", [])
                 if entry.get("platform", {}).get("os") == "linux"}
    require({"amd64", "arm64"} <= platforms, "base image must support both native architectures")
    return f"{image}:{tag}@{digest}"


def source_metadata(version, client, fetch):
    require(checker.SEMVER_RE.fullmatch(version), "invalid DSH version")
    repo = "deepseek-ai/deepseek-harness"
    ref = "dsh-v" + version
    commit = client.get_json("dsh-commit.json", f"https://api.github.com/repos/{repo}/commits/{ref}")["sha"]
    require(re.fullmatch(r"[a-f0-9]{40}", commit), "invalid DSH commit")
    url = f"https://codeload.github.com/{repo}/tar.gz/{commit}"
    data = fetch(url)
    # Inspect only two manifests; never extract or execute the upstream archive.
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for suffix in ["package.json", "apps/cli/package.json"]:
            members = [m for m in archive if m.name.partition("/")[2] == suffix]
            require(len(members) == 1 and members[0].isfile() and members[0].size < 1024 * 1024,
                    "invalid DSH package manifest")
            require(json.load(archive.extractfile(members[0]))["version"] == version,
                    "DSH archive version does not match release")
    return dict(version=version, repository=repo, ref=ref, commit=commit,
                archiveSha256=hashlib.sha256(data).hexdigest(), archiveUrl=url)


# Only the artifact locations already used by the Dockerfile are refreshable.
ARCHIVES = {
    "CADDY_VERSION": ("CADDY_SOURCE_ARCHIVE_SHA256", "https://codeload.github.com/caddyserver/caddy/tar.gz/refs/tags/v{}"),
    "GO_AUTHCRUNCH_VERSION": ("GO_AUTHCRUNCH_SOURCE_SHA256", "https://codeload.github.com/greenpau/go-authcrunch/tar.gz/refs/tags/v{}"),
    "DOCKER_VERSION": ("DOCKER_ARCHIVE_SHA256", "https://codeload.github.com/docker/cli/tar.gz/refs/tags/v{}"),
    "DOCKER_COMPOSE_VERSION": ("DOCKER_COMPOSE_ARCHIVE_SHA256", "https://codeload.github.com/docker/compose/tar.gz/refs/tags/v{}"),
    "DOCKER_BUILDX_VERSION": ("DOCKER_BUILDX_ARCHIVE_SHA256", "https://codeload.github.com/docker/buildx/tar.gz/refs/tags/v{}"),
    "ACTIONLINT_VERSION": ("ACTIONLINT_SOURCE_SHA256", "https://codeload.github.com/rhysd/actionlint/tar.gz/refs/tags/v{}"),
    "NPM_VERSION": ("NPM_ARCHIVE_SHA256", "https://registry.npmjs.org/npm/-/npm-{}.tgz"),
    "PNPM_VERSION": ("PNPM_ARCHIVE_SHA256", "https://registry.npmjs.org/pnpm/-/pnpm-{}.tgz"),
}
LICENSES = {
    "CADDY_VERSION": [("CADDY_LICENSE_SHA256", "caddyserver/caddy/v{}/LICENSE")],
    "CADDY_SECURITY_VERSION": [("CADDY_SECURITY_LICENSE_SHA256", "greenpau/caddy-security/v{}/LICENSE")],
    "GO_AUTHCRUNCH_VERSION": [("GO_AUTHCRUNCH_LICENSE_SHA256", "greenpau/go-authcrunch/v{}/LICENSE")],
    "CEL_GO_VERSION": [("CEL_GO_LICENSE_SHA256", "cel-expr/cel-go/v{}/LICENSE")],
    "DOCKER_VERSION": [("DOCKER_CLI_LICENSE_SHA256", "docker/cli/v{}/LICENSE")],
    "DOCKER_COMPOSE_VERSION": [("DOCKER_COMPOSE_LICENSE_SHA256", "docker/compose/v{}/LICENSE")],
    "DOCKER_BUILDX_VERSION": [("DOCKER_BUILDX_LICENSE_SHA256", "docker/buildx/v{}/LICENSE")],
    "YQ_VERSION": [("YQ_LICENSE_SHA256", "mikefarah/yq/v{}/LICENSE")],
    "RUFF_VERSION": [("RUFF_LICENSE_SHA256", "astral-sh/ruff/{}/LICENSE")],
    "UV_VERSION": [("UV_LICENSE_MIT_SHA256", "astral-sh/uv/{}/LICENSE-MIT"),
                   ("UV_LICENSE_APACHE_SHA256", "astral-sh/uv/{}/LICENSE-APACHE")],
}
IMAGES = {"NODE_VERSION": ("NODE_IMAGE", "node", "-trixie-slim"),
          "PYTHON_VERSION": ("PYTHON_IMAGE", "python", "-slim-trixie"),
          "GO_VERSION": ("GO_IMAGE", "golang", "-trixie"),
          "CADDY_VERSION": ("CADDY_IMAGE", "caddy", "-builder-alpine")}


def refresh(lock, source, policy, client, fetch=download, resolve_image=image_reference):
    result, resolved_source = copy.deepcopy(lock), copy.deepcopy(source)
    pins = result["build_args"]
    changes = []
    for component in policy:
        key = component.get("pin")
        if not key:
            require(component["source"]["type"] == "node_release_line", "unknown pin selector")
            key = "NODE_VERSION"
        current = source["version"] if key == "DSH_SOURCE_VERSION" else pins[key]
        version, url = checker.upstream_version(component, client)
        require(checker.SEMVER_RE.fullmatch(version), "invalid upstream version")
        if checker.semver_key(version) <= checker.semver_key(current):
            continue
        changes.append(f"- {component['name']}: `{current}` → `{version}` ([source]({url}))")
        if key == "DSH_SOURCE_VERSION":
            resolved_source = source_metadata(version, client, fetch)
            continue
        pins[key] = version
        for digest_key, location in LICENSES.get(key, []):
            digest = hashlib.sha256(fetch("https://raw.githubusercontent.com/" + location.format(version))).hexdigest()
            require(digest == pins[digest_key], f"{component['name']} license changed; review required")
        if key in ARCHIVES:
            digest_key, location = ARCHIVES[key]
            pins[digest_key] = hashlib.sha256(fetch(location.format(version))).hexdigest()
        if key in {"RUFF_VERSION", "UV_VERSION", "YQ_VERSION"}:
            name = key.removesuffix("_VERSION").lower()
            for arch, triple in [("amd64", "x86_64"), ("arm64", "aarch64")]:
                location = (f"https://github.com/mikefarah/yq/releases/download/v{version}/yq_linux_{arch}" if name == "yq"
                            else f"https://github.com/astral-sh/{name}/releases/download/{version}/{name}-{triple}-unknown-linux-gnu.tar.gz")
                pins[f"{name.upper()}_SHA256_{arch.upper()}"] = hashlib.sha256(fetch(location)).hexdigest()
    # Refresh rebuilt official base images even when their version tag is unchanged.
    for version_key, (image_key, image, suffix) in IMAGES.items():
        # xcaddy builds the checksum-locked source; the official builder image
        # can lag a new patch release. Keep its release line and immutable digest.
        image_version = pins[version_key].rsplit(".", 1)[0] if image == "caddy" else pins[version_key]
        reference = resolve_image(image, image_version + suffix)
        if reference != pins[image_key]:
            changes.append(f"- {image_key}: `{pins[image_key]}` → `{reference}`")
            pins[image_key] = reference
    return result, resolved_source, changes


def refresh_python_requirements(requirements, version):
    # pip's target-version option does not change all environment markers.
    require(sys.version_info[:2] == (3, 12) and sys.platform == "linux",
            "resolve the Python lock on Linux with Python 3.12")
    pins = {}
    for line in requirements.splitlines():
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9.!+]+) --hash=sha256:([a-f0-9]{64})", line)
        require(match, "invalid hash-locked Python requirement")
        name, current, _ = match.groups()
        key = re.sub(r"[-_.]+", "-", name).lower()
        require(key not in pins, "duplicate Python requirement")
        pins[key] = (name, version if key == "pytest" else current)
    require("pytest" in pins, "Python lock must include pytest")
    with tempfile.TemporaryDirectory(prefix="dsh-python-lock-") as temporary:
        report = Path(temporary) / "report.json"
        # https://github.com/pypa/pip/blob/24.0/docs/html/reference/installation-report.md
        # Resolve existing transitive pins without installing packages or running source builds.
        subprocess.run([
            sys.executable, "-m", "pip", "--isolated", "install", "--dry-run", "--ignore-installed",
            "--only-binary=:all:", "--python-version", "3.12", "--index-url", "https://pypi.org/simple",
            "--disable-pip-version-check", "--no-cache-dir", "--quiet", "--report", str(report),
            *[f"{name}=={value}" for name, value in pins.values()],
        ], check=True, capture_output=True, text=True, timeout=120)
        resolved = json.loads(report.read_text(encoding="utf-8"))
    require(resolved.get("version") == "1", "unsupported pip installation report version")
    require(resolved["environment"]["python_version"] == "3.12"
            and resolved["environment"]["sys_platform"] == "linux", "unexpected Python resolution environment")
    hashes = {}
    for item in resolved["install"]:
        metadata = item["metadata"]
        key = re.sub(r"[-_.]+", "-", metadata["name"]).lower()
        require(key in pins and key not in hashes and metadata["version"] == pins[key][1],
                "Python dependency set changed; review required")
        artifact = item["download_info"]
        url = urllib.parse.urlsplit(artifact["url"])
        require(url.scheme == "https" and url.hostname == "files.pythonhosted.org"
                and not url.username and not url.password and url.port in (None, 443)
                and url.path.endswith("-py3-none-any.whl") and not item.get("is_yanked"),
                "Python lock requires non-yanked, architecture-independent PyPI wheels")
        digest = artifact["archive_info"]["hashes"].get("sha256", "")
        require(re.fullmatch(r"[a-f0-9]{64}", digest), "Python wheel has no SHA-256 digest")
        hashes[key] = digest
    require(hashes.keys() == pins.keys(), "incomplete Python dependency resolution")
    return "".join(f"{name}=={value} --hash=sha256:{hashes[key]}\n"
                   for key, (name, value) in pins.items())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image-dir", type=Path, default=HERE.parent / "image")
    parser.add_argument("--apply", action="store_true", help="write the three generated input files after all sources validate")
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    root = args.image_dir.resolve(strict=True)
    paths = [root / name for name in ["components.lock.json", "dsh-source.json", "python-requirements.lock"]]
    for path in paths:
        require(path.is_file() and not path.is_symlink(), "pin file must be a regular file")
    original = [json.loads(p.read_text(encoding="utf-8")) for p in paths[:2]]
    policy = checker.load_policy(HERE.parent / "configs/component-update-policy.json")
    lock, source, changes = refresh(*original, policy, checker.SourceClient())
    requirements = paths[2].read_text(encoding="utf-8")
    pytest = re.findall(r"^pytest==([^ ]+) --hash=sha256:[a-f0-9]{64}$", requirements, re.MULTILINE)
    require(len(pytest) == 1, "Python lock must pin exactly one pytest version with a SHA-256 digest")
    if pytest[0] != lock["build_args"]["PYTEST_VERSION"]:
        requirements = refresh_python_requirements(requirements, lock["build_args"]["PYTEST_VERSION"])
        changes.append("- python-requirements.lock: resolve pytest and verify its existing dependency closure")
    summary = "## DeepSeek Harness component update\n\n" + ("\n".join(changes) if changes else "All component pins are current.") + "\n"
    print(summary)
    if args.summary:
        args.summary.write_text(summary, encoding="utf-8")
    if args.apply and changes:
        # All network, archive, license and platform checks finish before any write.
        for path, content in zip(paths, [json.dumps(lock, indent=2) + "\n", json.dumps(source, indent=2) + "\n", requirements]):
            temporary = path.with_suffix(path.suffix + ".update-tmp")
            with temporary.open("x", encoding="utf-8") as output:
                output.write(content)
            temporary.replace(path)
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(f"changed={str(bool(changes)).lower()}\n")


if __name__ == "__main__":
    main()
