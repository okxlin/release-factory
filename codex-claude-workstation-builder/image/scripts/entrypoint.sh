#!/usr/bin/env bash
# entrypoint.sh — codex-claude-workstation v2 容器入口
set -euo pipefail

CODEX_HOME="/home/dev"
CODE_SERVER_PORT=8080

# ── 1. 创建必要目录 ──
mkdir -p /workspace
mkdir -p "${CODEX_HOME}/.codex"
mkdir -p "${CODEX_HOME}/.config/code-server"
mkdir -p /run/codex
mkdir -p "${CODEX_HOME}/proxy"

# ── 2. 写入 code-server 配置（中文界面） ──
CODE_SERVER_PASSWORD="${PASSWORD:-change-me}"
cat > "${CODEX_HOME}/.config/code-server/config.yaml" <<EOF
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


# ── 4. 权限修复 ──
if [ "$(id -u)" = "0" ]; then
    chown -R dev:dev "${CODEX_HOME}" /workspace /run/codex 2>/dev/null || true
fi

# ── 5. 启动 code-server ──
code-server /workspace > /tmp/code-server.log 2>&1 &
CODE_SERVER_PID=$!
echo "code-server started (PID ${CODE_SERVER_PID}) on port ${CODE_SERVER_PORT}"

# ── 6. 初始化提示 ──
echo "============================================================"
echo " codex-claude-workstation is ready."
echo ""
echo " Access code-server: http://<host>:${CODE_SERVER_PORT}"
echo " Password: ${CODE_SERVER_PASSWORD}"
echo ""
echo " In the code-server terminal, run 'codex login' to authenticate."
echo "============================================================"

# ── 7. 等待任意进程退出 ──
echo "All services started. Waiting..."
wait -n
echo "A service process exited. Shutting down..."
kill ${CODE_SERVER_PID} ${SUPERVISOR_PID:-} 2>/dev/null || true
wait
