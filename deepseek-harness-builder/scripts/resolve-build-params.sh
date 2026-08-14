#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deepseek-harness-builder/configs/architectures.sh
source "${SCRIPT_DIR}/../configs/architectures.sh"

IMAGE_REPO="deepseek-harness"
PLATFORMS="linux/amd64,linux/arm64"
IMAGE_TAG="latest"
PUSH_LATEST="false"
LATEST_TAG="latest"
GITHUB_OUTPUT_PATH="${GITHUB_OUTPUT:-/dev/null}"

usage() {
  cat <<'EOF'
Usage: resolve-build-params.sh [options]

Options:
  --image-repo REPO       Lowercase OCI repository name
  --platforms LIST        Comma-separated target platforms
  --image-tag TAG         Primary image tag
  --push-latest BOOL      true or false
  --latest-tag TAG        Floating tag used by --push-latest
  --github-output FILE    GitHub Actions output file
  -h, --help              Show this help
EOF
}

require_value() {
  local option="$1"
  local count="$2"
  (( count >= 2 )) || {
    printf 'ERROR: %s requires a value\n' "${option}" >&2
    exit 2
  }
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-repo)
      require_value "$1" "$#"
      IMAGE_REPO="$2"
      shift 2
      ;;
    --platforms)
      require_value "$1" "$#"
      PLATFORMS="$2"
      shift 2
      ;;
    --image-tag)
      require_value "$1" "$#"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --push-latest)
      require_value "$1" "$#"
      PUSH_LATEST="$2"
      shift 2
      ;;
    --latest-tag)
      require_value "$1" "$#"
      LATEST_TAG="$2"
      shift 2
      ;;
    --github-output)
      require_value "$1" "$#"
      GITHUB_OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unsupported argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "${IMAGE_REPO}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]]; then
  printf 'ERROR: invalid image repository: %s\n' "${IMAGE_REPO}" >&2
  exit 1
fi

case "${PUSH_LATEST}" in
  true|false) ;;
  *)
    printf 'ERROR: push-latest must be true or false, got: %s\n' "${PUSH_LATEST}" >&2
    exit 1
    ;;
esac

IMAGE_TAG="${IMAGE_TAG#refs/tags/}"
IMAGE_TAG="${IMAGE_TAG#v}"
[[ -n "${IMAGE_TAG}" ]] || IMAGE_TAG="${LATEST_TAG}"

for tag_name in "${IMAGE_TAG}" "${LATEST_TAG}"; do
  if [[ ! "${tag_name}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    printf 'ERROR: invalid OCI image tag: %s\n' "${tag_name}" >&2
    exit 1
  fi
done

IFS=',' read -r -a requested_platforms <<< "${PLATFORMS}"
normalized_platforms=()
declare -A seen_platforms=()

for platform in "${requested_platforms[@]}"; do
  platform="$(trim "${platform}")"
  [[ -n "${platform}" ]] || {
    printf 'ERROR: platform list contains an empty entry\n' >&2
    exit 1
  }
  if ! is_supported_platform "${platform}"; then
    printf 'ERROR: unsupported platform: %s\n' "${platform}" >&2
    printf 'Supported platforms: %s\n' "${SUPPORTED_PLATFORMS[*]}" >&2
    exit 1
  fi
  if [[ -z "${seen_platforms[${platform}]:-}" ]]; then
    normalized_platforms+=("${platform}")
    seen_platforms["${platform}"]=1
  fi
done

(( ${#normalized_platforms[@]} > 0 )) || {
  printf 'ERROR: at least one platform is required\n' >&2
  exit 1
}
PLATFORMS="$(IFS=,; printf '%s' "${normalized_platforms[*]}")"

TAGS="type=raw,value=${IMAGE_TAG}"
if [[ "${PUSH_LATEST}" == "true" && "${IMAGE_TAG}" != "${LATEST_TAG}" ]]; then
  TAGS+=$'\n'"type=raw,value=${LATEST_TAG}"
fi

if [[ -n "${GITHUB_OUTPUT_PATH}" && "${GITHUB_OUTPUT_PATH}" != "/dev/null" ]]; then
  {
    printf 'image_repo=%s\n' "${IMAGE_REPO}"
    printf 'platforms=%s\n' "${PLATFORMS}"
    printf 'image_tag=%s\n' "${IMAGE_TAG}"
    printf 'latest_tag=%s\n' "${LATEST_TAG}"
    printf 'tags<<__DEEPSEEK_HARNESS_TAGS__\n%s\n__DEEPSEEK_HARNESS_TAGS__\n' "${TAGS}"
  } >> "${GITHUB_OUTPUT_PATH}"
fi

printf 'image_repo=%s\n' "${IMAGE_REPO}"
printf 'platforms=%s\n' "${PLATFORMS}"
printf 'image_tag=%s\n' "${IMAGE_TAG}"
printf 'tags=%s\n' "${TAGS//$'\n'/, }"
