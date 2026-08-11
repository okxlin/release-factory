#!/usr/bin/env bash
# smoke-test.sh — 冒烟测试 v2：快速验证核心服务可用性
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=paseo-password.sh
source /usr/local/lib/codex-workstation/paseo-password.sh

status=0

pass() { printf '[smoke] PASS: %s\n' "$*"; }
fail() { printf '[smoke] FAIL: %s\n' "$*" >&2; status=1; }
version_check() {
    local label="$1"
    shift
    if command -v "$1" >/dev/null 2>&1 && "$@"; then
        pass "${label}"
    else
        fail "${label}"
    fi
}
http_code() {
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 2 --max-time 5 "$@" 2>/dev/null || true
}

echo "[smoke] codex-claude-workstation smoke test"
echo "[smoke] $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
echo "[smoke] === Required Commands ==="
REQUIRED_CMDS=(node npm pnpm yarn corepack code-server codex claude omx paseo git curl jq rg fd python3 pytest uv uvx pipx ruff black mypy pre-commit yamllint direnv make gcc g++ docker go rustc bun deno cargo java mvn yq actionlint gh supervisorctl bwrap unshare mihomo clash-meta sing-box xray dig nc lsof file)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "$cmd available"
    else
        fail "$cmd missing"
    fi
done

echo ""
echo "[smoke] === Command Versions ==="
version_check "node" node --version
version_check "npm" npm --version
if [ "$(npm config get prefix)" = "/home/dev/.local" ]; then
    pass "npm global prefix persistent"
else
    fail "npm global prefix should be /home/dev/.local"
fi
version_check "pnpm" pnpm --version
version_check "yarn" yarn --version
version_check "corepack" corepack --version
version_check "uv" uv --version
version_check "pytest" pytest --version
version_check "ruff" ruff --version
version_check "black" black --version
version_check "mypy" mypy --version
version_check "codex" codex --version
version_check "claude" claude --version
version_check "oh-my-codex" omx --version
version_check "paseo" paseo --version
if [ "$(paseo --version 2>/dev/null || true)" = "${PASEO_VERSION:-0.3.1}" ]; then
    pass "paseo version pinned to ${PASEO_VERSION:-0.3.1}"
else
    fail "paseo version mismatch"
fi
version_check "go" go version
if [ "$(go env GOPATH 2>/dev/null || true)" = "/home/dev/go" ]; then
    pass "go GOPATH persistent"
else
    fail "go GOPATH should be /home/dev/go"
fi
version_check "rustc" rustc --version
version_check "bun" bun --version
version_check "deno" deno --version
version_check "java" java -version
version_check "maven" mvn --version
version_check "docker" docker --version
version_check "actionlint" actionlint --version
if [ -S /var/run/docker.sock ]; then
    version_check "docker daemon" docker info --format '{{.ServerVersion}}'
else
    pass "docker daemon skipped (socket not mounted)"
fi
version_check "bwrap" bwrap --version
version_check "mihomo" mihomo -v
version_check "sing-box" sing-box version
version_check "xray" xray version

echo ""
echo "[smoke] === Core Services (HTTP probes) ==="
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
PASEO_PORT="${PASEO_PORT:-6767}"

if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${CODE_SERVER_PORT}/" | grep -qE '^[234][0-9]{2}$'; then
    pass "code-server responding on port ${CODE_SERVER_PORT}"
else
    fail "code-server not responding on port ${CODE_SERVER_PORT}"
fi

if [ "$(http_code -H 'Host: paseo.internal' "http://127.0.0.1:${PASEO_PORT}/api/health")" = "200" ]; then
    pass "Paseo health responding on port ${PASEO_PORT}"
else
    fail "Paseo health not responding on port ${PASEO_PORT}"
fi

paseo_password="${PASEO_PASSWORD:-${PASSWORD:-change-me}}"
if [[ -z "${paseo_password//[[:space:]]/}" ]]; then
    paseo_password="change-me"
fi
if paseo_password_is_websocket_token "${paseo_password}"; then
    pass "Paseo password is browser WebSocket-token-safe"
else
    fail "Paseo password is not browser WebSocket-token-safe"
    paseo_password="invalid-password-placeholder"
fi
if [ "$(http_code -H 'Host: paseo.internal' -H "Authorization: Bearer ${paseo_password}" "http://127.0.0.1:${PASEO_PORT}/api/status")" = "200" ]; then
    pass "Paseo authenticated status responding"
else
    fail "Paseo authenticated status failed"
fi

websocket_code="$(curl --http1.1 --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 2 --max-time 1 \
    -H 'Host: paseo.internal' \
    -H 'Origin: http://paseo.internal' \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: SGVsbG9QYXNlbzEyMzQ1Ng==' \
    -H "Sec-WebSocket-Protocol: paseo.bearer.${paseo_password}" \
    "http://127.0.0.1:${PASEO_PORT}/ws" 2>/dev/null || true)"
if [ "${websocket_code}" = "101" ]; then
    pass "Paseo authenticated WebSocket accepts the configured origin"
else
    fail "Paseo authenticated WebSocket failed"
fi

if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "^(0\\.0\\.0\\.0|\\*):${PASEO_PORT}$"; then
    pass "Paseo daemon listening on container port ${PASEO_PORT}"
else
    fail "Paseo daemon is not listening on container port ${PASEO_PORT}"
fi

if supervisorctl status paseo 2>/dev/null | grep -q 'RUNNING'; then
    pass "supervisor service paseo running"
else
    fail "supervisor service paseo not running"
fi

echo ""
echo "[smoke] === Code-server Extensions ==="
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
extension_list="$(code-server --list-extensions 2>/dev/null || true)"
for extension in "${REQUIRED_EXTENSIONS[@]}"; do
    if grep -Fxq "$extension" <<< "$extension_list"; then
        pass "${extension} installed"
    else
        fail "${extension} missing"
    fi
done

echo ""
echo "[smoke] === Workspace Directory ==="
WORKSPACE="${CONTAINER_WORKSPACE:-/workspace}"
if [ -d "$WORKSPACE" ] && [ -w "$WORKSPACE" ]; then
    pass "${WORKSPACE} exists and writable"
else
    fail "${WORKSPACE} missing or not writable"
fi

echo ""
echo "[smoke] === Persistence Check ==="
for dir in \
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
    /home/dev/.paseo \
    /home/dev/go/bin \
    /home/dev/proxy; do
    if [ -d "$dir" ]; then
        pass "${dir} present"
    else
        fail "${dir} missing"
    fi
done

if [ -f /usr/share/doc/paseo/LICENSE ] && [ -f /usr/share/doc/paseo/UPSTREAM.md ]; then
    pass "Paseo license and exact upstream source notice present"
else
    fail "Paseo license or upstream source notice missing"
fi

echo ""
echo "[smoke] === Scripts Installed ==="
for script in entrypoint.sh healthcheck.sh doctor.sh smoke-test.sh; do
    if [ -x "/usr/local/bin/${script}" ]; then
        pass "${script} installed and executable"
    else
        fail "${script} missing or not executable"
    fi
done

echo ""
if [ "$status" -eq 0 ]; then
    echo "[smoke] ALL TESTS PASSED"
else
    echo "[smoke] ${status} TEST(S) FAILED" >&2
fi

exit "$status"
