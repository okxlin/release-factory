#!/usr/bin/env bash
# resolve-build-params.sh — CI-facing build parameter resolver
# Parses workflow inputs, validates platforms, sanitizes tags,
# and writes outputs for downstream workflow steps.
#
# Usage: source scripts/resolve-build-params.sh [--image-repo REPO] [--platforms LIST] [--image-tag TAG] [--push-latest BOOL] [--latest-tag TAG] [--github-output FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../configs/architectures.sh"

# Defaults
IMAGE_REPO="codex-web-workstation"
PLATFORMS="linux/amd64"
IMAGE_TAG="latest"
PUSH_LATEST="false"
LATEST_TAG="latest"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-repo) IMAGE_REPO="$2"; shift 2 ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --push-latest) PUSH_LATEST="$2"; shift 2 ;;
    --latest-tag) LATEST_TAG="$2"; shift 2 ;;
    --github-output) GITHUB_OUTPUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Sanitize tag: strip refs/tags/ and leading 'v'
IMAGE_TAG="${IMAGE_TAG#refs/tags/}"
IMAGE_TAG="${IMAGE_TAG#v}"

# Validate platforms
IFS=',' read -ra PLATFORM_LIST <<< "$PLATFORMS"
for platform in "${PLATFORM_LIST[@]}"; do
  platform="$(echo "$platform" | xargs)"
  if ! is_supported_platform "$platform"; then
    echo "ERROR: Unsupported platform: $platform" >&2
    echo "Supported: ${SUPPORTED_PLATFORMS[*]}" >&2
    exit 1
  fi
done

# Write GitHub Actions outputs
if [ -n "${GITHUB_OUTPUT}" ] && [ "${GITHUB_OUTPUT}" != "/dev/null" ]; then
  cat >> "${GITHUB_OUTPUT}" <<EOF
image-repo=${IMAGE_REPO}
platforms=${PLATFORMS}
image-tag=${IMAGE_TAG}
push-latest=${PUSH_LATEST}
latest-tag=${LATEST_TAG}
EOF
fi

echo "image-repo=${IMAGE_REPO}"
echo "platforms=${PLATFORMS}"
echo "image-tag=${IMAGE_TAG}"
echo "push-latest=${PUSH_LATEST}"
echo "latest-tag=${LATEST_TAG}"