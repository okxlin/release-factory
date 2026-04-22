#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${OUTPUT_DIR:-/data/output}" "${BROWSER_USER_DATA_DIR:-/data/browser-profile}"

if id kasm-user >/dev/null 2>&1; then
  chown -R kasm-user:kasm-user "${OUTPUT_DIR:-/data/output}" "${BROWSER_USER_DATA_DIR:-/data/browser-profile}" || true
fi

if command -v supervisord >/dev/null 2>&1; then
  /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
fi

if [ -x /dockerstartup/vnc_startup.sh ]; then
  exec /dockerstartup/vnc_startup.sh
fi

echo "No known Kasm startup entrypoint found." >&2
exit 1
