#!/bin/bash
set -euo pipefail

CONTAINER_DATA="${CONTAINER_DATA:-/data}"
OPENCODE_INSTALL_DIR="${OPENCODE_INSTALL_DIR:-${CONTAINER_DATA}/opencode}"
OPENCODE_NPM_BIN_DIR="${OPENCODE_NPM_BIN_DIR:-${CONTAINER_DATA}/bin}"
STATE_DIR="${CONTAINER_DATA}/state/oh-my-opencode-bootstrap"
BIN_DIR="${OPENCODE_NPM_BIN_DIR}"
NPM_PREFIX="${OPENCODE_INSTALL_DIR}"
mkdir -p "$STATE_DIR" "$BIN_DIR" "$NPM_PREFIX"

export PATH="$BIN_DIR:$PATH"

log() { printf '[update-opencode-userland] %s\n' "$*"; }

if ! command -v npm >/dev/null 2>&1; then
  echo 'npm is required but not found in current image.' >&2
  exit 1
fi

log "updating opencode-ai in persistent npm prefix"
npm install -g --prefix "$NPM_PREFIX" opencode-ai@latest

if command -v opencode >/dev/null 2>&1; then
  opencode --version > "$STATE_DIR/opencode.version" 2>/dev/null || true
  log "current opencode version: $(cat "$STATE_DIR/opencode.version" 2>/dev/null || true)"
fi

cat <<'MSG'
[update-opencode-userland] Update finished.
If you also want the latest oh-my-opencode plugin behavior, re-run:
  bunx oh-my-opencode install --no-tui ...
and then verify with:
  bunx oh-my-opencode doctor
MSG
