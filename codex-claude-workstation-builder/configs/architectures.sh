#!/usr/bin/env bash
# architectures.sh — supported build platforms for codex-claude-workstation
# Sourced by scripts/resolve-build-params.sh

SUPPORTED_PLATFORMS=(
  "linux/amd64"
  # "linux/arm64"  # Future: enable after multi-arch support
)

is_supported_platform() {
  local platform="$1"
  for supported in "${SUPPORTED_PLATFORMS[@]}"; do
    if [ "$platform" = "$supported" ]; then
      return 0
    fi
  done
  return 1
}