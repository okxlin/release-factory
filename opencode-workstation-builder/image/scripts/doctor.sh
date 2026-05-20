#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
omo_package="$(bash "${SCRIPT_DIR}/resolve-omo-package.sh")"

status=0

check() {
  printf '[doctor] %s\n' "$*"
}

run_optional() {
  if "$@"; then
    return 0
  fi
  status=$?
  return 0
}

check "node version"
node --version
check "npm version"
npm --version
check "bun version"
bun --version

check "common coding toolchain"
for cmd in python3 git sqlite3 rg fd gh jq gcc g++ make; do
  if command -v "$cmd" >/dev/null 2>&1; then
    check "$cmd available"
    "$cmd" --version >/dev/null 2>&1 || true
  else
    echo "[doctor] missing tool: $cmd" >&2
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
  if ! npm exec --yes --package="${omo_package}" -- oh-my-opencode doctor; then
    status=1
  fi
fi

exit "${status}"
