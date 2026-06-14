#!/usr/bin/env bash
# doctor.sh — 诊断 codex-claude-workstation v2 运行环境
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

check "codex"
if command -v codex >/dev/null 2>&1; then
    codex --version 2>/dev/null || true
else
    warn "codex not installed"
    status=1
fi

check "claude"
if command -v claude >/dev/null 2>&1; then
    claude --version 2>/dev/null || true
else
    warn "claude not installed"
fi

check "supervisord"
if command -v supervisord >/dev/null 2>&1; then
    check "supervisord: available"
else
    warn "supervisord not installed"
    status=1
fi

check ""
check "=== Development Toolchain ==="
for cmd in git curl jq rg fd make gcc g++ docker go rustc bun cargo yq gh supervisorctl; do
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
    "/etc/supervisor/supervisord.conf"
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
if ss -tlnp 2>/dev/null | grep -q ":8080 " || true; then
    check "port 8080: listening"
else
    warn "port 8080: not listening"
fi

check ""
check "=== Environment Variables ==="
for var in PASSWORD ENABLE_CUSTOM_PROVIDER ENABLE_DOCKER_SOCK; do
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
