#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${HOME:-}" ]]; then
  export HOME="$(getent passwd "$(id -u)" | cut -d: -f6 2>/dev/null || true)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${OPENCODE_BOOTSTRAP:=1}"
: "${OMO_AUTO_INSTALL:=0}"
: "${ACP_AUTO_START:=0}"
: "${OPENCODE_RUNTIME_MODE:=acp}"
: "${CONTAINER_WORKSPACE:=/workspace}"
: "${CONTAINER_CONFIG:=/config}"
: "${CONTAINER_CACHE:=/cache}"
: "${CONTAINER_DATA:=/data}"
: "${KEEPALIVE_COMMAND:=sleep infinity}"
: "${OPENCODE_INSTALL_DIR:=${CONTAINER_DATA}/opencode}"
: "${OPENCODE_NPM_BIN_DIR:=${CONTAINER_DATA}/bin}"
: "${OPENCODE_CONFIG_DIR:=${CONTAINER_CONFIG}/opencode}"
: "${OMO_INSTALL_DIR:=${CONTAINER_DATA}/oh-my-opencode}"

if [[ -n "${HOME:-}" ]]; then
  export PATH="/opt/bun/bin:${OPENCODE_NPM_BIN_DIR}:${HOME}/.local/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}"
fi

mkdir -p "${CONTAINER_WORKSPACE}" "${CONTAINER_CONFIG}" "${CONTAINER_CACHE}" "${CONTAINER_DATA}" "${OPENCODE_INSTALL_DIR}" "${OPENCODE_NPM_BIN_DIR}" "${OMO_INSTALL_DIR}" "$HOME/.config" "$HOME/.cache" "$HOME/.local/bin"

log() {
  printf '[entrypoint] %s\n' "$*"
}

for dir in "${CONTAINER_WORKSPACE}" "${CONTAINER_CONFIG}" "${CONTAINER_CACHE}" "${CONTAINER_DATA}"; do
  if [[ -d "$dir" && ! -w "$dir" ]]; then
    log "mount not writable for current user: $dir"
  fi
done

if [[ "${OPENCODE_BOOTSTRAP}" == "1" ]]; then
  log "bootstrapping OpenCode userland"
  "${SCRIPT_DIR}/bootstrap-opencode-userland.sh"
  log "installing OpenCode plugins and config hooks"
  "${SCRIPT_DIR}/install-opencode-plugins.sh"
fi

if [[ "${OMO_AUTO_INSTALL}" == "1" ]]; then
  log "installing or refreshing oh-my-opencode"
  "${SCRIPT_DIR}/install-oh-my-opencode.sh"
fi

log "runtime versions"
command -v node >/dev/null && node --version || true
command -v npm >/dev/null && npm --version || true
command -v bun >/dev/null && bun --version || true
command -v opencode >/dev/null && opencode --version || true

if [[ "${ACP_AUTO_START}" == "1" ]]; then
  log "starting OpenCode runtime in background (mode=${OPENCODE_RUNTIME_MODE})"
  "${SCRIPT_DIR}/start-opencode-runtime.sh" &
fi

case "${1:-shell}" in
  shell)
    log "keeping container alive via: ${KEEPALIVE_COMMAND}"
    exec bash -lc "${KEEPALIVE_COMMAND}"
    ;;
  doctor)
    exec "${SCRIPT_DIR}/doctor.sh"
    ;;
  smoke)
    exec "${SCRIPT_DIR}/smoke-test.sh"
    ;;
  runtime)
    exec "${SCRIPT_DIR}/start-opencode-runtime.sh"
    ;;
  *)
    exec "$@"
    ;;
esac
