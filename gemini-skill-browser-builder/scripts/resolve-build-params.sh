#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/configs/architectures.sh"

IMAGE_REPO="gemini-skill-browser"
DEFAULT_PLATFORM="linux/amd64"
IMAGE_TAG=""
DEFAULT_BROWSER_BASE_TAG="1.18.0"
BROWSER_BASE_TAG="$DEFAULT_BROWSER_BASE_TAG"
GEMINI_SKILL_REF="main"
PUSH_LATEST="false"
LATEST_TAG="latest-kasm"
GITHUB_OUTPUT_PATH=""

usage() {
  cat <<USAGE
用途：解析 Gemini Skill Browser 的镜像构建参数，供 GitHub Actions 调用。

参数：
  --image-repo <name>         镜像仓库名（默认 gemini-skill-browser）
  --default-platform <plat>   默认平台（默认 linux/amd64）
  --browser-base-tag <tag>    浏览器底座镜像 tag（手动输入）
  --image-tag <tag>           显式镜像标签；留空时默认跟随浏览器 tag 并追加 -kasm
  --gemini-skill-ref <ref>    gemini-skill git ref
  --push-latest <bool>        是否附带别名标签
  --latest-tag <tag>          附带别名标签名称（默认 latest）
  --github-output <path>      GitHub Actions 输出文件
  -h, --help                  查看帮助
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-repo) IMAGE_REPO="${2:-}"; shift 2 ;;
    --default-platform) DEFAULT_PLATFORM="${2:-}"; shift 2 ;;
    --browser-base-tag) BROWSER_BASE_TAG="${2:-}"; shift 2 ;;
    --image-tag) IMAGE_TAG="${2:-}"; shift 2 ;;
    --gemini-skill-ref) GEMINI_SKILL_REF="${2:-}"; shift 2 ;;
    --push-latest) PUSH_LATEST="${2:-}"; shift 2 ;;
    --latest-tag) LATEST_TAG="${2:-}"; shift 2 ;;
    --github-output) GITHUB_OUTPUT_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[resolve][ERROR] 未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$IMAGE_REPO" ]] || { echo '[resolve][ERROR] --image-repo 不能为空' >&2; exit 2; }
[[ -n "$DEFAULT_PLATFORM" ]] || { echo '[resolve][ERROR] --default-platform 不能为空' >&2; exit 2; }
[[ -n "$GEMINI_SKILL_REF" ]] || { echo '[resolve][ERROR] --gemini-skill-ref 不能为空' >&2; exit 2; }
[[ -n "$GITHUB_OUTPUT_PATH" ]] || { echo '[resolve][ERROR] --github-output 不能为空' >&2; exit 2; }

if ! is_supported_platform "$DEFAULT_PLATFORM"; then
  echo "[resolve][ERROR] 默认平台不在允许列表内: $DEFAULT_PLATFORM" >&2
  exit 2
fi

sanitize_tag() {
  local raw="$1"
  raw="${raw#refs/tags/}"
  raw="${raw#v}"
  printf '%s' "$raw"
}

BROWSER_BASE_TAG="$(sanitize_tag "$BROWSER_BASE_TAG")"
if [[ -z "$BROWSER_BASE_TAG" ]]; then
  BROWSER_BASE_TAG="$DEFAULT_BROWSER_BASE_TAG"
fi

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="${BROWSER_BASE_TAG}-kasm"
else
  IMAGE_TAG="$(sanitize_tag "$IMAGE_TAG")"
fi
[[ -n "$IMAGE_TAG" ]] || { echo '[resolve][ERROR] 规范化后 image tag 为空' >&2; exit 2; }

TAGS="type=raw,value=${IMAGE_TAG}"
if [[ "$PUSH_LATEST" == "true" ]]; then
  [[ -n "$LATEST_TAG" ]] || { echo '[resolve][ERROR] --latest-tag 不能为空' >&2; exit 2; }
  TAGS+=$'\n'"type=raw,value=${LATEST_TAG}"
fi

{
  echo "image_repo=$IMAGE_REPO"
  echo "platforms=$DEFAULT_PLATFORM"
  echo "gemini_skill_ref=$GEMINI_SKILL_REF"
  echo "browser_base_tag=$BROWSER_BASE_TAG"
  echo "image_tag=$IMAGE_TAG"
  echo "latest_tag=$LATEST_TAG"
  echo "tags<<__EOF__"
  printf '%s\n' "$TAGS"
  echo "__EOF__"
} >> "$GITHUB_OUTPUT_PATH"

printf '[resolve] image_repo=%s\n' "$IMAGE_REPO"
printf '[resolve] platforms=%s\n' "$DEFAULT_PLATFORM"
printf '[resolve] gemini_skill_ref=%s\n' "$GEMINI_SKILL_REF"
printf '[resolve] browser_base_tag=%s\n' "$BROWSER_BASE_TAG"
printf '[resolve] image_tag=%s\n' "$IMAGE_TAG"
printf '[resolve] tags=%s\n' "${TAGS//$'\n'/, }"
