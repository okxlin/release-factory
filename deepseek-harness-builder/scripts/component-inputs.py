#!/usr/bin/env python3
"""Resolve the same immutable build inputs for local builds and GitHub Actions."""

import argparse
import json
from pathlib import Path
import re
import sys


SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")
SHA256 = re.compile(r"[a-f0-9]{64}")
COMMIT = re.compile(r"[a-f0-9]{40}")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def valid_version(value):
    return isinstance(value, str) and SEMVER.fullmatch(value) and all(
        not (part.isdigit() and len(part) > 1 and part.startswith("0"))
        for part in value.partition("-")[2].split(".")
    )


def load_inputs(components_file, source_file, dsh_version=None):
    lock = json.loads(components_file.read_text(encoding="utf-8"))
    require(isinstance(lock, dict) and set(lock) == {"schema_version", "build_args"}
            and lock["schema_version"] == 1, "invalid component lock schema")
    require(isinstance(lock["build_args"], dict) and lock["build_args"], "missing component build args")
    args = dict(lock["build_args"])
    for name, value in args.items():
        require(re.fullmatch(r"[A-Z][A-Z0-9_]*", name) and not name.startswith("DSH_"), f"invalid component key: {name}")
        require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:/@+=-]+", value), f"invalid component value: {name}")
        if "SHA256" in name:
            require(SHA256.fullmatch(value), f"ARG {name} must be a lowercase SHA-256 digest")
        elif name.endswith("_VERSION"):
            require(valid_version(value), f"ARG {name} must be an exact semantic version")
        elif name.endswith("_REF"):
            require(COMMIT.fullmatch(value), f"ARG {name} must be an immutable Git commit")
        elif name.endswith("_IMAGE"):
            require(re.fullmatch(r"[^@]+:[^@]+@sha256:[a-f0-9]{64}", value), f"ARG {name} must pin an image tag and digest")
        else:
            raise ValueError(f"unknown component input: {name}")

    source = json.loads(source_file.read_text(encoding="utf-8"))
    require(isinstance(source, dict), "invalid DSH source metadata")
    version = source.get("version", "")
    commit = source.get("commit", "")
    checksum = source.get("archiveSha256", "")
    require(valid_version(version), "DSH source must use an exact semantic version")
    require(source.get("repository") == "deepseek-ai/deepseek-harness", "unexpected DSH source repository")
    require(source.get("ref") == f"dsh-v{version}", "DSH source tag does not match version")
    require(isinstance(commit, str) and COMMIT.fullmatch(commit), "DSH source must pin an immutable commit")
    require(isinstance(checksum, str) and SHA256.fullmatch(checksum), "invalid DSH source archive checksum")
    require(source.get("archiveUrl") == f"https://codeload.github.com/deepseek-ai/deepseek-harness/tar.gz/{commit}",
            "DSH source archive URL must name the resolved commit")
    resolved_version = dsh_version or version
    require(valid_version(resolved_version), "DSH build version must be an exact semantic version")
    args.update({
        "DSH_VERSION": resolved_version,
        "DSH_SOURCE_VERSION": version,
        "DSH_SOURCE_REF": source["ref"],
        "DSH_SOURCE_COMMIT": commit,
        "DSH_SOURCE_ARCHIVE_SHA256": checksum,
    })
    return args


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image-dir", type=Path, default=Path(__file__).resolve().parents[1] / "image")
    parser.add_argument("--components-file", type=Path)
    parser.add_argument("--source-file", type=Path)
    parser.add_argument("--dsh-version")
    parser.add_argument("--format", choices=("env", "json"), default="env")
    parser.add_argument("--github-output", type=Path)
    options = parser.parse_args()
    try:
        args = load_inputs(options.components_file or options.image_dir / "components.lock.json",
                           options.source_file or options.image_dir / "dsh-source.json", options.dsh_version)
        lines = "\n".join(f"{key}={value}" for key, value in sorted(args.items()))
        if options.github_output:
            with options.github_output.open("a", encoding="utf-8") as output:
                output.write(f"build_args<<COMPONENT_INPUTS\n{lines}\nCOMPONENT_INPUTS\n")
                for component in ("node", "go", "pnpm"):
                    output.write(f"{component}_version={args[component.upper() + '_VERSION']}\n")
                output.write(f"dsh_version={args['DSH_VERSION']}\n")
        print(json.dumps(args, indent=2) if options.format == "json" else lines)
        return 0
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
