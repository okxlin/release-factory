#!/usr/bin/env bash
set -euo pipefail

: "${DCP_INSTALL:=1}"
: "${DCP_GLOBAL:=1}"
: "${OPENCODE_CONFIG_DIR:=$HOME/.config/opencode}"

log() {
  printf '[plugins] %s\n' "$*"
}

ensure_opencode() {
  if ! command -v opencode >/dev/null 2>&1; then
    log 'opencode is required before installing plugins'
    exit 1
  fi
}

ensure_config_dir() {
  mkdir -p "$OPENCODE_CONFIG_DIR"
}

install_dcp() {
  [[ "${DCP_INSTALL}" == "1" ]] || return 0
  ensure_config_dir
  log 'installing Dynamic Context Pruning plugin'
  if [[ "${DCP_GLOBAL}" == "1" ]]; then
    opencode plugin @tarquinen/opencode-dcp@latest --global || true
  else
    opencode plugin @tarquinen/opencode-dcp@latest || true
  fi
  python3 /app/scripts/update_opencode_config.py plugin @tarquinen/opencode-dcp@latest
  if [[ -n "${DCP_CONFIG_B64:-}" ]]; then
    log 'writing DCP config from DCP_CONFIG_B64'
    printf '%s' "$DCP_CONFIG_B64" | base64 -d > "$OPENCODE_CONFIG_DIR/dcp.jsonc"
  fi
}

ensure_opencode
install_dcp
