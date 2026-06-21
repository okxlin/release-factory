#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t _omo_lines < <(bash "${SCRIPT_DIR}/resolve-omo-package.sh")
omo_package="${_omo_lines[0]}"
_needs_baseline="${_omo_lines[1]:-0}"
unset _omo_lines
if [[ "${_needs_baseline}" == "1" ]]; then
  export OH_MY_OPENCODE_FORCE_BASELINE=1
fi

status=0

check() {
  printf '[doctor] %s\n' "$*"
}

check "runtime identity"
check "user: $(id -un)"
check "uid:gid: $(id -u):$(id -g)"
check "home: ${HOME}"
if [[ "$(id -u)" == "0" ]]; then
  echo "[doctor] runtime should not continue as root" >&2
  status=1
fi

check "node version"
node --version
check "npm version"
npm --version
check "npm global prefix"
npm config get prefix
check "bun version"
bun --version
check "go version"
go version
check "rust version"
rustc --version
cargo --version

check "common coding toolchain"
for cmd in python3 git sqlite3 rg fd gh jq gcc g++ make docker docker-compose pnpm yarn tsc comment-checker sudo; do
  if command -v "$cmd" >/dev/null 2>&1; then
    check "$cmd available"
    "$cmd" --version >/dev/null 2>&1 || true
  else
    echo "[doctor] missing tool: $cmd" >&2
    status=1
  fi
done

check "docker daemon"
if [[ -S /var/run/docker.sock ]]; then
  if ! docker info --format '{{.ServerVersion}}'; then
    echo "[doctor] docker socket is mounted but docker daemon is not reachable" >&2
    status=1
  fi
else
  check "docker socket not mounted"
fi

check "persistent directories"
for dir in \
  "${CONTAINER_WORKSPACE:-/workspace}" \
  "${CONTAINER_CACHE:-/cache}" \
  "$HOME/.config/opencode" \
  "$HOME/.agents" \
  "$HOME/.cache/npm" \
  "$HOME/.cargo/bin" \
  "$HOME/.claude" \
  "$HOME/.opencode" \
  "$HOME/.local/bin" \
  "$HOME/.local/share/opencode" \
  "$HOME/.local/share/oh-my-opencode" \
  "$HOME/.npm"; do
  if [[ -d "$dir" && -w "$dir" ]]; then
    check "$dir writable"
  else
    echo "[doctor] $dir missing or not writable" >&2
    status=1
  fi
done

check "OpenCode availability"
if command -v opencode >/dev/null 2>&1; then
  opencode --version
else
  echo "[doctor] opencode not installed" >&2
  status=1
fi

check "configured runtime mode"
case "${OPENCODE_RUNTIME_MODE:-acp}" in
  acp)
    check "ACP runtime selected on ${ACP_HOST:-0.0.0.0}:${ACP_PORT:-8765}"
    check "ACP validation should use detached/background process checks, not HTTP probes"
    ;;
  serve)
    check "serve runtime selected on ${SERVE_HOST:-0.0.0.0}:${SERVE_PORT:-4096}"
    ;;
  *)
    echo "[doctor] unsupported OPENCODE_RUNTIME_MODE: ${OPENCODE_RUNTIME_MODE}" >&2
    status=1
    ;;
esac

check "oh-my-opencode availability"
if command -v npm >/dev/null 2>&1; then
  check "oh-my-opencode package ${omo_package}"
  if ! npm exec --yes --package="${omo_package}" -- oh-my-opencode --help >/dev/null; then
    status=1
  fi
else
  echo "[doctor] npm unavailable" >&2
  status=1
fi

check "oh-my-opencode doctor"
if command -v npm >/dev/null 2>&1; then
  npm exec --yes --package="${omo_package}" -- oh-my-opencode doctor || check "oh-my-opencode doctor reported runtime issues"
fi

exit "${status}"
