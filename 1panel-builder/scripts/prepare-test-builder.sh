#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="v2.1.3"
ARCH="all"
OUTPUT_DIR="$ROOT_DIR/output"
EXECUTE=0
BUILDER_NAME="panel-multiarch"

usage() {
  cat <<USAGE
用途：在测试机准备多架构构建环境（Docker + buildx + QEMU/binfmt）。
注意：默认 dry-run，仅打印将执行的命令；加 --execute 才会真正执行。

参数：
  --version <v2.1.3>      1Panel 版本（记录用途，默认 v2.1.3）
  --arch <all|arch>       目标架构（默认 all）
  --output-dir <dir>      输出目录（默认: $OUTPUT_DIR）
  --execute               真正执行命令
  -h, --help              查看帮助
USAGE
}

log() { printf '[prepare] %s
' "$*"; }
err() { printf '[prepare][ERROR] %s
' "$*" >&2; }

run_cmd() {
  local cmd="$*"
  if [[ "$EXECUTE" -eq 1 ]]; then
    log "EXEC: $cmd"
    eval "$cmd"
  else
    log "DRY-RUN: $cmd"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || { err '--version 不能为空'; exit 2; }
[[ -n "$ARCH" ]] || { err '--arch 不能为空'; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || { err '--output-dir 不能为空'; exit 2; }

mkdir -p "$OUTPUT_DIR"
log "开始准备测试机构建环境: version=$VERSION arch=$ARCH output=$OUTPUT_DIR"
log "说明：本流程编译二进制不依赖docker，docker仅用于可选多架构容器构建/辅助。"

# 以下命令在测试机执行（Ubuntu/Debian 样例）
run_cmd "sudo apt-get update"
run_cmd "sudo apt-get install -y ca-certificates curl git jq tar xz-utils"

# docker 已安装时跳过 docker.io，避免与 docker-ce 冲突
if [[ "$EXECUTE" -eq 1 ]]; then
  if command -v docker >/dev/null 2>&1; then
    log "检测到 docker 命令已存在，跳过 docker.io 安装"
  else
    run_cmd "sudo apt-get install -y docker.io"
  fi
else
  log "DRY-RUN: if command -v docker >/dev/null 2>&1; then skip docker.io install; else sudo apt-get install -y docker.io; fi"
fi
run_cmd "sudo apt-get install -y qemu-user-static binfmt-support"

# buildx 与 qemu/binfmt（可选）
if [[ "$EXECUTE" -eq 1 ]]; then
  if command -v docker >/dev/null 2>&1; then
    if docker buildx version >/dev/null 2>&1; then
      log "检测到 docker buildx，执行可选 buildx/binfmt 配置"
      run_cmd "sudo docker run --privileged --rm tonistiigi/binfmt --install all"
      # 兼容旧版 buildx: 可能不支持 --name
      if sudo docker buildx create --name "$BUILDER_NAME" --use >/dev/null 2>&1; then
        log "buildx builder 创建成功（--name）: $BUILDER_NAME"
      elif sudo docker buildx create --use >/dev/null 2>&1; then
        log "buildx create 不支持 --name，已回退到不带 --name 的创建方式"
      elif sudo docker buildx use "$BUILDER_NAME" >/dev/null 2>&1; then
        log "复用已存在 builder: $BUILDER_NAME"
      else
        err "buildx builder 初始化失败，已跳过（不影响二进制编译流程）"
      fi
      run_cmd "sudo docker buildx inspect --bootstrap || true"
      run_cmd "sudo docker buildx ls || true"
    else
      log "未检测到 docker buildx，跳过 buildx/binfmt 可选步骤（不影响二进制编译）"
    fi
  else
    log "未检测到 docker，跳过 buildx/binfmt 可选步骤（不影响二进制编译）"
  fi
else
  log "DRY-RUN: if docker and docker buildx available, run optional binfmt/buildx setup; otherwise skip and continue"
fi

# 验证 binfmt（可选）
run_cmd "update-binfmts --display | grep -E 'aarch64|arm|ppc64le|s390x' || true"

log "准备步骤已生成。若需多架构容器构建可使用 docker/buildx；仅编译二进制可直接进入下一步。"
