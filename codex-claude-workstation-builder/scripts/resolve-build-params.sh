#!/usr/bin/env bash
# resolve-build-params.sh — CI-facing build parameter resolver
# Parses workflow inputs, validates platforms, sanitizes tags,
# and writes outputs for downstream workflow steps.
#
# Usage: source scripts/resolve-build-params.sh [--image-repo REPO] [--platforms LIST] [--image-tag TAG] [--push-latest BOOL] [--latest-tag TAG] [--github-output FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-claude-workstation-builder/configs/architectures.sh
source "${SCRIPT_DIR}/../configs/architectures.sh"

# Defaults
IMAGE_REPO="codex-claude-workstation"
PLATFORMS="linux/amd64,linux/arm64"
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

if [[ ! "${IMAGE_REPO}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]]; then
  echo "ERROR: Invalid image repo: ${IMAGE_REPO}" >&2
  echo "Docker repository names must be lowercase and may use dot, underscore, dash, or slash separators." >&2
  exit 1
fi

case "${PUSH_LATEST}" in
  true|false) ;;
  *)
    echo "ERROR: push-latest must be true or false, got: ${PUSH_LATEST}" >&2
    exit 1
    ;;
esac

# Sanitize tag: strip refs/tags/ and leading 'v'
IMAGE_TAG="${IMAGE_TAG#refs/tags/}"
IMAGE_TAG="${IMAGE_TAG#v}"
if [ -z "${IMAGE_TAG}" ]; then
  IMAGE_TAG="${LATEST_TAG}"
fi
if [[ ! "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "ERROR: Invalid image tag: ${IMAGE_TAG}" >&2
  echo "Docker tags must be 1-128 chars and use only letters, numbers, underscore, dot, and dash." >&2
  exit 1
fi
if [[ ! "${LATEST_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "ERROR: Invalid latest tag: ${LATEST_TAG}" >&2
  exit 1
fi

# Validate platforms
IFS=',' read -ra PLATFORM_LIST <<< "$PLATFORMS"
NORMALIZED_PLATFORMS=()
for platform in "${PLATFORM_LIST[@]}"; do
  platform="$(echo "$platform" | xargs)"
  if ! is_supported_platform "$platform"; then
    echo "ERROR: Unsupported platform: $platform" >&2
    echo "Supported: ${SUPPORTED_PLATFORMS[*]}" >&2
    exit 1
  fi
  NORMALIZED_PLATFORMS+=("$platform")
done
PLATFORMS="$(IFS=,; echo "${NORMALIZED_PLATFORMS[*]}")"

# Write GitHub Actions outputs
# Build tags for docker/metadata-action
TAGS="type=raw,value=${IMAGE_TAG}"
if [[ "$PUSH_LATEST" == "true" && "$IMAGE_TAG" != "$LATEST_TAG" ]]; then
  TAGS+=$'\n'"type=raw,value=${LATEST_TAG}"
fi

# Write GitHub Actions outputs (underscore keys required)
if [ -n "${GITHUB_OUTPUT}" ] && [ "${GITHUB_OUTPUT}" != "/dev/null" ]; then
  {
    echo "image_repo=${IMAGE_REPO}"
    echo "platforms=${PLATFORMS}"
    echo "image_tag=${IMAGE_TAG}"
    echo "latest_tag=${LATEST_TAG}"
    echo "tags<<__EOF__"
    printf '%s\n' "$TAGS"
    echo "__EOF__"
  } >> "${GITHUB_OUTPUT}"
fi

echo "image_repo=${IMAGE_REPO}"
echo "platforms=${PLATFORMS}"
echo "image_tag=${IMAGE_TAG}"
echo "tags=${TAGS//$'\n'/, }"
