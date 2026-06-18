#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=opencode-workstation-builder/configs/architectures.sh
source "$ROOT_DIR/configs/architectures.sh"

IMAGE_REPO="opencode-workstation"
DEFAULT_PLATFORMS="linux/amd64,linux/arm64"
PLATFORMS="$DEFAULT_PLATFORMS"
IMAGE_TAG=""
PUSH_LATEST="false"
LATEST_TAG="latest"
GITHUB_OUTPUT_PATH=""

usage() {
  cat <<USAGE
用途：解析 opencode-workstation 镜像构建参数，供 GitHub Actions 调用。

参数：
  --image-repo <name>         镜像仓库名（默认 opencode-workstation）
  --platforms <csv>           平台列表（默认 linux/amd64,linux/arm64）
  --image-tag <tag>           显式镜像标签；留空时默认 latest
  --push-latest <bool>        是否附带 latest 别名标签
  --latest-tag <tag>          附带别名标签名称（默认 latest）
  --github-output <path>      GitHub Actions 输出文件
  -h, --help                  查看帮助
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-repo) IMAGE_REPO="${2:-}"; shift 2 ;;
    --platforms) PLATFORMS="${2:-}"; shift 2 ;;
    --image-tag) IMAGE_TAG="${2:-}"; shift 2 ;;
    --push-latest) PUSH_LATEST="${2:-}"; shift 2 ;;
    --latest-tag) LATEST_TAG="${2:-}"; shift 2 ;;
    --github-output) GITHUB_OUTPUT_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[resolve][ERROR] 未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$IMAGE_REPO" ]] || { echo '[resolve][ERROR] --image-repo 不能为空' >&2; exit 2; }
[[ -n "$PLATFORMS" ]] || { echo '[resolve][ERROR] --platforms 不能为空' >&2; exit 2; }
[[ -n "$GITHUB_OUTPUT_PATH" ]] || { echo '[resolve][ERROR] --github-output 不能为空' >&2; exit 2; }

if [[ ! "${IMAGE_REPO}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]]; then
  echo "[resolve][ERROR] 镜像仓库名非法: ${IMAGE_REPO}" >&2
  echo '[resolve][ERROR] 镜像仓库名必须为小写，可使用点、下划线、短横线或斜线分隔' >&2
  exit 2
fi

case "${PUSH_LATEST}" in
  true|false) ;;
  *)
    echo "[resolve][ERROR] --push-latest 必须是 true 或 false: ${PUSH_LATEST}" >&2
    exit 2
    ;;
esac

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

sanitize_tag() {
  local raw="$1"
  raw="${raw#refs/tags/}"
  raw="${raw#v}"
  printf '%s' "$raw"
}

IMAGE_TAG="$(sanitize_tag "$IMAGE_TAG")"
if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="latest"
fi
if [[ ! "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "[resolve][ERROR] 镜像 tag 非法: ${IMAGE_TAG}" >&2
  exit 2
fi
if [[ ! "${LATEST_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "[resolve][ERROR] latest tag 非法: ${LATEST_TAG}" >&2
  exit 2
fi

IFS=',' read -r -a platform_items <<< "$PLATFORMS"
normalized_platforms=()
for item in "${platform_items[@]}"; do
  item="$(trim "$item")"
  if [[ -z "$item" ]]; then
    echo '[resolve][ERROR] 平台列表包含空项' >&2
    exit 2
  fi
  if ! is_supported_platform "$item"; then
    echo "[resolve][ERROR] 平台不在允许列表内: $item" >&2
    echo "[resolve][ERROR] 支持平台: ${TARGET_PLATFORMS[*]}" >&2
    exit 2
  fi
  normalized_platforms+=("$item")
done
PLATFORMS="$(IFS=,; echo "${normalized_platforms[*]}")"

TAGS="type=raw,value=${IMAGE_TAG}"
if [[ "$PUSH_LATEST" == "true" && "$IMAGE_TAG" != "$LATEST_TAG" ]]; then
  TAGS+=$'\n'"type=raw,value=${LATEST_TAG}"
fi

{
  echo "image_repo=$IMAGE_REPO"
  echo "platforms=$PLATFORMS"
  echo "image_tag=$IMAGE_TAG"
  echo "latest_tag=$LATEST_TAG"
  echo "tags<<__EOF__"
  printf '%s\n' "$TAGS"
  echo "__EOF__"
} >> "$GITHUB_OUTPUT_PATH"

printf '[resolve] image_repo=%s\n' "$IMAGE_REPO"
printf '[resolve] platforms=%s\n' "$PLATFORMS"
printf '[resolve] image_tag=%s\n' "$IMAGE_TAG"
printf '[resolve] tags=%s\n' "${TAGS//$'\n'/, }"
