#!/usr/bin/env python3
"""Compare DeepSeek Harness component pins with authoritative upstream releases."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable


SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
ARG_RE = re.compile(
    r"^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)=([^\s#]*)\s*(?:#.*)?$",
    re.IGNORECASE,
)
FROM_RE = re.compile(r"^\s*FROM\s+(?:(?:--\S+)\s+)*(\S+)", re.IGNORECASE)


class UpdateCheckError(RuntimeError):
    """A deterministic pin or upstream-source check failed."""


class SameOriginHTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Keep metadata redirects on the original HTTPS origin."""

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
        original = urllib.parse.urlparse(request.full_url)
        redirected = urllib.parse.urlparse(absolute_url)
        if (
            redirected.scheme != "https"
            or not redirected.hostname
            or redirected.username is not None
            or redirected.password is not None
            or (redirected.hostname, redirected.port)
            != (original.hostname, original.port)
        ):
            raise UpdateCheckError(
                f"component source redirected outside its HTTPS origin: {absolute_url}"
            )
        return super().redirect_request(
            request, fp, code, msg, headers, absolute_url
        )


class SourceClient:
    MAX_RESPONSE_BYTES = 16 * 1024 * 1024

    def __init__(self, fixture_dir: Path | None = None) -> None:
        self.fixture_dir = fixture_dir

    def get_text(self, fixture: str, url: str) -> str:
        if self.fixture_dir is not None:
            fixture_path = self.fixture_dir / fixture
            try:
                payload = fixture_path.read_bytes()
            except OSError as exc:
                raise UpdateCheckError(
                    f"cannot read fixture {fixture_path}: {exc}"
                ) from exc
            if len(payload) > self.MAX_RESPONSE_BYTES:
                raise UpdateCheckError(
                    f"fixture {fixture_path} exceeds {self.MAX_RESPONSE_BYTES} bytes"
                )
            try:
                return payload.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise UpdateCheckError(f"fixture {fixture_path} is not UTF-8") from exc

        parsed_url = urllib.parse.urlparse(url)
        if (
            parsed_url.scheme != "https"
            or not parsed_url.hostname
            or parsed_url.username is not None
            or parsed_url.password is not None
        ):
            raise UpdateCheckError(f"component source must use an absolute HTTPS URL: {url}")

        headers = {"User-Agent": "release-factory-component-update-check"}
        hostname = parsed_url.hostname
        if hostname == "api.github.com":
            headers["Accept"] = "application/vnd.github+json"
            headers["X-GitHub-Api-Version"] = "2022-11-28"
        github_token = os.environ.get("GITHUB_TOKEN", "")
        if github_token and hostname == "api.github.com":
            headers["Authorization"] = f"Bearer {github_token}"

        request = urllib.request.Request(url, headers=headers)
        opener = urllib.request.build_opener(SameOriginHTTPSRedirectHandler())
        try:
            with opener.open(request, timeout=30) as response:
                final_url = urllib.parse.urlparse(response.geturl())
                if (
                    final_url.scheme != "https"
                    or not final_url.hostname
                    or (final_url.hostname, final_url.port)
                    != (parsed_url.hostname, parsed_url.port)
                ):
                    raise UpdateCheckError(
                        "component source redirected outside its HTTPS origin: "
                        f"{response.geturl()}"
                    )
                content_length = response.headers.get("Content-Length")
                if content_length and int(content_length) > self.MAX_RESPONSE_BYTES:
                    raise UpdateCheckError(
                        f"component source response exceeds {self.MAX_RESPONSE_BYTES} bytes: {url}"
                    )
                payload = response.read(self.MAX_RESPONSE_BYTES + 1)
                if len(payload) > self.MAX_RESPONSE_BYTES:
                    raise UpdateCheckError(
                        f"component source response exceeds {self.MAX_RESPONSE_BYTES} bytes: {url}"
                    )
                return payload.decode("utf-8")
        except (
            OSError,
            TimeoutError,
            UnicodeDecodeError,
            ValueError,
            urllib.error.URLError,
        ) as exc:
            raise UpdateCheckError(f"cannot fetch {url}: {exc}") from exc

    def get_json(self, fixture: str, url: str) -> Any:
        try:
            return json.loads(self.get_text(fixture, url))
        except json.JSONDecodeError as exc:
            raise UpdateCheckError(f"invalid JSON from {url}: {exc}") from exc


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    builder_dir = script_dir.parent
    parser = argparse.ArgumentParser(
        description="Check pinned DeepSeek Harness components for upstream updates."
    )
    parser.add_argument(
        "--dockerfile",
        type=Path,
        default=builder_dir / "image" / "Dockerfile",
        help="Dockerfile containing component pins",
    )
    parser.add_argument(
        "--policy",
        type=Path,
        default=builder_dir / "configs" / "component-update-policy.json",
        help="component source policy",
    )
    parser.add_argument("--fixture-dir", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--summary", type=Path, help="write a Markdown summary")
    parser.add_argument(
        "--fail-on-updates",
        action="store_true",
        help="exit 1 when one or more newer versions are found",
    )
    return parser.parse_args()


def semver_key(version: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(version)
    if not match:
        raise UpdateCheckError(f"unsupported non-stable semantic version: {version}")
    return tuple(int(part) for part in match.groups())


def normalize_semver(version: str) -> str:
    semver_key(version)
    return version.removeprefix("v")


def latest_stable(versions: Iterable[str]) -> str:
    stable = [
        normalize_semver(version)
        for version in versions
        if isinstance(version, str) and SEMVER_RE.fullmatch(version)
    ]
    if not stable:
        raise UpdateCheckError("upstream returned no stable semantic versions")
    return max(stable, key=semver_key)


def read_dockerfile(dockerfile: Path) -> tuple[str, dict[str, str]]:
    try:
        dockerfile_text = dockerfile.read_text(encoding="utf-8")
    except OSError as exc:
        raise UpdateCheckError(f"cannot read Dockerfile {dockerfile}: {exc}") from exc

    pins: dict[str, str] = {}
    for line in dockerfile_text.splitlines():
        match = ARG_RE.match(line)
        if not match:
            continue
        name, value = match.groups()
        if name in pins and pins[name] != value:
            raise UpdateCheckError(
                f"Dockerfile ARG {name} has inconsistent values: {pins[name]} and {value}"
            )
        pins[name] = value
    return dockerfile_text, pins


def dockerfile_from_version(
    component_name: str,
    dockerfile_text: str,
    image: str,
    suffix: str,
) -> str:
    versions: set[str] = set()
    tag_pattern = re.compile(rf"^(v?\d+\.\d+\.\d+){re.escape(suffix)}$")

    for line in dockerfile_text.splitlines():
        match = FROM_RE.match(line)
        if not match:
            continue
        image_ref = match.group(1)
        if "@sha256:" not in image_ref:
            continue
        name_and_tag = image_ref.rsplit("@", 1)[0]
        slash_index = name_and_tag.rfind("/")
        colon_index = name_and_tag.rfind(":")
        if colon_index <= slash_index:
            continue
        repository = name_and_tag[:colon_index]
        tag = name_and_tag[colon_index + 1 :]
        if repository.rsplit("/", 1)[-1] != image:
            continue
        tag_match = tag_pattern.fullmatch(tag)
        if tag_match:
            versions.add(normalize_semver(tag_match.group(1)))

    if len(versions) != 1:
        raise UpdateCheckError(
            f"component {component_name} expected one pinned {image} base-image "
            f"version, got {sorted(versions)}"
        )
    return versions.pop()


def resolve_current(
    component: dict[str, Any],
    pins: dict[str, str],
    dockerfile_text: str,
) -> str:
    pin_name = component.get("pin")
    if isinstance(pin_name, str) and pin_name:
        current = pins.get(pin_name, "")
        if not current:
            raise UpdateCheckError(f"required Dockerfile ARG {pin_name} is missing")
        return normalize_semver(current)

    pin_from = component.get("pin_from")
    if not isinstance(pin_from, dict) or pin_from.get("type") != "dockerfile_from":
        raise UpdateCheckError(
            f"component {component.get('name', 'unknown component')} has no supported pin selector"
        )
    return dockerfile_from_version(
        str(component.get("name", "unknown component")),
        dockerfile_text,
        str(pin_from["image"]),
        str(pin_from["suffix"]),
    )


def node_release_entries(data: Any, major: int) -> list[dict[str, Any]]:
    if not isinstance(data, list):
        raise UpdateCheckError("Node.js release index is not a JSON array")
    entries = [
        entry
        for entry in data
        if isinstance(entry, dict)
        and entry.get("lts") not in (False, None, "")
        and isinstance(entry.get("version"), str)
        and SEMVER_RE.fullmatch(entry["version"])
        and semver_key(entry["version"])[0] == major
    ]
    if not entries:
        raise UpdateCheckError(f"Node.js release index has no stable LTS v{major} release")
    return entries


def latest_node_release(data: Any, major: int) -> dict[str, Any]:
    return max(node_release_entries(data, major), key=lambda entry: semver_key(entry["version"]))


def upstream_version(
    component: dict[str, Any], client: SourceClient
) -> tuple[str, str]:
    source = component.get("source")
    if not isinstance(source, dict):
        raise UpdateCheckError("component source policy is missing")
    source_type = source.get("type")

    if source_type == "github_release":
        repo = str(source["repo"])
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        data = client.get_json(f"github-release-{repo.replace('/', '-')}.json", url)
        if not isinstance(data, dict) or not isinstance(data.get("tag_name"), str):
            raise UpdateCheckError(f"GitHub latest release for {repo} has no tag_name")
        tag_name = data["tag_name"]
        version = normalize_semver(tag_name)
        encoded_tag = urllib.parse.quote(tag_name, safe="")
        return version, f"https://github.com/{repo}/releases/tag/{encoded_tag}"

    if source_type == "github_tag":
        repo = str(source["repo"])
        url = f"https://api.github.com/repos/{repo}/tags?per_page=100"
        data = client.get_json(f"github-tags-{repo.replace('/', '-')}.json", url)
        if not isinstance(data, list):
            raise UpdateCheckError(f"GitHub tags for {repo} are not a JSON array")
        version = latest_stable(
            entry.get("name", "") for entry in data if isinstance(entry, dict)
        )
        return version, f"https://github.com/{repo}/releases/tag/v{version}"

    if source_type == "go_module":
        module = str(source["module"])
        escaped = urllib.parse.quote(module, safe="/")
        url = f"https://proxy.golang.org/{escaped}/@v/list"
        versions = client.get_text(
            f"go-module-{module.replace('/', '-')}.txt", url
        ).splitlines()
        return latest_stable(versions), f"https://pkg.go.dev/{module}"

    if source_type == "go_stable":
        url = "https://go.dev/VERSION?m=text"
        lines = client.get_text("go-stable.txt", url).splitlines()
        if not lines:
            raise UpdateCheckError("Go stable endpoint returned an empty response")
        return normalize_semver(lines[0].removeprefix("go")), "https://go.dev/dl/"

    if source_type == "node_release_line":
        url = "https://nodejs.org/dist/index.json"
        major = int(source["major"])
        release = latest_node_release(client.get_json("node-index.json", url), major)
        node_version = normalize_semver(release["version"])
        release_url = f"https://nodejs.org/en/download/archive/v{node_version}"
        return node_version, release_url

    if source_type == "npm":
        package = str(source["package"])
        selector = str(source.get("selector", "latest"))
        if not re.fullmatch(r"[A-Za-z0-9._-]+", selector):
            raise UpdateCheckError(f"invalid npm selector for {package}: {selector}")
        encoded = urllib.parse.quote(package, safe="")
        encoded_selector = urllib.parse.quote(selector, safe="")
        url = f"https://registry.npmjs.org/{encoded}/{encoded_selector}"
        fixture = f"npm-{encoded}.json"
        if selector != "latest":
            fixture = f"npm-{encoded}-{encoded_selector}.json"
        data = client.get_json(fixture, url)
        if not isinstance(data, dict) or not isinstance(data.get("version"), str):
            raise UpdateCheckError(f"npm metadata for {package} has no version")
        version = normalize_semver(data["version"])
        return version, f"https://www.npmjs.com/package/{package}/v/{version}"

    if source_type == "pypi":
        package = str(source["package"])
        url = f"https://pypi.org/pypi/{package}/json"
        data = client.get_json(f"pypi-{package}.json", url)
        try:
            version = data["info"]["version"]
        except (KeyError, TypeError) as exc:
            raise UpdateCheckError(f"PyPI metadata for {package} has no version") from exc
        if not isinstance(version, str):
            raise UpdateCheckError(f"PyPI metadata for {package} has an invalid version")
        return normalize_semver(version), f"https://pypi.org/project/{package}/"

    if source_type == "python_release_line":
        url = str(source["url"])
        release_line = str(source["release_line"])
        data = client.get_json(f"python-{release_line}.json", url)
        if not isinstance(data, list):
            raise UpdateCheckError("Python release API response is not a JSON array")
        versions: list[str] = []
        for release in data:
            if not isinstance(release, dict) or release.get("pre_release") is True:
                continue
            name = release.get("name", "")
            match = re.fullmatch(r"Python (\d+\.\d+\.\d+)", name)
            if match and match.group(1).startswith(f"{release_line}."):
                versions.append(match.group(1))
        latest = latest_stable(versions)
        slug = latest.replace(".", "")
        return latest, f"https://www.python.org/downloads/release/python-{slug}/"

    raise UpdateCheckError(f"unsupported source type: {source_type}")


def markdown_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def format_summary(rows: list[dict[str, str]], errors: list[str]) -> str:
    lines = [
        "## DeepSeek Harness component update check",
        "",
        "| Component | Pinned | Upstream | Status |",
        "| --- | --- | --- | --- |",
    ]
    for row in rows:
        name = markdown_cell(row["name"])
        current = markdown_cell(row["current"])
        upstream = markdown_cell(row["upstream"])
        status = markdown_cell(row["status"])
        lines.append(
            f"| {name} | `{current}` | [{upstream}]({row['url']}) | {status} |"
        )
    if errors:
        lines.extend(["", "### Source errors", ""])
        lines.extend(f"- {markdown_cell(error)}" for error in errors)
    lines.extend(
        [
            "",
            "This workflow is read-only. Update candidates still require reviewed pins, "
            "checksum/digest refreshes where applicable, and the existing build, smoke, "
            "and vulnerability gates.",
            "",
        ]
    )
    return "\n".join(lines)


def load_policy(policy_path: Path) -> list[dict[str, Any]]:
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise UpdateCheckError(f"cannot read policy {policy_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise UpdateCheckError(f"invalid policy JSON {policy_path}: {exc}") from exc
    if not isinstance(policy, dict) or policy.get("version") != 1:
        raise UpdateCheckError("component update policy must be an object with version 1")
    components = policy.get("components")
    if not isinstance(components, list) or not components:
        raise UpdateCheckError("component update policy has no components")
    if not all(isinstance(component, dict) for component in components):
        raise UpdateCheckError("component update policy contains a non-object component")
    return components


def write_summary(path: Path, summary: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as summary_file:
            summary_file.write(summary)
    except OSError as exc:
        raise UpdateCheckError(f"cannot write summary {path}: {exc}") from exc


def main() -> int:
    args = parse_args()
    try:
        components = load_policy(args.policy)
        dockerfile_text, pins = read_dockerfile(args.dockerfile)
    except UpdateCheckError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    client = SourceClient(args.fixture_dir)
    rows: list[dict[str, str]] = []
    errors: list[str] = []
    updates = 0

    for component in components:
        name = str(component.get("name", "unknown component"))
        try:
            current = resolve_current(component, pins, dockerfile_text)
            upstream, url = upstream_version(component, client)
            if semver_key(upstream) > semver_key(current):
                status = "update available"
                updates += 1
            elif semver_key(upstream) == semver_key(current):
                status = "current"
            else:
                status = "pinned newer than source"
            rows.append(
                {
                    "name": name,
                    "current": current,
                    "upstream": upstream,
                    "url": url,
                    "status": status,
                }
            )
        except (KeyError, TypeError, ValueError, UpdateCheckError) as exc:
            errors.append(f"{name}: {exc}")

    summary = format_summary(rows, errors)
    print(summary)
    if args.summary:
        try:
            write_summary(args.summary, summary)
        except UpdateCheckError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2

    print(f"component_updates={updates}")
    if errors:
        print(f"ERROR: {len(errors)} component source checks failed", file=sys.stderr)
        return 2
    if updates:
        message = f"{updates} pinned component update candidate(s) found"
        print(f"WARNING: {message}", file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::warning title=Component updates available::{message}")
        if args.fail_on_updates:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
