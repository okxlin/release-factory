#!/usr/bin/env python3
"""Resolve immutable OpenClaw inputs and decide whether a GHCR build is fresh."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")
SHA = re.compile(r"[a-f0-9]{40}")
ACCEPT = ", ".join(("application/vnd.oci.image.index.v1+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.v2+json"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def http(url, headers):
    request = urllib.request.Request(url, headers={"User-Agent": "release-factory", **headers})
    try:
        response = urllib.request.build_opener(NoRedirect()).open(request, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read(4 * 1024 * 1024 + 1)
        if len(body) > 4 * 1024 * 1024:
            raise ValueError("remote metadata exceeded size limit")
        return response.status, response.headers, body


def github(path):
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    status, _, body = http("https://api.github.com/repos/openclaw/openclaw/" + path, headers)
    if status != 200:
        raise ValueError(f"GitHub metadata lookup failed: HTTP {status}")
    return json.loads(body)


class Registry:
    def __init__(self, repository):
        if not re.fullmatch(r"ghcr\.io/[a-z0-9][a-z0-9-]*/openclaw-sandbox", repository):
            raise ValueError("unexpected OpenClaw registry repository")
        self.repository = repository.removeprefix("ghcr.io/")
        self.token = None

    def authorize(self, challenge):
        # https://distribution.github.io/distribution/spec/auth/token/
        scheme, _, fields = challenge.partition(" ")
        values = urllib.request.parse_keqv_list(urllib.request.parse_http_list(fields))
        scope = "repository:" + self.repository + ":pull"
        if (scheme.lower() != "bearer" or values.get("realm") != "https://ghcr.io/token"
                or values.get("service") != "ghcr.io" or values.get("scope") != scope):
            raise ValueError("unexpected registry authentication challenge")
        headers = {}
        credential = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if credential:
            actor = os.environ.get("GITHUB_ACTOR", self.repository.split("/")[0])
            headers["Authorization"] = "Basic " + base64.b64encode((actor + ":" + credential).encode()).decode()
        query = urllib.parse.urlencode({"service": "ghcr.io", "scope": scope})
        status, _, body = http("https://ghcr.io/token?" + query, headers)
        if status != 200:
            raise ValueError(f"registry token request failed: HTTP {status}")
        data = json.loads(body)
        self.token = data.get("token") or data.get("access_token")
        if not isinstance(self.token, str) or not self.token or any(c.isspace() for c in self.token):
            raise ValueError("invalid registry access token")

    def get(self, kind, reference, *, missing_ok=False):
        if kind not in ("manifests", "blobs") or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", reference):
            raise ValueError("invalid registry metadata reference")
        url = f"https://ghcr.io/v2/{self.repository}/{kind}/{reference}"
        headers = {"Accept": ACCEPT}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        status, response_headers, body = http(url, headers)
        if status == 401 and not self.token:
            self.authorize(response_headers.get("www-authenticate", ""))
            headers["Authorization"] = "Bearer " + self.token
            status, response_headers, body = http(url, headers)
        if kind == "blobs" and status in (302, 307):
            target = response_headers.get("location", "")
            parsed = urllib.parse.urlsplit(target)
            if (parsed.scheme != "https" or not parsed.hostname
                    or not parsed.hostname.endswith(".githubusercontent.com")
                    or parsed.username or parsed.password or parsed.port not in (None, 443)):
                raise ValueError("unexpected registry blob redirect")
            # GitHub's signed download URL must never receive the registry token.
            status, _, body = http(target, {})
        if status == 404 and missing_ok:
            return None
        if status != 200:
            raise ValueError(f"registry {kind} lookup failed: HTTP {status}")
        if reference.startswith("sha256:") and "sha256:" + hashlib.sha256(body).hexdigest() != reference:
            raise ValueError("registry metadata digest mismatch")
        return json.loads(body)

    def labels(self, tag):
        manifest = self.get("manifests", tag, missing_ok=True)
        if manifest is None:
            return None
        if "manifests" in manifest:
            candidates = [item for item in manifest["manifests"]
                          if item.get("platform", {}).get("os") == "linux"
                          and item["platform"].get("architecture") == "amd64"]
            if len(candidates) != 1:
                raise ValueError("expected one amd64 OpenClaw manifest")
            manifest = self.get("manifests", candidates[0]["digest"])
        config_digest = manifest.get("config", {}).get("digest", "")
        if not DIGEST.fullmatch(config_digest):
            raise ValueError("invalid registry config digest")
        config = self.get("blobs", config_digest)
        if config.get("os") != "linux" or config.get("architecture") != "amd64":
            raise ValueError("unexpected OpenClaw image platform")
        return config.get("config", {}).get("Labels") or {}


def pin_image(reference):
    result = subprocess.run(["docker", "buildx", "imagetools", "inspect", reference,
                             "--format", "{{json .Manifest}}"], capture_output=True,
                            text=True, check=True, timeout=120)
    digest = json.loads(result.stdout)["digest"]
    if not DIGEST.fullmatch(digest):
        raise ValueError("registry returned an invalid base digest")
    return reference.split("@", 1)[0] + "@" + digest


def needs_build(labels, upstream_sha, recipe_digest, now, max_age_days):
    if labels is None:
        return True, "release tag is absent"
    for key, expected in (("io.release-factory.upstream.revision", upstream_sha),
                          ("io.release-factory.recipe", recipe_digest)):
        if labels.get(key) != expected:
            return True, "source, components or recipe changed"
    try:
        created = dt.datetime.fromisoformat(labels["io.release-factory.build.created"])
        age = now - created
    except (KeyError, TypeError, ValueError):
        return True, "build timestamp is missing or invalid"
    if not dt.timedelta(0) <= age < dt.timedelta(days=max_age_days):
        return True, "security refresh is due"
    return False, "same immutable inputs and build is less than seven days old"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="ghcr.io/okxlin/openclaw-sandbox")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    components = json.loads((ROOT / "openclaw-builder/configs/components.json").read_text())
    if components.get("schema_version") != 1 or components.get("max_build_age_days") != 7:
        raise ValueError("invalid OpenClaw component policy")
    tag = github("releases/latest")["tag_name"]
    if not re.fullmatch(r"v?[0-9][A-Za-z0-9._-]{0,118}", tag):
        raise ValueError("invalid upstream release tag")
    upstream_sha = github("commits/" + urllib.parse.quote(tag, safe=""))["sha"]
    if not SHA.fullmatch(upstream_sha):
        raise ValueError("invalid upstream commit")
    build_args = dict(components["build_args"])
    for key in ("OPENCLAW_NODE_BOOKWORM_IMAGE", "OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE"):
        build_args[key] = pin_image(build_args[key])
    build_args["OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST"] = build_args["OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE"].split("@")[1]
    recipe = hashlib.sha256(json.dumps(build_args, sort_keys=True).encode())
    paths = sorted([*ROOT.joinpath("openclaw-builder").rglob("*"),
                    *ROOT.joinpath("scripts").glob("*openclaw*"),
                    ROOT / "scripts/trivy-image-gate.sh", ROOT / "scripts/evaluate-trivy-policy.py",
                    ROOT / "scripts/publish-tested-image.py", ROOT / ".github/workflows/openclaw-upstream-docker.yml"])
    for path in paths:
        if path.is_file():
            recipe.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes() + b"\0")
    digest = "sha256:" + recipe.hexdigest()
    now = dt.datetime.now(dt.UTC)
    labels = Registry(args.repository).labels(tag + "-sandbox")
    rebuild, reason = needs_build(labels, upstream_sha, digest, now, components["max_build_age_days"])
    if args.force:
        rebuild, reason = True, "forced verification/rebuild"
    build_args.update(SECURITY_REFRESH=now.strftime("%G-%V"), OPENCLAW_INSTALL_DOCKER_CLI="1",
                      OPENCLAW_IMAGE_APT_PACKAGES="libgnutls30", OPENCLAW_PREFER_PNPM="1",
                      GIT_COMMIT=upstream_sha, OPENCLAW_DOCKER_BUILD_VERSION=tag.removeprefix("v"))
    result = {"skip": str(not rebuild).lower(), "reason": reason, "upstream_tag": tag,
              "upstream_sha": upstream_sha, "recipe_digest": digest, "created": now.isoformat(),
              "image_tag": tag + "-sandbox", "build_args": build_args}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    if args.github_output:
        with args.github_output.open("a") as output:
            for key, value in result.items():
                if key != "build_args":
                    output.write(f"{key}={value}\n")
            output.write("build_args<<OPENCLAW_BUILD_ARGS\n")
            for key, value in build_args.items():
                if not re.fullmatch(r"[A-Z_]+", key) or not isinstance(value, str) or any(c in value for c in "\r\n"):
                    raise ValueError("invalid build argument")
                output.write(f"{key}={value}\n")
            output.write("OPENCLAW_BUILD_ARGS\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"ERROR: OpenClaw input resolution failed: {error}", file=sys.stderr)
        sys.exit(1)
