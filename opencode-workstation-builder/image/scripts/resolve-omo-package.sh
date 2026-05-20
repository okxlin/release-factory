#!/usr/bin/env bash
set -euo pipefail

: "${OMO_PACKAGE:=}"
: "${OMO_PACKAGE_AMD64:=oh-my-opencode-linux-x64}"
: "${OMO_PACKAGE_AMD64_BASELINE:=oh-my-opencode-linux-x64-baseline}"
: "${OMO_PACKAGE_ARM64:=oh-my-opencode-linux-arm64}"
: "${OMO_FORCE_BASELINE:=auto}"

normalize_bool() {
  case "${1,,}" in
    1|yes|true|on) printf 'yes' ;;
    0|no|false|off) printf 'no' ;;
    *) printf '%s' "$1" ;;
  esac
}

has_avx2() {
  [[ -r /proc/cpuinfo ]] && grep -qiE '(^|[[:space:]])avx2($|[[:space:]])' /proc/cpuinfo
}

if [[ -n "${OMO_PACKAGE}" ]]; then
  printf '%s\n' "${OMO_PACKAGE}"
  exit 0
fi

arch="$(uname -m)"
force_baseline="$(normalize_bool "${OMO_FORCE_BASELINE}")"

case "${arch}" in
  x86_64|amd64)
    if [[ "${force_baseline}" == "yes" ]]; then
      printf '%s\n' "${OMO_PACKAGE_AMD64_BASELINE}"
      exit 0
    fi

    if [[ "${force_baseline}" != "no" ]] && ! has_avx2; then
      printf '%s\n' "${OMO_PACKAGE_AMD64_BASELINE}"
      exit 0
    fi

    printf '%s\n' "${OMO_PACKAGE_AMD64}"
    ;;
  aarch64|arm64)
    printf '%s\n' "${OMO_PACKAGE_ARM64}"
    ;;
  *)
    printf '%s\n' 'oh-my-opencode'
    ;;
esac
