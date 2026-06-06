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

# When the user explicitly picks a package, trust it and don't force baseline.
if [[ -n "${OMO_PACKAGE}" ]]; then
  printf '%s\n' "${OMO_PACKAGE}"
  printf '%s\n' '0'
  exit 0
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

printf '%s\n' 'oh-my-opencode'
printf '%s\n' "${needs_baseline}"
