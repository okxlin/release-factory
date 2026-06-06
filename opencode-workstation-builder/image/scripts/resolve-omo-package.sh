#!/usr/bin/env bash
set -euo pipefail

: "${OMO_PACKAGE:=}"
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

# Honour explicit OMO_PACKAGE but still detect AVX2 for the baseline flag.
targeted_package='oh-my-opencode'
if [[ -n "${OMO_PACKAGE}" ]]; then
  targeted_package="${OMO_PACKAGE}"
fi

arch="$(uname -m)"
force_baseline="$(normalize_bool "${OMO_FORCE_BASELINE}")"
needs_baseline=0

if [[ "${force_baseline}" == "yes" ]]; then
  needs_baseline=1
elif [[ "${force_baseline}" != "no" ]]; then
  case "${arch}" in
    x86_64|amd64)
      if ! has_avx2; then
        needs_baseline=1
      fi
      ;;
  esac
fi

printf '%s\n' "${targeted_package}"
printf '%s\n' "${needs_baseline}"
