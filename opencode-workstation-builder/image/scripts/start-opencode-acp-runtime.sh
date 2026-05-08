#!/usr/bin/env bash
set -euo pipefail

: "${ACP_PORT:=8765}"
: "${ACP_HOST:=0.0.0.0}"
: "${ACP_COMMAND:=opencode acp --hostname ${ACP_HOST} --port ${ACP_PORT}}"

if ! command -v opencode >/dev/null 2>&1; then
  echo "[acp-runtime] opencode is required before starting ACP runtime" >&2
  exit 1
fi

echo "[acp-runtime] starting: ${ACP_COMMAND}"
exec bash -lc "${ACP_COMMAND}"
