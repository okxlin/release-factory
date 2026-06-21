#!/usr/bin/env bash
# doctor.sh — 诊断 codex-claude-workstation v2 运行环境
set -euo pipefail

status=0

check() { printf '[doctor] %s\n' "$*"; }
warn()  { printf '[doctor] WARN: %s\n' "$*" >&2; }
is_true() {
    case "${1:-}" in
        true|TRUE|True|1|yes|YES|Yes|on|ON|On) return 0 ;;
        *) return 1 ;;
    esac
}
mask_value() {
    local name="$1"
    local value="$2"
    if [[ "$name" == *PASSWORD* || "$name" == *TOKEN* || "$name" == *SECRET* || "$name" == *KEY* ]]; then
        printf '<set>'
    else
        printf '%s' "$value"
    fi
}

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
    npm_prefix="$(npm config get prefix)"
    check "npm global prefix: ${npm_prefix}"
    if [ "${npm_prefix}" != "/home/dev/.local" ]; then
        warn "npm global prefix should be /home/dev/.local for persistence"
        status=1
    fi
else
    warn "npm not found"
    status=1
fi

check "pnpm version"
if command -v pnpm >/dev/null 2>&1; then
    if ! pnpm --version; then
        warn "pnpm is installed but failed to run"
        status=1
    fi
else
    warn "pnpm not found"
    status=1
fi

check "python3 version"
python3 --version 2>/dev/null || warn "python3 not found"

check "uv version"
if command -v uv >/dev/null 2>&1; then
    uv --version
else
    warn "uv not found"
    status=1
fi

check "pytest version"
if command -v pytest >/dev/null 2>&1; then
    pytest --version
else
    warn "pytest not found"
    status=1
fi

check "python quality tools"
for cmd in ruff black mypy; do
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" --version
    else
        warn "$cmd not found"
        status=1
    fi
done

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

check "docker daemon"
if [ -S /var/run/docker.sock ]; then
    if docker info --format '{{.ServerVersion}}'; then
        check "docker daemon: reachable"
    else
        warn "docker daemon socket is mounted but not reachable by $(whoami)"
        status=1
    fi
else
    check "docker daemon: socket not mounted"
fi

check ""
check "=== Code-server Extensions ==="
REQUIRED_EXTENSIONS=(
    "anthropic.claude-code"
    "openai.chatgpt"
    "ms-python.python"
    "charliermarsh.ruff"
    "redhat.vscode-yaml"
    "tamasfe.even-better-toml"
    "editorconfig.editorconfig"
    "esbenp.prettier-vscode"
    "dbaeumer.vscode-eslint"
    "ms-azuretools.vscode-docker"
    "ms-ceintl.vscode-language-pack-zh-hans"
)
if command -v code-server >/dev/null 2>&1; then
    extension_list="$(code-server --list-extensions 2>/dev/null || true)"
    for extension in "${REQUIRED_EXTENSIONS[@]}"; do
        if grep -Fxq "$extension" <<< "$extension_list"; then
            check "$extension: installed"
        else
            warn "$extension: missing"
            status=1
        fi
    done
fi

check ""
check "=== Development Toolchain ==="
for cmd in git curl jq rg fd make gcc g++ docker go rustc bun deno cargo java mvn yq actionlint gh supervisorctl bwrap unshare corepack uv uvx pipx pytest ruff black mypy pre-commit yamllint direnv dig nc lsof file; do
    if command -v "$cmd" >/dev/null 2>&1; then
        check "$cmd: available"
    else
        warn "$cmd: missing"
        status=1
    fi
done

if command -v go >/dev/null 2>&1; then
    go_path="$(go env GOPATH 2>/dev/null || true)"
    check "go GOPATH: ${go_path}"
    if [ "${go_path}" != "/home/dev/go" ]; then
        warn "go GOPATH should be /home/dev/go for persistent go install binaries"
        status=1
    fi
fi

check ""
check "=== Proxy Tooling ==="
for cmd in mihomo clash-meta sing-box xray; do
    if command -v "$cmd" >/dev/null 2>&1; then
        check "$cmd: available"
    else
        warn "$cmd: missing"
        status=1
    fi
done

check ""
check "=== Codex Sandbox Prerequisites ==="
if command -v bwrap >/dev/null 2>&1; then
    bwrap --version 2>/dev/null || check "bwrap: available"
else
    warn "bwrap missing; Codex sandbox cannot start"
    status=1
fi

if [ -r /proc/sys/kernel/unprivileged_userns_clone ]; then
    userns_clone="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
    check "kernel.unprivileged_userns_clone=${userns_clone}"
    if [ "${userns_clone}" != "1" ]; then
        warn "kernel.unprivileged_userns_clone should be 1"
        status=1
    fi
else
    warn "cannot read kernel.unprivileged_userns_clone"
fi

if [ -r /proc/sys/user/max_user_namespaces ]; then
    max_userns="$(cat /proc/sys/user/max_user_namespaces)"
    check "user.max_user_namespaces=${max_userns}"
    if [ "${max_userns}" = "0" ]; then
        warn "user.max_user_namespaces should be greater than 0"
        status=1
    fi
else
    warn "cannot read user.max_user_namespaces"
fi

if command -v unshare >/dev/null 2>&1; then
    if userns_error="$(unshare -Ur true 2>&1)"; then
        check "unprivileged user namespace: available"
    else
        warn "unprivileged user namespace failed: ${userns_error}"
        warn "set CODEX_SANDBOX_STRICT=true to fail doctor on this host runtime limitation"
        if is_true "${CODEX_SANDBOX_STRICT:-false}"; then
            status=1
        fi
    fi
fi

check ""
check "=== Directories ==="
for dir in \
    /workspace \
    /home/dev \
    /home/dev/.bun \
    /home/dev/.cache/npm \
    /home/dev/.cargo/bin \
    /home/dev/.claude \
    /home/dev/.codex \
    /home/dev/.config/code-server \
    /home/dev/.deno \
    /home/dev/.local/bin \
    /home/dev/.local/share/code-server/extensions \
    /home/dev/.npm \
    /home/dev/go/bin \
    /home/dev/proxy \
    /run/codex; do
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
for var in PASSWORD ROOT_PASSWORD DOCKER_SOCK_SRC CONTAINER_WORKSPACE FIX_WORKSPACE_OWNERSHIP_RECURSIVE CODEX_SANDBOX_STRICT BUN_INSTALL CARGO_HOME DENO_INSTALL COREPACK_HOME GOPATH JAVA_HOME NPM_CONFIG_CACHE NPM_CONFIG_PREFIX PIPX_BIN_DIR RUSTUP_HOME; do
    val="${!var:-}"
    if [ -n "$val" ]; then
        check "${var}=$(mask_value "$var" "$val")"
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
