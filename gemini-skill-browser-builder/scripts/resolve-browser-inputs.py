#!/usr/bin/env python3
"""Resolve maintained channels once, then build only immutable inputs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TAG = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")
SHA = re.compile(r"[a-f0-9]{40}")
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("unexpected GitHub API redirect")


def github(path):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "release-factory"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request("https://api.github.com/repos/" + path, headers=headers)
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=60) as response:
        payload = response.read(2 * 1024 * 1024 + 1)
        if len(payload) > 2 * 1024 * 1024:
            raise ValueError("GitHub metadata exceeded size limit")
        return json.loads(payload)


def pin_image(reference):
    result = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", reference, "--format", "{{json .Manifest}}"],
        capture_output=True, text=True, check=True, timeout=120,
    )
    digest = json.loads(result.stdout)["digest"]
    if not DIGEST.fullmatch(digest):
        raise ValueError("registry returned an invalid digest")
    return reference + "@" + digest


def resolve(args, components):
    if components.get("schema_version") != 1:
        raise ValueError("unsupported component input schema")
    variant = components["variants"][args.variant]
    tag = args.browser_base_tag or variant.get("tag")
    if not tag:
        tag = github(variant["release_repository"] + "/releases/latest")["tag_name"]
    image_tag = args.image_tag or f"{tag}-{args.variant}"
    for value in (tag, image_tag, args.latest_tag or f"latest-{args.variant}"):
        if not TAG.fullmatch(value):
            raise ValueError("invalid container tag")
    ref = args.gemini_skill_ref or components["source_ref"]
    if any(ord(c) < 32 for c in ref) or len(ref) > 256:
        raise ValueError("invalid source ref")
    commit = ref if SHA.fullmatch(ref) else github(
        components["source_repository"] + "/commits/" + urllib.parse.quote(ref, safe="")
    )["sha"]
    if not SHA.fullmatch(commit):
        raise ValueError("GitHub returned an invalid source commit")
    return {
        "variant": args.variant,
        "image_repo": "gemini-skill-browser",
        "platforms": "linux/amd64",
        "browser_base_tag": tag,
        "base_image": pin_image(variant["repository"] + ":" + tag),
        "node_image": pin_image(components["node_image"]),
        "gemini_skill_ref": commit,
        "image_tag": image_tag,
        "latest_tag": args.latest_tag or f"latest-{args.variant}",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=("kasm", "linuxserver"), required=True)
    parser.add_argument("--browser-base-tag", default="")
    parser.add_argument("--image-tag", default="")
    parser.add_argument("--gemini-skill-ref", default="")
    parser.add_argument("--push-latest", choices=("true", "false"), default="false")
    parser.add_argument("--latest-tag", default="")
    parser.add_argument("--image-repo", choices=("gemini-skill-browser",), default="gemini-skill-browser")
    parser.add_argument("--default-platform", choices=("linux/amd64",), default="linux/amd64")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    inputs = resolve(args, json.loads((ROOT / "configs/components.json").read_text()))
    if args.output:
        args.output.write_text(json.dumps(inputs, indent=2) + "\n")
    if args.github_output:
        tags = "type=raw,value=" + inputs["image_tag"]
        if args.push_latest == "true":
            tags += "\ntype=raw,value=" + inputs["latest_tag"]
        with args.github_output.open("a") as output:
            for key, value in inputs.items():
                output.write(f"{key}={value}\n")
            output.write("tags<<BROWSER_TAGS\n" + tags + "\nBROWSER_TAGS\n")
    print(json.dumps(inputs, indent=2))


if __name__ == "__main__":
    main()
