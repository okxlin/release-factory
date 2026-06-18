#!/usr/bin/env bash
set -euo pipefail

TARGET_PLATFORMS=(
  "linux/amd64"
  "linux/arm64"
)

is_supported_platform() {
  local platform="${1:-}"
  local supported
  for supported in "${TARGET_PLATFORMS[@]}"; do
    if [[ "$supported" == "$platform" ]]; then
      return 0
    fi
  done
  return 1
}
