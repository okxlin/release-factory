#!/usr/bin/env bash
# healthcheck.sh — 容器健康检查 v2
# 检查 code-server 与 Paseo 安全代理是否可用

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=paseo-password.sh
source /usr/local/lib/codex-workstation/paseo-password.sh

CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
PASEO_PROXY_PORT="${PASEO_PROXY_PORT:-6767}"

http_code() {
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 2 --max-time 5 "$@" 2>/dev/null || true
}

# Accept a normal success, redirect, or authentication/client response.
if ! http_code "http://127.0.0.1:${CODE_SERVER_PORT}/" | grep -qE '^[234][0-9]{2}$'; then
    echo "code-server not responding on port ${CODE_SERVER_PORT}" >&2
    exit 1
fi

if [ "$(http_code "http://127.0.0.1:${PASEO_PROXY_PORT}/api/health")" != "200" ]; then
    echo "Paseo health endpoint not responding through port ${PASEO_PROXY_PORT}" >&2
    exit 1
fi

# A forged localhost service Host must be rewritten by the inner Nginx proxy.
# Without that rewrite Paseo classifies it before daemon authentication and
# returns a Service Proxy response (404 or the registered service itself).
if [ "$(http_code -H 'Host: fake--route.localhost' "http://127.0.0.1:${PASEO_PROXY_PORT}/api/status")" != "401" ]; then
    echo "Paseo Host rewrite/authentication boundary is not enforced" >&2
    exit 1
fi

paseo_password="${PASEO_PASSWORD:-${PASSWORD:-change-me}}"
if [[ -z "${paseo_password//[[:space:]]/}" ]]; then
    paseo_password="change-me"
fi
if ! paseo_password_is_websocket_token "${paseo_password}"; then
    echo "Paseo password is not browser WebSocket-token-safe; set a separate PASEO_PASSWORD" >&2
    exit 1
fi
if [ "$(http_code -H "Authorization: Bearer ${paseo_password}" "http://127.0.0.1:${PASEO_PROXY_PORT}/api/status")" != "200" ]; then
    echo "Paseo authenticated status endpoint is not responding" >&2
    exit 1
fi

# Check workspace directory is accessible and writable by dev
if [ ! -d /workspace ] || [ ! -w /workspace ]; then
    echo "/workspace directory not found or not writable" >&2
    exit 1
fi

echo "healthy"
exit 0
