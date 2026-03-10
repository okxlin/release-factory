#!/usr/bin/env bash
set -euo pipefail

# 统一维护目标架构（硬性要求）
TARGET_ARCHS=(
  "amd64"
  "arm64"
  "armv7"
  "ppc64le"
  "s390x"
)

is_supported_arch() {
  local arch="${1:-}"
  for a in "${TARGET_ARCHS[@]}"; do
    if [[ "$a" == "$arch" ]]; then
      return 0
    fi
  done
  return 1
}

# 从 uname -a 推断当前架构（与用户给定规则一致）
# 返回：amd64/arm64/armv7/ppc64le/s390x；失败则返回非零
get_arch_from_uname() {
  local osCheck
  osCheck="$(uname -a)"
  if [[ "$osCheck" =~ 'x86_64' ]]; then
    echo "amd64"
  elif [[ "$osCheck" =~ 'arm64' ]] || [[ "$osCheck" =~ 'aarch64' ]]; then
    echo "arm64"
  elif [[ "$osCheck" =~ 'armv7l' ]]; then
    echo "armv7"
  elif [[ "$osCheck" =~ 'ppc64le' ]]; then
    echo "ppc64le"
  elif [[ "$osCheck" =~ 's390x' ]]; then
    echo "s390x"
  else
    return 1
  fi
}
