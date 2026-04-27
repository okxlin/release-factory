#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${HOME:-}" ]]; then
  export HOME="$(getent passwd "$(id -u)" | cut -d: -f6 2>/dev/null || true)"
fi

: "${CONTAINER_DATA:=/data}"
: "${OPENCODE_NPM_BIN_DIR:=${CONTAINER_DATA}/bin}"

if [[ -n "${HOME:-}" ]]; then
  export PATH="/opt/bun/bin:${OPENCODE_NPM_BIN_DIR}:${HOME}/.local/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${OPENCODE_RUNTIME_MODE:=acp}"
: "${ACP_PORT:=8765}"
: "${ACP_HOST:=0.0.0.0}"
: "${SERVE_PORT:=4096}"
: "${SERVE_HOST:=0.0.0.0}"
: "${OPENCODE_BOOTSTRAP:=1}"
: "${OPENCODE_INSTALL_PLUGINS:=1}"

if [[ "${OPENCODE_BOOTSTRAP}" == "1" ]]; then
  "${SCRIPT_DIR}/bootstrap-opencode-userland.sh"
fi

if [[ "${OPENCODE_INSTALL_PLUGINS}" == "1" ]]; then
  "${SCRIPT_DIR}/install-opencode-plugins.sh"
fi

case "${OPENCODE_RUNTIME_MODE}" in
  acp)
    runtime_label="ACP"
    runtime_command=(opencode acp --hostname "${ACP_HOST}" --port "${ACP_PORT}")
    ;;
  serve)
    runtime_label="serve"
    runtime_command=(opencode serve --hostname "${SERVE_HOST}" --port "${SERVE_PORT}")
    ;;
  *)
    echo "[runtime] unsupported OPENCODE_RUNTIME_MODE: ${OPENCODE_RUNTIME_MODE} (expected acp or serve)" >&2
    exit 1
    ;;
esac

if ! command -v opencode >/dev/null 2>&1; then
  echo "[runtime] opencode is required before starting runtime" >&2
  exit 1
fi

echo "[runtime] starting ${runtime_label}: ${runtime_command[*]}"
exec "${runtime_command[@]}"
