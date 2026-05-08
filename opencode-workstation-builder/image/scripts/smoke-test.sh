#!/usr/bin/env bash
set -euo pipefail

status=0

printf '[smoke] checking required commands\n'
for cmd in node npm bun bunx python3 git sqlite3 rg fd gh jq gcc g++ make; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '[smoke] missing command: %s\n' "$cmd" >&2
    status=1
  fi
done

printf '[smoke] checking OpenCode\n'
if command -v opencode >/dev/null 2>&1; then
  opencode --version
else
  printf '[smoke] opencode not installed yet; run bootstrap script\n' >&2
  status=1
fi

printf '[smoke] checking runtime mode\n'
case "${OPENCODE_RUNTIME_MODE:-acp}" in
  acp)
    printf '[smoke] runtime=acp target=%s:%s\n' "${ACP_HOST:-0.0.0.0}" "${ACP_PORT:-8765}"
    ;;
  serve)
    printf '[smoke] runtime=serve target=%s:%s\n' "${SERVE_HOST:-0.0.0.0}" "${SERVE_PORT:-4096}"
    ;;
  *)
    printf '[smoke] unsupported OPENCODE_RUNTIME_MODE: %s\n' "${OPENCODE_RUNTIME_MODE}" >&2
    status=1
    ;;
esac

printf '[smoke] checking oh-my-opencode resolver\n'
if ! bunx --bun oh-my-opencode --help >/dev/null; then
  status=1
fi

printf '[smoke] checking runtime scripts\n'
for script in /app/scripts/entrypoint.sh /app/scripts/bootstrap-opencode-userland.sh /app/scripts/install-oh-my-opencode.sh /app/scripts/doctor.sh /app/scripts/start-opencode-runtime.sh; do
  [[ -f "$script" ]] || { printf '[smoke] missing %s\n' "$script" >&2; status=1; }
done

exit "${status}"
