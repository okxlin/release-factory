#!/usr/bin/env bash
# entrypoint.sh — codex-claude-workstation v2 容器入口
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=paseo-password.sh
source /usr/local/lib/codex-workstation/paseo-password.sh

WORKSTATION_HOME="/home/dev"
CODEX_USER="dev"
CODEX_GROUP="dev"
WORKSPACE="${CONTAINER_WORKSPACE:-/workspace}"
CODE_SERVER_PORT=8080
PASEO_PROXY_PORT=6767
PASEO_DAEMON_PORT=6768

ensure_owned_dir() {
    local dir="$1"
    if ! sudo install -d -o "${CODEX_USER}" -g "${CODEX_GROUP}" "${dir}"; then
        echo "WARN: failed to prepare ${dir}" >&2
    fi
}

configure_docker_socket_access() {
    local socket="/var/run/docker.sock"
    local socket_gid group_name

    if [ ! -S "${socket}" ]; then
        return
    fi

    socket_gid="$(stat -c '%g' "${socket}" 2>/dev/null || true)"
    if [ -z "${socket_gid}" ]; then
        echo "WARN: failed to inspect ${socket}" >&2
        return
    fi

    if [ "${socket_gid}" = "0" ]; then
        echo "WARN: ${socket} is owned by root group; use sudo docker inside the container." >&2
        return
    fi

    if id -G | tr ' ' '\n' | grep -qx "${socket_gid}"; then
        return
    fi

    group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
    if [ -z "${group_name}" ]; then
        group_name="docker-host"
        if getent group "${group_name}" >/dev/null 2>&1; then
            group_name="docker-host-${socket_gid}"
        fi
        if ! sudo groupadd -g "${socket_gid}" "${group_name}" 2>/dev/null; then
            group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
        fi
    fi

    if [ -z "${group_name}" ]; then
        echo "WARN: failed to create group for ${socket}; use sudo docker inside the container." >&2
        return
    fi

    if ! sudo usermod -aG "${group_name}" "${CODEX_USER}"; then
        echo "WARN: failed to add ${CODEX_USER} to ${group_name}; use sudo docker inside the container." >&2
        return
    fi

    if [ "${CODEX_DOCKER_GROUP_REFRESHED:-false}" != "true" ]; then
        export CODEX_DOCKER_GROUP_REFRESHED=true
        echo "Docker socket group ${socket_gid} detected; refreshing ${CODEX_USER} session groups."
        exec sudo -E -u "${CODEX_USER}" -g "${CODEX_GROUP}" /usr/local/bin/entrypoint.sh
    fi

    echo "WARN: ${CODEX_USER} was added to ${group_name}, but current session groups were not refreshed." >&2
}

seed_code_server_extensions() {
    local seed_dir="/opt/code-server/extensions"
    local target_dir="${WORKSTATION_HOME}/.local/share/code-server/extensions"

    if [ ! -d "${seed_dir}" ]; then
        return
    fi

    ensure_owned_dir "${target_dir}"
    if ! cp -a --update=none "${seed_dir}/." "${target_dir}/"; then
        echo "WARN: failed to seed code-server extensions into ${target_dir}" >&2
    fi
}

# ── 1. 创建必要目录并修复挂载卷 ownership ──
ensure_owned_dir "${WORKSPACE}"
ensure_owned_dir "${WORKSTATION_HOME}"
ensure_owned_dir "${WORKSTATION_HOME}/.bun"
ensure_owned_dir "${WORKSTATION_HOME}/.bun/bin"
ensure_owned_dir "${WORKSTATION_HOME}/.cache"
ensure_owned_dir "${WORKSTATION_HOME}/.cache/npm"
ensure_owned_dir "${WORKSTATION_HOME}/.cargo"
ensure_owned_dir "${WORKSTATION_HOME}/.cargo/bin"
ensure_owned_dir "${WORKSTATION_HOME}/.claude"
ensure_owned_dir "${WORKSTATION_HOME}/.codex"
ensure_owned_dir "${WORKSTATION_HOME}/.config"
ensure_owned_dir "${WORKSTATION_HOME}/.config/code-server"
ensure_owned_dir "${WORKSTATION_HOME}/.deno"
ensure_owned_dir "${WORKSTATION_HOME}/.deno/bin"
ensure_owned_dir "${WORKSTATION_HOME}/.local"
ensure_owned_dir "${WORKSTATION_HOME}/.local/bin"
ensure_owned_dir "${WORKSTATION_HOME}/.local/share"
ensure_owned_dir "${WORKSTATION_HOME}/.local/share/code-server"
ensure_owned_dir "${WORKSTATION_HOME}/.local/share/code-server/extensions"
ensure_owned_dir "${WORKSTATION_HOME}/.npm"
ensure_owned_dir "${WORKSTATION_HOME}/.paseo"
ensure_owned_dir "${WORKSTATION_HOME}/go"
ensure_owned_dir "${WORKSTATION_HOME}/go/bin"
ensure_owned_dir /run/codex
ensure_owned_dir "${WORKSTATION_HOME}/proxy"
ensure_owned_dir /tmp/codex-nginx
ensure_owned_dir /tmp/codex-nginx/client-body
ensure_owned_dir /tmp/codex-nginx/proxy

seed_code_server_extensions
configure_docker_socket_access

if [ "${FIX_WORKSPACE_OWNERSHIP_RECURSIVE:-false}" = "true" ]; then
    if [ "${WORKSPACE}" = "/workspace" ]; then
        sudo chown -R "${CODEX_USER}:${CODEX_GROUP}" "${WORKSPACE}" || true
    else
        echo "WARN: recursive workspace ownership repair is only allowed for /workspace; skipped ${WORKSPACE}" >&2
    fi
fi

if [ ! -w "${WORKSPACE}" ]; then
    echo "ERROR: ${WORKSPACE} is not writable by ${CODEX_USER}." >&2
    echo "Check the host bind mount ownership or run with a writable APP_DATA_DIR." >&2
    exit 1
fi

# ── 1.5. 应用 ROOT_PASSWORD（运行时覆盖） ──
echo "root:${ROOT_PASSWORD:-codex2024}" | sudo chpasswd

# ── 1.6. Paseo 安全运行时 ──
# Existing installations may not have PASEO_PASSWORD yet. In that case keep
# upgrades usable by inheriting the already-known code-server password.
PASEO_PASSWORD="${PASEO_PASSWORD:-${PASSWORD:-change-me}}"
if [[ -z "${PASEO_PASSWORD//[[:space:]]/}" ]]; then
    echo "WARN: empty PASEO_PASSWORD; falling back to PASSWORD/default." >&2
    PASEO_PASSWORD="${PASSWORD:-change-me}"
fi
if [[ -z "${PASEO_PASSWORD//[[:space:]]/}" ]]; then
    PASEO_PASSWORD=change-me
fi
export PASEO_PASSWORD
export PASEO_HOME="${WORKSTATION_HOME}/.paseo"
export PASEO_LISTEN="127.0.0.1:${PASEO_DAEMON_PORT}"
export PASEO_HOSTNAMES=paseo.internal
export PASEO_TRUSTED_PROXIES=loopback
export PASEO_RELAY_ENABLED=false
# This disables Paseo's optional standalone proxy layer, but upstream keeps
# localhost Service Proxy routing. The fixed-Host Nginx listener on 6767 is
# the actual containment boundary and the daemon port must remain private.
export PASEO_SERVICE_PROXY_ENABLED=false
export PASEO_WEB_UI_ENABLED=true
export PASEO_VOICE_MODE_ENABLED=false
export PASEO_DICTATION_ENABLED=false
export PASEO_LOCAL_SPEECH_AUTO_DOWNLOAD=false

if ! paseo_password_is_websocket_token "${PASEO_PASSWORD}"; then
    echo "WARN: the effective Paseo password cannot be represented as a browser WebSocket subprotocol token." >&2
    echo "WARN: code-server remains available, but mobile Paseo sessions require a separate token-safe PASEO_PASSWORD." >&2
elif ! paseo_password_has_recommended_length "${PASEO_PASSWORD}"; then
    echo "WARN: use a unique Paseo password of at least 20 characters before public access." >&2
fi

if [ "${PASEO_PASSWORD}" = "change-me" ]; then
    echo "WARN: Paseo is using the example password; set PASEO_PASSWORD before public access." >&2
fi

# ── 2. 写入 code-server 配置（中文界面） ──
CODE_SERVER_PASSWORD="${PASSWORD:-change-me}"
cat > "${WORKSTATION_HOME}/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
locale: zh-cn
EOF

# ── 3. 启动 supervisord（管理代理等后台服务） ──
if [ -f /etc/supervisor/supervisord.conf ]; then
    supervisord -c /etc/supervisor/supervisord.conf -n &
    SUPERVISOR_PID=$!
    echo "supervisord started (PID ${SUPERVISOR_PID})"
fi


# ── 4. 启动 code-server ──
code-server --bind-addr 0.0.0.0:${CODE_SERVER_PORT} &
CODE_SERVER_PID=$!
# ── 5. 初始化提示 ──
echo "============================================================"
echo " codex-claude-workstation is ready."
echo ""
echo " Access code-server: http://<host>:${CODE_SERVER_PORT}"
echo " Password: configured from PASSWORD environment variable"
echo " Access Paseo:      http://<host>:${PASEO_PROXY_PORT} (place behind HTTPS)"
echo " Paseo password:    configured from PASEO_PASSWORD (falls back to PASSWORD)"
echo ""
echo " In the code-server terminal, run 'codex login' to authenticate."
echo "============================================================"

# ── 6. 等待任意进程退出 ──
echo "All services started. Waiting..."
wait -n
echo "A service process exited. Shutting down..."
PIDS=("${CODE_SERVER_PID}")
if [ -n "${SUPERVISOR_PID:-}" ]; then
    PIDS+=("${SUPERVISOR_PID}")
fi
kill "${PIDS[@]}" 2>/dev/null || true
wait
