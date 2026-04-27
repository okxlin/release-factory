#!/usr/bin/env bash
set -euo pipefail

: "${DCP_INSTALL:=1}"
: "${DCP_GLOBAL:=1}"
: "${GPT_UNLOCKED_INSTALL:=1}"
: "${GPT_UNLOCKED_MODE:=plugin}"
: "${GPT_UNLOCKED_PLUGIN_SOURCE:=npm}"
: "${CONTAINER_CONFIG:=/config}"

log() {
  printf '[plugins] %s\n' "$*"
}

sync_config_mount() {
  local target_dir="$1"
  if [[ "$target_dir" == "$HOME/.config/opencode" ]]; then
    return 0
  fi
  mkdir -p "$target_dir"
  if [[ -f "$HOME/.config/opencode/opencode.json" ]]; then
    cp "$HOME/.config/opencode/opencode.json" "$target_dir/opencode.json"
  fi
  if [[ -f "$HOME/.config/opencode/dcp.jsonc" ]]; then
    cp "$HOME/.config/opencode/dcp.jsonc" "$target_dir/dcp.jsonc"
  fi
}

cp_config_mount_back() {
  if [[ -n "${OPENCODE_CONFIG_DIR:-}" && "$OPENCODE_CONFIG_DIR" != "$HOME/.config/opencode" ]]; then
    mkdir -p "$HOME/.config/opencode"
    if [[ -f "$OPENCODE_CONFIG_DIR/opencode.json" ]]; then
      cp "$OPENCODE_CONFIG_DIR/opencode.json" "$HOME/.config/opencode/opencode.json"
    fi
    if [[ -f "$OPENCODE_CONFIG_DIR/dcp.jsonc" ]]; then
      cp "$OPENCODE_CONFIG_DIR/dcp.jsonc" "$HOME/.config/opencode/dcp.jsonc"
    fi
  fi
}

ensure_opencode() {
  if ! command -v opencode >/dev/null 2>&1; then
    log 'opencode is required before installing plugins'
    exit 1
  fi
}

ensure_config_dir() {
  mkdir -p "$HOME/.config/opencode"
  if [[ -w "$CONTAINER_CONFIG" ]] || [[ ! -e "$CONTAINER_CONFIG" ]]; then
    mkdir -p "$CONTAINER_CONFIG/opencode"
    export OPENCODE_CONFIG_DIR="$CONTAINER_CONFIG/opencode"
    sync_config_mount "$OPENCODE_CONFIG_DIR"
  else
    export OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
    log "config mount not writable: $CONTAINER_CONFIG; falling back to $OPENCODE_CONFIG_DIR"
  fi
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
  cp_config_mount_back
  sync_config_mount "$OPENCODE_CONFIG_DIR"
  if [[ -n "${DCP_CONFIG_B64:-}" ]]; then
    log 'writing DCP config from DCP_CONFIG_B64'
    printf '%s' "$DCP_CONFIG_B64" | base64 -d > "$HOME/.config/opencode/dcp.jsonc"
    sync_config_mount "$OPENCODE_CONFIG_DIR"
  fi
}

install_gpt_unlocked() {
  [[ "${GPT_UNLOCKED_INSTALL}" == "1" ]] || return 0
  ensure_config_dir
  if [[ "${GPT_UNLOCKED_MODE}" == "plugin" ]]; then
    if [[ "${GPT_UNLOCKED_PLUGIN_SOURCE}" == "npm" ]]; then
      log 'registering opencode-gpt-unlocked npm plugin in opencode config'
      python3 /app/scripts/update_opencode_config.py plugin opencode-gpt-unlocked@latest
      cp_config_mount_back
      sync_config_mount "$OPENCODE_CONFIG_DIR"
    else
      log 'GPT unlocked plugin source is not npm; skipping config mutation'
    fi
  else
    log 'GPT unlocked patcher mode selected; no plugin registration performed'
  fi
}

ensure_opencode
install_dcp
install_gpt_unlocked
