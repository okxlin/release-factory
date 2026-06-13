#!/usr/bin/env bash
# healthcheck.sh — 容器健康检查
# 检查 code-server 和 ttyd 是否在监听

set -euo pipefail

CODE_SERVER_PORT=8080
TTYD_PORT=7681

# Check code-server is listening
if ! curl -s -o /dev/null -w "%{http_code}" "http://localhost:${CODE_SERVER_PORT}/" | grep -qE '^[2345][0-9]{2}$'; then
  echo "code-server not responding on port ${CODE_SERVER_PORT}" >&2
  exit 1
fi

# Check ttyd is listening
if ! curl -s -o /dev/null -w "%{http_code}" "http://localhost:${TTYD_PORT}/" | grep -qE '^[2345][0-9]{2}$'; then
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