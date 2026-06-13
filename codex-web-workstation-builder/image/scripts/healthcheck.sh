#!/usr/bin/env bash
# healthcheck.sh — 容器健康检查
# 检查 code-server 和 ttyd 是否在监听

set -euo pipefail

CODE_SERVER_PORT=8080
TTYD_PORT=7681

# Check code-server is listening
if ! curl -sf http://localhost:${CODE_SERVER_PORT}/ > /dev/null 2>&1; then
  echo "code-server not responding on port ${CODE_SERVER_PORT}" >&2
  exit 1
fi

# Check ttyd is listening
if ! curl -sf http://localhost:${TTYD_PORT}/ > /dev/null 2>&1; then
  echo "ttyd not responding on port ${TTYD_PORT}" >&2
  exit 1
fi

# Check workspace directory is accessible
if [ ! -d /workspace ]; then
  echo "/workspace directory not found" >&2
  exit 1
fi

echo "healthy"
exit 0