#!/usr/bin/env python3
"""Export verified images and publish those exact images without rebuilding."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile


DIGEST = re.compile(r"sha256:[a-f0-9]{64}")
PLATFORMS = ("linux/amd64", "linux/arm64")
IMAGE_TYPES = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}
INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def docker(*args, capture=False):
    result = subprocess.run(["docker", *map(str, args)], check=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def check_config(config, expected):
    require(f"{config.get('os')}/{config.get('architecture')}" == expected["platform"],
            "image platform does not match the tested platform")
    settings = config.get("config") or {}
    labels = settings.get("Labels") or {}
    require(labels.get("org.opencontainers.image.revision") == expected["revision"],
            "image revision does not match this workflow")
    require(labels.get("org.opencontainers.image.version") == expected["dsh_version"],
            "image DSH version does not match this release")
    variants = [value for value in settings.get("Env", []) if value.startswith("DSH_IMAGE_VARIANT=")]
    require(variants == [f"DSH_IMAGE_VARIANT={expected['variant']}"], "image variant mismatch")


def inspect_image(image, expected):
    inspected = json.loads(docker("image", "inspect", image, capture=True))
    require(isinstance(inspected, list) and len(inspected) == 1, "expected exactly one local image")
    inspected = inspected[0]
    require(inspected.get("Id") == expected["image_id"], "local image ID changed after verification")
    check_config({"os": inspected.get("Os"), "architecture": inspected.get("Architecture"),
                  "config": inspected.get("Config")}, expected)
    return inspected


def check_archive(directory, expected):
    require(not directory.is_symlink() and directory.is_dir(), f"missing artifact directory: {directory}")
    for name in ("receipt.json", "image.tar.gz"):
        path = directory / name
        require(path.is_file() and not path.is_symlink(), f"missing or symlinked artifact: {path}")
    receipt = json.loads((directory / "receipt.json").read_text(encoding="utf-8"))
    require(isinstance(receipt, dict) and type(receipt.get("schema_version")) is int
            and receipt["schema_version"] == 1, "invalid artifact receipt")
    for key, value in expected.items():
        require(receipt.get(key) == value, f"artifact {key} mismatch: {directory}")
    require(isinstance(receipt.get("image_id"), str) and DIGEST.fullmatch(receipt["image_id"]),
            "invalid image ID in receipt")
    archive = directory / "image.tar.gz"
    require(sha256(archive) == receipt.get("archive_sha256"), f"archive checksum mismatch: {archive}")

    # Read metadata without extracting any archive paths into the host filesystem.
    digest = receipt["image_id"].removeprefix("sha256:")
    config_names = {f"{digest}.json", f"blobs/sha256/{digest}"}
    metadata = {}
    with tarfile.open(archive, "r|gz") as saved:
        for member in saved:
            if member.name not in config_names | {"manifest.json"}:
                continue
            require(member.isfile() and member.size <= 4 * 1024 * 1024,
                    "invalid image archive metadata member")
            require(member.name not in metadata, "duplicate image archive metadata")
            metadata[member.name] = saved.extractfile(member).read()
    manifest = json.loads(metadata.get("manifest.json", b"null"))
    require(isinstance(manifest, list) and len(manifest) == 1, "archive must contain exactly one image")
    config_name = manifest[0].get("Config")
    require(config_name in config_names and config_name in metadata, "archive config does not match tested image ID")
    config_bytes = metadata[config_name]
    require(hashlib.sha256(config_bytes).hexdigest() == digest, "archive image config digest mismatch")
    check_config(json.loads(config_bytes), receipt)
    return receipt


def export_image(options, expected):
    require(DIGEST.fullmatch(options.image_id), "expected image ID must be a SHA-256 digest")
    expected = {**expected, "platform": options.platform, "image_id": options.image_id}
    inspected = inspect_image(options.image, expected)
    directory = options.directory
    require(not directory.is_symlink(), "artifact destination must not be a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    require(not any(directory.iterdir()), "artifact destination must be empty")
    size = inspected.get("Size")
    require(type(size) is int and size >= 0, "Docker did not report an image size")
    require(shutil.disk_usage(directory).free >= size + 64 * 1024 * 1024, "insufficient free space for image export")
    print(f"Exporting {options.image_id} to {directory.resolve()}: 2 files, up to {size} image bytes before compression",
          flush=True)
    archive = directory / "image.tar.gz"
    # Saving by config ID binds the archive to the tested image, even if a tag moves.
    with archive.open("xb") as target:
        with subprocess.Popen(["docker", "image", "save", options.image_id], stdout=subprocess.PIPE) as saved:
            with gzip.GzipFile(filename="", mode="wb", fileobj=target, compresslevel=1, mtime=0) as zipped:
                shutil.copyfileobj(saved.stdout, zipped)
            require(saved.wait() == 0, "docker image save failed")
    receipt = {"schema_version": 1, **expected, "archive_sha256": sha256(archive)}
    (directory / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2))


def remote_manifest(reference):
    # Buildx --raw emits the original bytes without an added newline.
    raw = docker("buildx", "imagetools", "inspect", "--raw", reference, capture=True)
    return json.loads(raw), "sha256:" + hashlib.sha256(raw).hexdigest()


def check_index(reference, expected_digests):
    manifest, digest = remote_manifest(reference)
    require(manifest.get("schemaVersion") == 2 and manifest.get("mediaType") in INDEX_TYPES,
            f"published reference is not an image index: {reference}")
    found = {}
    for item in manifest.get("manifests", []):
        platform = item.get("platform") or {}
        key = f"{platform.get('os')}/{platform.get('architecture')}"
        require(key not in found, "duplicate platform in published index")
        found[key] = item.get("digest")
    require(found == expected_digests, f"published index does not match verified images: {reference}")
    return digest


def publish_images(options, expected):
    platforms = options.platforms.split(",")
    require(platforms and len(set(platforms)) == len(platforms)
            and all(platform in PLATFORMS for platform in platforms), "invalid or duplicate platforms")
    require(re.fullmatch(r"[1-9][0-9]*", options.run_attempt), "invalid run attempt")
    require(len(options.repository) == len(set(options.repository)), "duplicate registry repository")
    for repository in options.repository:
        require(re.fullmatch(r"(?:ghcr\.io|docker\.io)/[a-z0-9]+(?:[._-][a-z0-9]+)*/deepseek-harness", repository),
                f"invalid release repository: {repository}")
    tags = list(dict.fromkeys([options.image_tag] + ([options.latest_tag] if options.latest_tag else [])))
    for tag in tags:
        require(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag), "invalid release tag")
    require(not options.directory.is_symlink() and options.directory.is_dir(), "invalid artifact root")
    names = {f"deepseek-harness-{expected['variant']}-image-{platform.split('/')[1]}" for platform in platforms}
    require({path.name for path in options.directory.iterdir()} == names, "missing or unexpected platform artifacts")
    artifacts = []
    for platform in platforms:
        directory = options.directory / f"deepseek-harness-{expected['variant']}-image-{platform.split('/')[1]}"
        receipt = check_archive(directory, {**expected, "platform": platform})
        artifacts.append((directory, receipt))
    if options.dry_run:
        print(json.dumps({"repositories": options.repository, "tags": tags,
                          "verified_images": [receipt for _, receipt in artifacts]}, indent=2))
        return

    # Validate every archive and loaded image before making the first registry write.
    for directory, receipt in artifacts:
        docker("image", "load", "--input", directory / "image.tar.gz")
        inspect_image(receipt["image_id"], receipt)

    staged = {}
    for repository in options.repository:
        staged[repository] = {}
        for _, receipt in artifacts:
            arch = receipt["platform"].split("/")[1]
            reference = f"{repository}:ci-{expected['run_id']}-{options.run_attempt}-{expected['variant']}-{arch}"
            docker("image", "tag", receipt["image_id"], reference)
            docker("image", "push", reference)
            manifest, digest = remote_manifest(reference)
            require(manifest.get("schemaVersion") == 2 and manifest.get("mediaType") in IMAGE_TYPES
                    and manifest.get("config", {}).get("digest") == receipt["image_id"],
                    f"pushed image does not match tested image ID: {reference}")
            staged[repository][receipt["platform"]] = digest

    # Both registries must have all images before updating release tags. Floating
    # tags follow only after the version tag has been verified in both registries.
    published = []
    for tag in tags:
        for repository, digests in staged.items():
            reference = f"{repository}:{tag}"
            docker("buildx", "imagetools", "create", "--prefer-index=true", "--tag", reference,
                   *(f"{repository}@{digest}" for digest in digests.values()))
            digest = check_index(reference, digests)
            published.append(f"{reference} -> {digest}")
    for item in published:
        print(item)
    if options.summary:
        with options.summary.open("a", encoding="utf-8") as summary:
            summary.write("\n### Published verified images\n\n" + "\n".join(f"- `{item}`" for item in published) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    export = subcommands.add_parser("export")
    publish = subcommands.add_parser("publish")
    for command in (export, publish):
        command.add_argument("--directory", type=Path, required=True)
        command.add_argument("--variant", choices=("runtime", "workstation"), required=True)
        command.add_argument("--revision", required=True)
        command.add_argument("--dsh-version", required=True)
        command.add_argument("--run-id", required=True)
    export.add_argument("--image", required=True)
    export.add_argument("--image-id", required=True)
    export.add_argument("--platform", choices=PLATFORMS, required=True)
    publish.add_argument("--platforms", required=True)
    publish.add_argument("--repository", action="append", required=True)
    publish.add_argument("--image-tag", required=True)
    publish.add_argument("--latest-tag")
    publish.add_argument("--run-attempt", default="1")
    publish.add_argument("--dry-run", action="store_true")
    publish.add_argument("--summary", type=Path)
    options = parser.parse_args()
    try:
        require(re.fullmatch(r"[a-f0-9]{40}", options.revision), "invalid workflow revision")
        require(re.fullmatch(r"[1-9][0-9]*", options.run_id), "invalid workflow run ID")
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", options.dsh_version), "invalid DSH version")
        expected = {key: getattr(options, key) for key in ("variant", "revision", "dsh_version", "run_id")}
        if options.command == "export":
            export_image(options, expected)
        else:
            publish_images(options, expected)
        return 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError, tarfile.TarError, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
