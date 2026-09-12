#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${OUTPUT_DIR:-/data/output}" "${BROWSER_USER_DATA_DIR:-/data/browser-profile}"

if id kasm-user >/dev/null 2>&1; then
  chown -R kasm-user:kasm-user "${OUTPUT_DIR:-/data/output}" "${BROWSER_USER_DATA_DIR:-/data/browser-profile}" || true
fi

# Initialize the upstream user profile before either service can launch a browser.
runuser -u kasm-user -- /dockerstartup/kasm_default_profile.sh /bin/true
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf
exec runuser -u kasm-user -- /dockerstartup/vnc_startup.sh --wait
