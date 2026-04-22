#!/usr/bin/env bash
set -euo pipefail

PORT="${DAEMON_PORT:-40225}"

if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null
  exit 0
fi

exit 1
