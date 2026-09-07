#!/usr/bin/env python3
"""Resolve reproducible, current proxy-core build inputs for CI."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections.abc import Iterable
from pathlib import Path
from typing import Any

SEMVER_RE = re.compile(r"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
RELEASE_SEMVER_RE = re.compile(
    r"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
GO_VERSION_RE = re.compile(r"^(?:go)?(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?$")
ARG_RE = re.compile(r"^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)=([^\s#]*)\s*(?:#.*)?$")
COMMIT_RE = re.compile(r"^[0-9a-fA-F]{40}$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
POLICY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
MODULE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)+$")
COMPONENT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ARG_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
BUILD_ARG_VALUE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:-]*$")


class ResolveError(RuntimeError):
    """A source, policy, or input-validation error that should fail the build."""


class SameOriginHTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Allow redirects only to an explicitly approved HTTPS host set."""

    def __init__(self, allowed_hosts: set[str]) -> None:
        super().__init__()
        self.allowed_hosts = allowed_hosts

    def redirect_request(
        self,
        request: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        new_url: str,
    ) -> urllib.request.Request | None:
        absolute_url = urllib.parse.urljoin(request.full_url, new_url)
        redirected = urllib.parse.urlparse(absolute_url)
        if (
            redirected.scheme != "https"
            or redirected.hostname not in self.allowed_hosts
            or redirected.username is not None
            or redirected.password is not None
        ):
            raise ResolveError(f"source redirected outside approved HTTPS hosts: {absolute_url}")
        return super().redirect_request(request, fp, code, msg, headers, absolute_url)


class SourceClient:
    """Fetch bounded metadata and source archives from approved HTTPS origins."""

    MAX_METADATA_BYTES = 16 * 1024 * 1024
    MAX_ARCHIVE_BYTES = 128 * 1024 * 1024

    def __init__(self, fixture_dir: Path | None = None) -> None:
        self.fixture_dir = fixture_dir

    @staticmethod
    def _validate_url(url: str, allowed_hosts: set[str]) -> urllib.parse.ParseResult:
        parsed = urllib.parse.urlparse(url)
        if (
            parsed.scheme != "https"
            or parsed.hostname not in allowed_hosts
            or parsed.username is not None
            or parsed.password is not None
            or not parsed.path
        ):
            raise ResolveError(f"source must be an approved absolute HTTPS URL: {url}")
        return parsed

    def _fixture_bytes(self, fixture: str, max_bytes: int) -> bytes:
        if self.fixture_dir is None:
            raise AssertionError("fixture lookup requested without a fixture directory")
        fixture_path = self.fixture_dir / fixture
        try:
            payload = fixture_path.read_bytes()
        except OSError as exc:
            raise ResolveError(f"cannot read fixture {fixture_path}: {exc}") from exc
        if len(payload) > max_bytes:
            raise ResolveError(f"fixture {fixture_path} exceeds {max_bytes} bytes")
        return payload

    def get_bytes(
        self,
        fixture: str,
        url: str,
        *,
        allowed_hosts: set[str],
        max_bytes: int,
    ) -> bytes:
        self._validate_url(url, allowed_hosts)
        if self.fixture_dir is not None:
            return self._fixture_bytes(fixture, max_bytes)

        headers = {"User-Agent": "release-factory-proxy-core-resolver"}
        if "api.github.com" in allowed_hosts:
            headers["Accept"] = "application/vnd.github+json"
            headers["X-GitHub-Api-Version"] = "2022-11-28"
            github_token = os.environ.get("GITHUB_TOKEN", "")
            if github_token:
                headers["Authorization"] = f"Bearer {github_token}"

        request = urllib.request.Request(url, headers=headers)
        opener = urllib.request.build_opener(
            SameOriginHTTPSRedirectHandler(allowed_hosts)
        )
        try:
            with opener.open(request, timeout=60) as response:
                final_url = urllib.parse.urlparse(response.geturl())
                if (
                    final_url.scheme != "https"
                    or final_url.hostname not in allowed_hosts
                    or final_url.username is not None
                    or final_url.password is not None
                ):
                    raise ResolveError(
                        f"source response ended outside approved HTTPS hosts: {response.geturl()}"
                    )
                content_length = response.headers.get("Content-Length")
                if content_length:
                    try:
                        if int(content_length) > max_bytes:
                            raise ResolveError(
                                f"source response exceeds {max_bytes} bytes: {url}"
                            )
                    except ValueError as exc:
                        raise ResolveError(
                            f"source response has an invalid Content-Length: {url}"
                        ) from exc
                payload = response.read(max_bytes + 1)
                if len(payload) > max_bytes:
                    raise ResolveError(f"source response exceeds {max_bytes} bytes: {url}")
                return payload
        except ResolveError:
            raise
        except (OSError, TimeoutError) as exc:
            raise ResolveError(f"cannot fetch {url}: {exc}") from exc

    def get_text(
        self,
        fixture: str,
        url: str,
        *,
        allowed_hosts: set[str],
    ) -> str:
        try:
            return self.get_bytes(
                fixture,
                url,
                allowed_hosts=allowed_hosts,
                max_bytes=self.MAX_METADATA_BYTES,
            ).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ResolveError(f"source response is not UTF-8: {url}") from exc

    def get_json(
        self,
        fixture: str,
        url: str,
        *,
        allowed_hosts: set[str],
    ) -> Any:
        try:
            return json.loads(
                self.get_text(fixture, url, allowed_hosts=allowed_hosts)
            )
        except json.JSONDecodeError as exc:
            raise ResolveError(f"invalid JSON from {url}: {exc}") from exc


def semver_key(version: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(version)
    if not match:
        raise ResolveError(f"unsupported stable semantic version: {version}")
    return tuple(int(part) for part in match.groups())


def normalize_stable_version(version: str) -> str:
    return ".".join(str(part) for part in semver_key(version))


def latest_stable(versions: Iterable[str]) -> str:
    candidates = [
        normalize_stable_version(version)
        for version in versions
        if isinstance(version, str) and SEMVER_RE.fullmatch(version)
    ]
    if not candidates:
        raise ResolveError("source returned no stable semantic versions")
    return max(candidates, key=semver_key)


def release_semver_key(version: str) -> tuple[int, int, int, tuple[Any, ...]]:
    match = RELEASE_SEMVER_RE.fullmatch(version)
    if not match:
        raise ResolveError(f"unsupported release semantic version: {version}")
    core = tuple(int(part) for part in match.groups()[:3])
    prerelease = match.group(4)
    if prerelease is None:
        prerelease_key: tuple[Any, ...] = (1,)
    else:
        identifiers: list[tuple[int, int | str]] = []
        for identifier in prerelease.split("."):
            if identifier.isdigit():
                identifiers.append((0, int(identifier)))
            else:
                identifiers.append((1, identifier))
        prerelease_key = (0, tuple(identifiers))
    return (*core, prerelease_key)


def normalize_release_version(version: str) -> str:
    match = RELEASE_SEMVER_RE.fullmatch(version)
    if not match:
        raise ResolveError(f"unsupported release semantic version: {version}")
    normalized = ".".join(match.group(index) for index in range(1, 4))
    if match.group(4):
        normalized += f"-{match.group(4)}"
    return normalized


def parse_go_version(version: str) -> tuple[int, int, int]:
    match = GO_VERSION_RE.fullmatch(version)
    if not match:
        raise ResolveError(f"unsupported Go version: {version}")
    return tuple(int(part or 0) for part in match.groups())


def read_dockerfile_arg(dockerfile: Path, arg_name: str) -> str:
    try:
        dockerfile_text = dockerfile.read_text(encoding="utf-8")
    except OSError as exc:
        raise ResolveError(f"cannot read Dockerfile {dockerfile}: {exc}") from exc
    values: list[str] = []
    for line in dockerfile_text.splitlines():
        match = ARG_RE.fullmatch(line)
        if match and match.group(1) == arg_name:
            values.append(match.group(2))
    if len(set(values)) != 1:
        raise ResolveError(
            f"Dockerfile must define exactly one {arg_name} ARG, got {values}"
        )
    return values[0]


def resolve_git_tag(client: SourceClient, repository: str, tag: str) -> str:
    encoded_tag = urllib.parse.quote(tag, safe="")
    ref_url = f"https://api.github.com/repos/{repository}/git/ref/tags/{encoded_tag}"
    ref_data = client.get_json(
        f"github-ref-{repository.replace('/', '-')}-{tag}.json",
        ref_url,
        allowed_hosts={"api.github.com"},
    )
    if not isinstance(ref_data, dict) or not isinstance(ref_data.get("object"), dict):
        raise ResolveError(f"Git tag reference for {repository}:{tag} is malformed")
    target = ref_data["object"]

    for _ in range(4):
        object_type = target.get("type")
        object_sha = target.get("sha")
        if object_type == "commit" and isinstance(object_sha, str) and COMMIT_RE.fullmatch(object_sha):
            return object_sha.lower()
        if object_type != "tag" or not isinstance(object_sha, str) or not COMMIT_RE.fullmatch(object_sha):
            raise ResolveError(f"Git tag reference for {repository}:{tag} does not resolve to a commit")
        tag_url = f"https://api.github.com/repos/{repository}/git/tags/{object_sha}"
        tag_data = client.get_json(
            f"github-tag-{repository.replace('/', '-')}-{object_sha}.json",
            tag_url,
            allowed_hosts={"api.github.com"},
        )
        if not isinstance(tag_data, dict) or not isinstance(tag_data.get("object"), dict):
            raise ResolveError(f"annotated Git tag for {repository}:{tag} is malformed")
        target = tag_data["object"]
    raise ResolveError(f"Git tag for {repository}:{tag} is nested too deeply")


def latest_release(
    client: SourceClient, component: dict[str, Any]
) -> tuple[str, str]:
    repository = component["repository"]
    # GitHub release bodies/assets metadata can make a 100-item response very
    # large. Recent releases contain the current version sequence for these
    # projects, while the bounded response keeps the resolver predictable.
    url = f"https://api.github.com/repos/{repository}/releases?per_page=30"
    data = client.get_json(
        f"github-releases-{repository.replace('/', '-')}.json",
        url,
        allowed_hosts={"api.github.com"},
    )
    if not isinstance(data, list):
        raise ResolveError(f"release list for {repository} is malformed")
    include_prereleases = component.get("include_prereleases", False)
    candidates: list[tuple[tuple[int, int, int, tuple[Any, ...]], str]] = []
    for release in data:
        if not isinstance(release, dict) or release.get("draft") is True:
            continue
        if release.get("prerelease") is True and not include_prereleases:
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or not RELEASE_SEMVER_RE.fullmatch(tag):
            continue
        candidates.append((release_semver_key(tag), tag))
    if not candidates:
        channel = "including prereleases" if include_prereleases else "stable"
        raise ResolveError(f"release list for {repository} has no {channel} semantic version")
    tag = max(candidates, key=lambda candidate: candidate[0])[1]
    return tag, normalize_release_version(tag)


def required_go_version(go_mod_text: str) -> tuple[int, int, int]:
    required: list[tuple[int, int, int]] = []
    for line in go_mod_text.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] in {"go", "toolchain"}:
            required.append(parse_go_version(fields[1]))
    return max(required, default=(0, 0, 0))


def latest_compatible_module_version(
    client: SourceClient,
    module: str,
    builder_go_version: tuple[int, int, int],
) -> str:
    escaped_module = urllib.parse.quote(module, safe="/")
    list_url = f"https://proxy.golang.org/{escaped_module}/@v/list"
    versions = client.get_text(
        f"go-module-{module.replace('/', '-')}.txt",
        list_url,
        allowed_hosts={"proxy.golang.org"},
    ).splitlines()
    candidates = sorted(
        {
            normalize_stable_version(version)
            for version in versions
            if isinstance(version, str) and SEMVER_RE.fullmatch(version)
        },
        key=semver_key,
        reverse=True,
    )
    if not candidates:
        raise ResolveError(f"Go module {module} returned no stable versions")

    for version in candidates:
        mod_url = f"https://proxy.golang.org/{escaped_module}/@v/v{version}.mod"
        mod_text = client.get_text(
            f"go-module-{module.replace('/', '-')}-v{version}.mod",
            mod_url,
            allowed_hosts={"proxy.golang.org"},
        )
        if required_go_version(mod_text) <= builder_go_version:
            return version
    raise ResolveError(
        f"no compatible stable {module} version for Go {'.'.join(map(str, builder_go_version))}"
    )


def load_policy(policy_path: Path) -> dict[str, Any]:
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ResolveError(f"cannot read policy {policy_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ResolveError(f"invalid policy JSON {policy_path}: {exc}") from exc

    if not isinstance(policy, dict) or policy.get("version") != 1:
        raise ResolveError("proxy update policy must be an object with version 1")
    releases = policy.get("github_releases")
    modules = policy.get("go_modules")
    go_version_arg = policy.get("go_version_arg")
    if not isinstance(releases, list) or not releases:
        raise ResolveError("proxy update policy has no GitHub releases")
    if not isinstance(modules, list) or not modules:
        raise ResolveError("proxy update policy has no Go modules")
    if not isinstance(go_version_arg, str) or not ARG_NAME_RE.fullmatch(go_version_arg):
        raise ResolveError("proxy update policy has an invalid go_version_arg")

    used_args: set[str] = set()
    for component in releases:
        if not isinstance(component, dict):
            raise ResolveError("proxy release policy contains a non-object component")
        repository = component.get("repository")
        if not isinstance(repository, str) or not POLICY_RE.fullmatch(repository):
            raise ResolveError(f"invalid proxy source repository: {repository}")
        name = component.get("name")
        if not isinstance(name, str) or not COMPONENT_NAME_RE.fullmatch(name):
            raise ResolveError(f"invalid proxy component name: {name}")
        if not isinstance(component.get("include_prereleases", False), bool):
            raise ResolveError(f"invalid include_prereleases setting for {name}")
        for key in ("name", "version_arg", "source_ref_arg", "source_sha256_arg"):
            value = component.get(key)
            if not isinstance(value, str) or not value:
                raise ResolveError(f"proxy release policy is missing {key}")
        for key in ("version_arg", "source_ref_arg", "source_sha256_arg"):
            arg_name = component[key]
            if not ARG_NAME_RE.fullmatch(arg_name) or arg_name in used_args:
                raise ResolveError(f"duplicate or invalid proxy build arg: {arg_name}")
            used_args.add(arg_name)

    for module in modules:
        if not isinstance(module, dict):
            raise ResolveError("proxy module policy contains a non-object module")
        module_name = module.get("module")
        arg_name = module.get("version_arg")
        if (
            not isinstance(module_name, str)
            or not MODULE_RE.fullmatch(module_name)
            or not isinstance(arg_name, str)
            or not ARG_NAME_RE.fullmatch(arg_name)
            or arg_name in used_args
        ):
            raise ResolveError(f"duplicate or invalid Go module build arg: {arg_name}")
        used_args.add(arg_name)
    return policy


def render_build_args(values: dict[str, str]) -> str:
    lines: list[str] = []
    for name, value in values.items():
        if not ARG_NAME_RE.fullmatch(name):
            raise ResolveError(f"invalid build arg name: {name}")
        if not BUILD_ARG_VALUE_RE.fullmatch(value):
            raise ResolveError(f"invalid build arg value for {name}")
        lines.append(f"{name}={value}")
    if not lines:
        raise ResolveError("no proxy build args were resolved")
    return "\n".join(lines)


def write_github_output(path: Path, name: str, value: str) -> None:
    if str(path) == "/dev/null":
        return
    delimiter = f"PROXY_CORE_OUTPUT_{uuid.uuid4().hex}"
    try:
        with path.open("a", encoding="utf-8") as output:
            output.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")
    except OSError as exc:
        raise ResolveError(f"cannot write GitHub output {path}: {exc}") from exc


def markdown_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def format_summary(releases: list[dict[str, str]], modules: list[dict[str, str]]) -> str:
    lines = [
        "## Proxy core build inputs",
        "",
        "The workflow resolves upstream release channels and passes immutable source inputs to Docker.",
        "",
        "| Component | Release | Source commit | Source SHA256 |",
        "| --- | --- | --- | --- |",
    ]
    for release in releases:
        lines.append(
            "| "
            + " | ".join(
                (
                    markdown_cell(release["name"]),
                    f"[{markdown_cell(release['version'])}]({release['release_url']})",
                    f"`{release['source_ref']}`",
                    f"`{release['source_sha256']}`",
                )
            )
            + " |"
        )
    lines.extend(
        [
            "",
            "| Go module | Selected version |",
            "| --- | --- |",
        ]
    )
    for module in modules:
        lines.append(f"| `{module['module']}` | `{module['version']}` |")
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    builder_dir = script_dir.parent
    parser = argparse.ArgumentParser(
        description="Resolve latest stable proxy-core source and Go module inputs."
    )
    parser.add_argument(
        "--dockerfile",
        type=Path,
        default=builder_dir / "image" / "Dockerfile",
    )
    parser.add_argument(
        "--policy",
        type=Path,
        default=builder_dir / "configs" / "proxy-core-update-policy.json",
    )
    parser.add_argument(
        "--github-output",
        type=Path,
        default=Path(os.environ.get("GITHUB_OUTPUT", "/dev/null")),
    )
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--fixture-dir", type=Path, help=argparse.SUPPRESS)
    parser.add_argument(
        "--go-version",
        help="override the Go version read from the Dockerfile (test utility)",
    )
    return parser.parse_args()


def resolve_inputs(
    client: SourceClient,
    policy: dict[str, Any],
    dockerfile: Path,
    go_version_override: str | None = None,
) -> tuple[dict[str, str], list[dict[str, str]], list[dict[str, str]]]:
    go_version = go_version_override or read_dockerfile_arg(
        dockerfile, policy["go_version_arg"]
    )
    builder_go_version = parse_go_version(go_version)
    values: dict[str, str] = {}
    release_rows: list[dict[str, str]] = []
    module_rows: list[dict[str, str]] = []

    for component in policy["github_releases"]:
        repository = component["repository"]
        tag, version = latest_release(client, component)
        source_ref = resolve_git_tag(client, repository, tag)
        archive_url = f"https://codeload.github.com/{repository}/tar.gz/{source_ref}"
        archive = client.get_bytes(
            f"source-{component['name']}-{source_ref}.tar.gz",
            archive_url,
            allowed_hosts={"codeload.github.com"},
            max_bytes=SourceClient.MAX_ARCHIVE_BYTES,
        )
        source_sha256 = hashlib.sha256(archive).hexdigest()
        if not SHA256_RE.fullmatch(source_sha256):
            raise ResolveError(f"computed source archive digest is malformed for {repository}")
        values[component["version_arg"]] = version
        values[component["source_ref_arg"]] = source_ref
        values[component["source_sha256_arg"]] = source_sha256
        release_rows.append(
            {
                "name": component["name"],
                "version": version,
                "source_ref": source_ref,
                "source_sha256": source_sha256,
                "release_url": f"https://github.com/{repository}/releases/tag/{urllib.parse.quote(tag, safe='')}",
            }
        )

    for module in policy["go_modules"]:
        version = latest_compatible_module_version(
            client, module["module"], builder_go_version
        )
        values[module["version_arg"]] = version
        module_rows.append({"module": module["module"], "version": version})

    return values, release_rows, module_rows


def main() -> int:
    args = parse_args()
    try:
        policy = load_policy(args.policy)
        client = SourceClient(args.fixture_dir)
        values, release_rows, module_rows = resolve_inputs(
            client, policy, args.dockerfile, args.go_version
        )
        build_args = render_build_args(values)
        summary = format_summary(release_rows, module_rows)
        print(summary)
        write_github_output(args.github_output, "build_args", build_args)
        if args.summary:
            try:
                with args.summary.open("a", encoding="utf-8") as summary_file:
                    summary_file.write(summary)
            except OSError as exc:
                raise ResolveError(f"cannot write summary {args.summary}: {exc}") from exc
        print("Proxy core build inputs resolved successfully.")
        return 0
    except (KeyError, TypeError, ValueError, ResolveError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
