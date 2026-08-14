#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"
DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3080}"

curl --fail --silent --show-error --max-time 3 \
    "http://127.0.0.1:${PORT}/healthz" >/dev/null
curl --fail --silent --show-error --max-time 3 \
    "http://127.0.0.1:${DSH_INTERNAL_PORT}/" >/dev/null
