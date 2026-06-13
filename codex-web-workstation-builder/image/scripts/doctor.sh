#!/usr/bin/env bash
# doctor.sh — 诊断 codex-web-workstation 运行环境
set -euo pipefail

status=0

check() { printf '[doctor] %s\n' "$*"; }
warn()  { printf '[doctor] WARN: %s\n' "$*" >&2; }

check "=== System Environment ==="
check "hostname: $(hostname 2>/dev/null || echo unknown)"
check "user: $(whoami 2>/dev/null || id -un)"
check "home: ${HOME:-not set}"
check "workspace: ${CONTAINER_WORKSPACE:-/workspace}"

check ""
check "=== Runtime Versions ==="

check "node version"
if command -v node >/dev/null 2>&1; then
  node --version
else
  warn "node not found"
  status=1
fi

check "npm version"
if command -v npm >/dev/null 2>&1; then
  npm --version
else
  warn "npm not found"
  status=1
fi

check "python3 version"
python3 --version 2>/dev/null || warn "python3 not found"

check ""
check "=== Core Services ==="

check "code-server"
if command -v code-server >/dev/null 2>&1; then
  code-server --version 2>/dev/null | head -1 || true
else
  warn "code-server not installed"
  status=1
fi

check "ttyd"
if command -v ttyd >/dev/null 2>&1; then
  ttyd --version 2>/dev/null || true
else
  warn "ttyd not installed"
  status=1
fi

check "codex"
if command -v codex >/dev/null 2>&1; then
  codex --version 2>/dev/null || true
else
  warn "codex not installed"
  status=1
fi

check ""
check "=== Development Toolchain ==="
for cmd in git curl jq rg fd make gcc g++; do
  if command -v "$cmd" >/dev/null 2>&1; then
    check "$cmd: available"
  else
    warn "$cmd: missing"
    status=1
  fi
done

check ""
check "=== Directories ==="
for dir in /workspace /home/dev /home/dev/.codex /home/dev/.config/code-server /run/codex; do
  if [ -d "$dir" ]; then
    if [ -w "$dir" ]; then
      check "$dir: exists and writable"
    else
      warn "$dir: exists but NOT writable"
      status=1
    fi
  else
    warn "$dir: missing"
    status=1
  fi
done

check ""
check "=== Config Files ==="
CONFIG_FILES=(
  "/home/dev/.config/code-server/config.yaml"
  "/home/dev/.codex/config.toml"
)
for f in "${CONFIG_FILES[@]}"; do
  if [ -f "$f" ]; then
    check "$f: present"
  else
    warn "$f: missing (may be generated at runtime)"
  fi
done

check ""
check "=== Service Ports ==="
for port in 8080 7681; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || true; then
    check "port ${port}: listening"
  else
    warn "port ${port}: not listening (services may not be started yet)"
  fi
done

check ""
check "=== Environment Variables ==="
for var in PASSWORD CODEX_AUTH_MODE ENABLE_CUSTOM_PROVIDER ENABLE_HAPPY_REMOTE; do
  val="${!var:-}"
  if [ -n "$val" ]; then
    check "${var}=${val}"
  else
    check "${var}=<not set>"
  fi
done

check ""
if [ "$status" -eq 0 ]; then
  check "=== Doctor: ALL CHECKS PASSED ==="
else
  warn "=== Doctor: ${status} CHECK(S) FAILED ==="
fi

exit "$status"
