#!/usr/bin/env bash
# Supported build platforms for the DeepSeek Harness image.

SUPPORTED_PLATFORMS=(
  "linux/amd64"
  "linux/arm64"
)

is_supported_platform() {
  local platform="$1"
  local supported

  for supported in "${SUPPORTED_PLATFORMS[@]}"; do
    if [[ "${platform}" == "${supported}" ]]; then
      return 0
    fi
  done
  return 1
}
