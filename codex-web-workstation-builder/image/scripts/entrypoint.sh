#!/usr/bin/env bash
# entrypoint.sh — codex-web-workstation 容器入口
set -euo pipefail

CODEX_HOME="/home/dev"
CODE_SERVER_PORT=8080
TTYD_PORT=7681

# ── 1. 创建必要目录（不覆盖已有内容） ──
mkdir -p /workspace
mkdir -p "${CODEX_HOME}/.codex"
mkdir -p "${CODEX_HOME}/.config/code-server"
mkdir -p /run/codex

# ── 2. 写入 code-server 配置 ──
CODE_SERVER_PASSWORD="${PASSWORD:-change-me}"
cat > "${CODEX_HOME}/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
EOF

# ── 3. Codex 登录提示 ──
CODEX_AUTH_MODE="${CODEX_AUTH_MODE:-device-auth}"
case "${CODEX_AUTH_MODE}" in
  device-auth)
    echo "============================================================"
    echo " Codex login required. Run the following command:"
    echo "   codex login --device-auth"
    echo ""
    echo " Open the URL shown in the terminal in any browser,"
    echo " enter the verification code to complete authentication."
    echo " Login state persists in the codex-home volume."
    echo "============================================================"
    ;;
  api-key)
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "WARNING: CODEX_AUTH_MODE=api-key but OPENAI_API_KEY is not set." >&2
      echo "         Set OPENAI_API_KEY in .env or environment." >&2
    else
      echo "OPENAI_API_KEY is set. Use: printenv OPENAI_API_KEY | codex login --with-api-key"
    fi
    ;;
  access-token)
    if [ -z "${CODEX_ACCESS_TOKEN:-}" ]; then
      echo "WARNING: CODEX_AUTH_MODE=access-token but CODEX_ACCESS_TOKEN is not set." >&2
    fi
    # Do not print the token value
    echo "CODEX_ACCESS_TOKEN is set. Use: codex login --with-access-token"
    ;;
  none)
    echo "Codex login skipped (CODEX_AUTH_MODE=none). Assuming persisted auth state."
    ;;
  *)
    echo "WARNING: Unknown CODEX_AUTH_MODE='${CODEX_AUTH_MODE}'. Expected: device-auth|api-key|access-token|none" >&2
    ;;
esac

# ── 4. 自定义 Provider 配置 ──
export ENABLE_CUSTOM_PROVIDER
export CUSTOM_PROVIDER_NAME CUSTOM_PROVIDER_BASE_URL CUSTOM_PROVIDER_MODEL CUSTOM_PROVIDER_ENV_KEY
if [ "${ENABLE_CUSTOM_PROVIDER:-false}" = "true" ]; then
  /usr/local/bin/configure-provider.sh
fi

# ── 5. 确保 /home/dev 目录权限 ──
# If running as root initially, fix ownership then switch
if [ "$(id -u)" = "0" ]; then
  chown -R dev:dev "${CODEX_HOME}" /workspace /run/codex 2>/dev/null || true
fi

# ── 6. 启动 code-server ──
code-server /workspace > /tmp/code-server.log 2>&1 &
CODE_SERVER_PID=$!
echo "code-server started (PID ${CODE_SERVER_PID}) on port ${CODE_SERVER_PORT}"

# ── 7. 启动 ttyd ──
TTYD_USER="${TTYD_USER:-dev}"
TTYD_PASSWORD="${TTYD_PASSWORD:-change-me}"
ttyd -p ${TTYD_PORT} -W --base-path /terminal \
  -c "${TTYD_USER}:${TTYD_PASSWORD}" \
  bash -lc 'cd /workspace && exec bash' > /tmp/ttyd.log 2>&1 &
TTYD_PID=$!
echo "ttyd started (PID ${TTYD_PID}) on port ${TTYD_PORT}"

# ── 8. Happy 远程控制提示 ──
ENABLE_HAPPY_REMOTE="${ENABLE_HAPPY_REMOTE:-false}"
HAPPY_SERVER_URL="${HAPPY_SERVER_URL:-}"
if [ "${ENABLE_HAPPY_REMOTE}" = "true" ] && [ -n "${HAPPY_SERVER_URL}" ]; then
  echo "============================================================"
  echo " Happy remote control is enabled."
  echo " HAPPY_SERVER_URL=${HAPPY_SERVER_URL}"
  echo ""
  echo " To start a remote-controllable Codex session, run:"
  echo "   happy codex"
  echo ""
  echo " Note: happy CLI must be installed separately."
  echo "       npm install -g happy"
  echo "============================================================"
fi

# ── 9. Wait for any process to exit ──
echo "All services started. Waiting for processes..."
wait -n
echo "A service process exited. Shutting down..."
kill ${CODE_SERVER_PID} ${TTYD_PID} 2>/dev/null || true
wait