#!/usr/bin/env python3
"""Stage a tested image by config digest, then publish only verified receipts."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

REPOSITORIES = {
    "codex": "codex-claude-workstation", "opencode": "opencode-workstation",
    "kasm": "gemini-skill-browser", "linuxserver": "gemini-skill-browser",
    "openclaw": "openclaw-sandbox",
}
PLATFORMS = ("linux/amd64", "linux/arm64")
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")
IMAGE_TYPES = {"application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"}
INDEX_TYPES = {"application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json"}


def require(value, message):
    if not value:
        raise ValueError(message)


def docker(*args, capture=False):
    return subprocess.run(["docker", *map(str, args)], check=True,
                          timeout=1800, stdout=subprocess.PIPE if capture else None).stdout


def remote_manifest(reference):
    raw = docker("buildx", "imagetools", "inspect", "--raw", reference, capture=True)
    return json.loads(raw), "sha256:" + hashlib.sha256(raw).hexdigest()


def check_manifest(manifest, image_id):
    require(manifest.get("schemaVersion") == 2 and manifest.get("mediaType") in IMAGE_TYPES
            and manifest.get("config", {}).get("digest") == image_id,
            "registry image differs from the tested config digest")


def stage(args, expected):
    require(DIGEST.fullmatch(args.image_id), "invalid tested image ID")
    inspected = json.loads(docker("image", "inspect", args.image, capture=True))
    require(len(inspected) == 1, "expected exactly one local image")
    image = inspected[0]
    require(image.get("Id") == args.image_id, "image changed after verification")
    require(f"{image.get('Os')}/{image.get('Architecture')}" == args.platform, "tested platform mismatch")
    labels = image.get("Config", {}).get("Labels") or {}
    require(labels.get("org.opencontainers.image.revision") == args.revision, "tested revision mismatch")
    receipt_path = args.receipt
    require(not receipt_path.exists() and not receipt_path.is_symlink(), "receipt must be a new file")
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    reference = f"{args.repository}:ci-{args.run_id}-{args.run_attempt}-{args.variant}-{args.platform.split('/')[1]}"
    # Tag the recorded ID, never a mutable local tag.
    docker("image", "tag", args.image_id, reference)
    docker("image", "push", reference)
    manifest, digest = remote_manifest(reference)
    check_manifest(manifest, args.image_id)
    receipt = {"schema_version": 1, **expected, "platform": args.platform,
               "image_id": args.image_id, "manifest_digest": digest}
    with receipt_path.open("x", encoding="utf-8") as output:
        output.write(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


def check_receipts(directory, expected, platforms):
    require(directory.is_dir() and not directory.is_symlink(), "invalid receipt directory")
    paths = sorted(directory.rglob("receipt.json"))
    require(len(paths) == len(platforms), "missing or unexpected platform receipts")
    receipts = {}
    for path in paths:
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(directory.resolve()),
                "receipt escaped artifact directory")
        receipt = json.loads(path.read_text(encoding="utf-8"))
        require(receipt.get("schema_version") == 1, "invalid receipt schema")
        for key, value in expected.items():
            require(receipt.get(key) == value, f"receipt {key} mismatch")
        platform = receipt.get("platform")
        require(platform in platforms and platform not in receipts, "unexpected or duplicate platform receipt")
        for field in ("image_id", "manifest_digest"):
            require(isinstance(receipt.get(field), str) and DIGEST.fullmatch(receipt[field]), f"invalid {field}")
        receipts[platform] = receipt
    for field in ("image_id", "manifest_digest"):
        require(len({receipt[field] for receipt in receipts.values()}) == len(platforms),
                "different platforms cannot share an image config or manifest")
    # Validate all remote images before touching any release tag.
    for receipt in receipts.values():
        manifest, digest = remote_manifest(expected["repository"] + "@" + receipt["manifest_digest"])
        require(digest == receipt["manifest_digest"], "registry manifest digest mismatch")
        check_manifest(manifest, receipt["image_id"])
    return receipts


def publish(args, expected):
    platforms = args.platforms.split(",")
    require(platforms and len(set(platforms)) == len(platforms) and set(platforms) <= set(PLATFORMS),
            "invalid target platforms")
    tags = list(dict.fromkeys([args.image_tag] + ([args.latest_tag] if args.latest_tag else [])))
    for tag in tags:
        require(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag), "invalid release tag")
    receipts = check_receipts(args.directory, expected, platforms)
    digests = {platform: receipt["manifest_digest"] for platform, receipt in receipts.items()}
    if args.dry_run:
        print(json.dumps({"repository": args.repository, "tags": tags, "tested_manifests": digests}, indent=2))
        return
    for tag in tags:
        reference = args.repository + ":" + tag
        docker("buildx", "imagetools", "create", "--prefer-index=true", "--tag", reference,
               *(args.repository + "@" + digest for digest in digests.values()))
        manifest, digest = remote_manifest(reference)
        require(manifest.get("mediaType") in INDEX_TYPES, "published tag is not an image index")
        found = {}
        for item in manifest.get("manifests", []):
            platform = item.get("platform") or {}
            key = f"{platform.get('os')}/{platform.get('architecture')}"
            require(key not in found, "duplicate platform in published index")
            found[key] = item.get("digest")
        require(found == digests, "published index differs from tested manifests")
        print(f"Published tested image: {reference} -> {digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    staging = subparsers.add_parser("stage")
    publishing = subparsers.add_parser("publish")
    for command in (staging, publishing):
        command.add_argument("--variant", required=True, choices=REPOSITORIES)
        command.add_argument("--repository", required=True)
        command.add_argument("--revision", required=True)
        command.add_argument("--run-id", required=True)
        command.add_argument("--run-attempt", required=True)
    staging.add_argument("--image", required=True)
    staging.add_argument("--image-id", required=True)
    staging.add_argument("--platform", required=True, choices=PLATFORMS)
    staging.add_argument("--receipt", required=True, type=Path)
    publishing.add_argument("--directory", required=True, type=Path)
    publishing.add_argument("--platforms", required=True)
    publishing.add_argument("--image-tag", required=True)
    publishing.add_argument("--latest-tag", default="")
    publishing.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    require(re.fullmatch(r"ghcr\.io/[a-z0-9][a-z0-9-]*/" + REPOSITORIES[args.variant], args.repository),
            "unexpected publication repository")
    require(re.fullmatch(r"[a-f0-9]{40}", args.revision), "invalid workflow revision")
    for value in (args.run_id, args.run_attempt):
        require(re.fullmatch(r"[1-9][0-9]*", value), "invalid workflow run identity")
    expected = {key: getattr(args, key) for key in ("variant", "repository", "revision", "run_id", "run_attempt")}
    if args.command == "stage":
        stage(args, expected)
    else:
        publish(args, expected)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
