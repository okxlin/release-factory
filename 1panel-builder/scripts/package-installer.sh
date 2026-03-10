#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/configs/architectures.sh"

VERSION="v2.1.3"
ARCH="all"
OUTPUT_DIR="$ROOT_DIR/output/package"
EXECUTE=0
WORKDIR="${WORKDIR:-/opt/1panel-build-pipeline}"
INSTALLER_REPO="https://github.com/1Panel-dev/installer.git"
ALLOW_LEGACY_FALLBACK="${ALLOW_LEGACY_FALLBACK:-0}"

usage() {
  cat <<USAGE
用途：基于 1Panel installer 仓库组装“完整安装包”。
默认 dry-run，不进行危险操作。

参数：
  --version <v2.1.3>
  --arch <all|auto|arch>
  --output-dir <dir>
  --execute
  -h, --help

环境变量：
  ALLOW_LEGACY_FALLBACK=1 允许旧产物名回退（默认关闭）
USAGE
}

log() { printf '[package] %s
' "$*"; }
err() { printf '[package][ERROR] %s
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
      err "$kind 与 /usr/bin/true SHA256 相同，拒绝打包: $bin"
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
    # 最小替代校验：命名必须符合 1panel 二进制规范（避免误收其它 ELF）
    if [[ "$(basename "$bin")" != 1panel-core-* && "$(basename "$bin")" != 1panel-agent-* ]]; then
      err "$kind 未命中白名单字符串(1panel/1Panel-dev)，且文件名不符合最小替代校验: $bin"
      return 1
    fi
  fi

  log "verify_bin 通过: kind=$kind file=$bin sha256=$bin_sha"
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

OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

resolve_bin() {
  local a="$1"
  local kind="$2"
  local base="$ROOT_DIR/output/build/$a"
  local candidates=()

  case "$kind" in
    core)
      candidates=("$base/1panel-core-$a")
      if [[ "$ALLOW_LEGACY_FALLBACK" == "1" ]]; then
        candidates+=("$base/1panel-core" "$base/1panel-$a")
      fi
      ;;
    agent)
      candidates=("$base/1panel-agent-$a")
      if [[ "$ALLOW_LEGACY_FALLBACK" == "1" ]]; then
        candidates+=("$base/1panel-agent")
      fi
      ;;
    *)
      return 2
      ;;
  esac

  local f
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      printf '%s' "$f"
      return 0
    fi
  done

  return 1
}

run_cmd "mkdir -p '$WORKDIR' '$OUTPUT_DIR'"
run_cmd "git -C '$WORKDIR' clone '$INSTALLER_REPO' installer-src || true"
run_cmd "git -C '$WORKDIR/installer-src' fetch --tags --force"
run_cmd "git -C '$WORKDIR/installer-src' checkout '$VERSION' || git -C '$WORKDIR/installer-src' checkout v2 || git -C '$WORKDIR/installer-src' checkout main || git -C '$WORKDIR/installer-src' checkout master"

package_one() {
  local a="$1"
  local out_dir="$OUTPUT_DIR/$a"
  local stage="$WORKDIR/stage-$a"
  local out_tar="$out_dir/1panel-installer-${VERSION}-${a}.tar.gz"

  local src_core src_agent
  if [[ "$EXECUTE" -eq 1 ]]; then
    src_core="$(resolve_bin "$a" core)" || {
      err "缺少 core 构建产物，默认仅接受: $ROOT_DIR/output/build/$a/1panel-core-$a (可设 ALLOW_LEGACY_FALLBACK=1 放宽)"
      exit 4
    }
    src_agent="$(resolve_bin "$a" agent)" || {
      err "缺少 agent 构建产物，默认仅接受: $ROOT_DIR/output/build/$a/1panel-agent-$a (可设 ALLOW_LEGACY_FALLBACK=1 放宽)"
      exit 4
    }

    verify_bin "$src_core" "core" || exit 6
    verify_bin "$src_agent" "agent" || exit 6
  else
    src_core="$ROOT_DIR/output/build/$a/1panel-core-$a"
    src_agent="$ROOT_DIR/output/build/$a/1panel-agent-$a"
  fi

  run_cmd "rm -rf '$stage' && mkdir -p '$stage' '$out_dir'"
  run_cmd "cp -r '$WORKDIR/installer-src/'* '$stage/'"

  # install.sh 预期根目录文件
  run_cmd "cp '$src_core' '$stage/1panel-core'"
  run_cmd "cp '$src_agent' '$stage/1panel-agent'"
  run_cmd "chmod +x '$stage/1panel-core' '$stage/1panel-agent' '$stage/1pctl'"

  # GeoIP.mmdb: install.sh 会 cp 该文件，若 installer 仓库无该文件则补一个占位文件以避免安装中断
  run_cmd "if [[ ! -f '$stage/GeoIP.mmdb' ]]; then install -m 0644 /dev/null '$stage/GeoIP.mmdb'; fi"

  run_cmd "cd '$stage' && tar -czf '$out_tar' ."
  run_cmd "sha256sum '$out_tar' > '$out_tar.sha256'"
}

if [[ "$ARCH" == "all" ]]; then
  for a in "${TARGET_ARCHS[@]}"; do
    log "组装安装包: $a"
    package_one "$a"
  done
else
  package_one "$ARCH"
fi

log "安装包流程完成。输出目录: $OUTPUT_DIR"
