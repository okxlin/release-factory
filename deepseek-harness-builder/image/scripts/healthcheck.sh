#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"
DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3080}"

http_response() {
    local url="$1"
    local status

    status="$(curl --silent --show-error --max-time 3 \
        --output /dev/null --write-out '%{http_code}' "${url}")" \
        || return 1
    [[ "${status}" =~ ^[1-4][0-9]{2}$ ]]
}

http_response "http://127.0.0.1:${PORT}/healthz"
http_response "http://127.0.0.1:${DSH_INTERNAL_PORT}/"
