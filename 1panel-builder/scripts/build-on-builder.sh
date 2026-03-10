#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/configs/architectures.sh"

VERSION="v2.1.3"
ARCH="all"
OUTPUT_DIR="$ROOT_DIR/output/build"
EXECUTE=0
WORKDIR="${WORKDIR:-/opt/1panel-build-pipeline}"

usage() {
  cat <<USAGE
用途：在测试机执行 1Panel v2.1.3 多架构构建。
注意：禁止本机编译。本脚本仅用于“测试机”执行；默认 dry-run。

参数：
  --version <v2.1.3>      源码版本（默认 v2.1.3）
  --arch <all|auto|arch>  all/auto 或单架构（amd64/arm64/armv7/ppc64le/s390x）
  --output-dir <dir>      构建输出目录
  --execute               真正执行构建命令
  -h, --help              查看帮助
USAGE
}

log() { printf '[build] %s
' "$*"; }
err() { printf '[build][ERROR] %s
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

verify_bin() {
  local bin="$1"
  local kind="$2"

  [[ -f "$bin" ]] || { err "$kind 文件不存在: $bin"; return 1; }

  local file_out
  file_out="$(file -b "$bin" 2>/dev/null || true)"
  if [[ "$file_out" != *"ELF"* ]]; then
    err "$kind 非 ELF 文件: $bin (file: $file_out)"
    return 1
  fi

  local bin_sha true_sha
  bin_sha="$(sha256sum "$bin" | awk '{print $1}')"
  if [[ -x /usr/bin/true ]]; then
    true_sha="$(sha256sum /usr/bin/true | awk '{print $1}')"
    if [[ "$bin_sha" == "$true_sha" ]]; then
      err "$kind 与 /usr/bin/true SHA256 相同，拒绝继续: $bin"
      return 1
    fi
  fi

  local s
  s="$(strings -a "$bin" 2>/dev/null || true)"
if printf '%s
' "$s" | grep -Ei 'GNU coreutils|/usr/bin/true' >/dev/null; then
    err "$kind 命中黑名单字符串(GNU coreutils 或 /usr/bin/true): $bin"
    return 1
  fi

if ! printf '%s
' "$s" | grep -Ei '1panel|1Panel-dev' >/dev/null; then
    if command -v go >/dev/null 2>&1; then
      if ! go version -m "$bin" 2>/dev/null | grep -Ei '1Panel-dev/1Panel|1panel' >/dev/null; then
        err "$kind 未命中白名单字符串(1panel/1Panel-dev)且 Go metadata 校验失败: $bin"
        return 1
      fi
    else
      err "$kind 未命中白名单字符串(1panel/1Panel-dev)，且无 go 命令执行替代校验: $bin"
      return 1
    fi
  fi

  log "verify_bin 通过: kind=$kind file=$bin sha256=$bin_sha"
}

version_ge() {
  local current="$1"
  local required="$2"
  [[ "$(printf '%s
%s
' "$required" "$current" | sort -V | tail -n1)" == "$current" ]]
}

check_runtime_versions() {
  local go_raw go_ver node_raw node_ver

  if ! command -v go >/dev/null 2>&1; then
    err "未检测到 go，请安装 Go >= 1.24"
    exit 5
  fi
  if ! command -v node >/dev/null 2>&1; then
    err "未检测到 node，请安装 Node.js >= 22.12"
    exit 5
  fi

  go_raw="$(go version | awk '{print $3}')"
  go_ver="${go_raw#go}"
  node_raw="$(node -v)"
  node_ver="${node_raw#v}"

  if ! version_ge "$go_ver" "1.24"; then
    err "Go 版本过低: 当前 $go_ver，要求 >= 1.24"
    exit 5
  fi
  if ! version_ge "$node_ver" "22.12"; then
    err "Node.js 版本过低: 当前 $node_ver，要求 >= 22.12"
    exit 5
  fi

  log "版本检查通过: go=$go_ver node=$node_ver"
}

map_goarch() {
  case "$1" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    armv7) echo "arm" ;;
    ppc64le) echo "ppc64le" ;;
    s390x) echo "s390x" ;;
    *) return 1 ;;
  esac
}

map_goarm() {
  case "$1" in
    armv7) echo "7" ;;
    *) echo "" ;;
  esac
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

if [[ "$ARCH" == "auto" ]]; then
  ARCH="$(get_arch_from_uname || true)"
  [[ -n "$ARCH" ]] || { err "无法从 uname 自动识别架构"; exit 2; }
  log "自动识别架构: $ARCH"
fi

if [[ "$ARCH" != "all" ]] && ! is_supported_arch "$ARCH"; then
  err "不支持的架构: $ARCH"
  exit 2
fi

check_runtime_versions

mkdir -p "$OUTPUT_DIR"
run_cmd "mkdir -p '$WORKDIR'"
run_cmd "git -C '$WORKDIR' clone --depth=1 --branch '$VERSION' https://github.com/1Panel-dev/1Panel.git 1Panel-src || true"
run_cmd "git -C '$WORKDIR/1Panel-src' fetch --tags --force"
run_cmd "git -C '$WORKDIR/1Panel-src' checkout '$VERSION'"

# frontend 构建顺序：安装依赖 -> 构建
run_cmd "cd '$WORKDIR/1Panel-src/frontend' && npm install"
run_cmd "cd '$WORKDIR/1Panel-src/frontend' && npm run build:pro"

build_one() {
  local a="$1"
  local goarch
  goarch="$(map_goarch "$a")" || { err "架构映射失败: $a"; exit 3; }
  local goarm
  goarm="$(map_goarm "$a")"
  local out_dir="$OUTPUT_DIR/$a"

  run_cmd "mkdir -p '$out_dir'"

  local core_build_cmd="cd '$WORKDIR/1Panel-src/core' && mkdir -p build && \
CGO_ENABLED=0 GOOS=linux GOARCH=$goarch"

  if [[ -n "$goarm" ]]; then
    core_build_cmd+=" GOARM=$goarm"
  fi

  core_build_cmd+=" go build -trimpath -ldflags '-s -w' -o 'build/1panel-core-$a' ./cmd/server"
  run_cmd "$core_build_cmd"

  local agent_build_cmd="cd '$WORKDIR/1Panel-src/agent' && mkdir -p build && \
CGO_ENABLED=0 GOOS=linux GOARCH=$goarch"

  if [[ -n "$goarm" ]]; then
    agent_build_cmd+=" GOARM=$goarm"
  fi

  agent_build_cmd+=" go build -trimpath -ldflags '-s -w' -o 'build/1panel-agent-$a' ./cmd/server"
  run_cmd "$agent_build_cmd"

  run_cmd "cp '$WORKDIR/1Panel-src/core/build/1panel-core-$a' '$out_dir/'"
  run_cmd "cp '$WORKDIR/1Panel-src/agent/build/1panel-agent-$a' '$out_dir/'"
  # 兼容旧流程（仅识别 1panel-$arch）
  run_cmd "cp '$WORKDIR/1Panel-src/core/build/1panel-core-$a' '$out_dir/1panel-$a'"

  if [[ "$EXECUTE" -eq 1 ]]; then
    verify_bin "$out_dir/1panel-core-$a" "core" || exit 6
    verify_bin "$out_dir/1panel-agent-$a" "agent" || exit 6
  fi

  run_cmd "sha256sum '$out_dir/1panel-core-$a' > '$out_dir/1panel-core-$a.sha256'"
  run_cmd "sha256sum '$out_dir/1panel-agent-$a' > '$out_dir/1panel-agent-$a.sha256'"
  run_cmd "sha256sum '$out_dir/1panel-$a' > '$out_dir/1panel-$a.sha256'"
}

if [[ "$ARCH" == "all" ]]; then
  for a in "${TARGET_ARCHS[@]}"; do
    log "准备构建架构: $a"
    build_one "$a"
  done
else
  build_one "$ARCH"
fi

log "构建命令流程完成。输出目录: $OUTPUT_DIR"
