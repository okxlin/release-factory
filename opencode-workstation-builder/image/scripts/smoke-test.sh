#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OPENCODE_NPM_BIN_DIR:=$HOME/.local/bin}"
mapfile -t _omo_lines < <(bash "${SCRIPT_DIR}/resolve-omo-package.sh")
omo_package="${_omo_lines[0]}"
_needs_baseline="${_omo_lines[1]:-0}"
unset _omo_lines
if [[ "${_needs_baseline}" == "1" ]]; then
  export OH_MY_OPENCODE_FORCE_BASELINE=1
fi

status=0

pass() { printf '[smoke] PASS: %s\n' "$*"; }
fail() {
  printf '[smoke] FAIL: %s\n' "$*" >&2
  status=1
}

printf '[smoke] checking required commands\n'
for cmd in node npm pnpm yarn bun python3 git sqlite3 rg fd gh jq gcc g++ make docker docker-compose go rustc cargo tsc comment-checker actionlint sudo; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "missing command: $cmd"
  else
    pass "$cmd available"
  fi
done

printf '[smoke] checking runtime identity\n'
if [[ "$(id -u)" == "0" ]]; then
  fail "runtime should not continue as root"
else
  pass "runtime user $(id -un)"
fi

printf '[smoke] checking versions\n'
node --version
npm --version
pnpm --version
yarn --version
bun --version
go version
rustc --version
cargo --version

expected_npm_prefix="${NPM_CONFIG_PREFIX:-${OPENCODE_NPM_BIN_DIR%/bin}}"
if [[ "$(npm config get prefix)" == "${expected_npm_prefix}" ]]; then
  pass "npm global prefix persistent"
else
  fail "npm global prefix should be ${expected_npm_prefix}"
fi

printf '[smoke] checking persistent directories\n'
for dir in \
  "${CONTAINER_WORKSPACE:-/workspace}" \
  "${CONTAINER_CACHE:-/cache}" \
  "$HOME/.config/opencode" \
  "$HOME/.agents" \
  "$HOME/.cache/npm" \
  "$HOME/.cargo/bin" \
  "$HOME/.claude" \
  "$HOME/.opencode" \
  "$HOME/.local/bin" \
  "$HOME/.local/share/opencode" \
  "$HOME/.local/share/oh-my-opencode" \
  "$HOME/.npm"; do
  if [[ -d "$dir" && -w "$dir" ]]; then
    pass "$dir writable"
  else
    fail "$dir missing or not writable"
  fi
done

printf '[smoke] checking Docker daemon access\n'
if [[ -S /var/run/docker.sock ]]; then
  if docker info --format '{{.ServerVersion}}'; then
    pass "docker daemon reachable"
  else
    fail "docker socket mounted but daemon not reachable"
  fi
else
  pass "docker daemon skipped (socket not mounted)"
fi

printf '[smoke] checking OpenCode\n'
if command -v opencode >/dev/null 2>&1; then
  opencode --version
  pass "opencode available"
else
  fail "opencode not installed yet; run bootstrap script"
fi

printf '[smoke] checking deprecated OpenCode config migration\n'
migration_dir="$(mktemp -d)"
printf '%s\n' '{' '  "plugin": ["opencode-gpt-unlocked@latest", "custom-plugin"],' '  "experimental": {"refusal_patcher": {"enabled": true}, "continue_loop_on_deny": true}' '}' > "${migration_dir}/opencode.json"
printf '%s\n' '{' '  "plugin": ["opencode-gpt-unlocked@1.0.1", "user-plugin"],' '  "experimental": {"refusal_patcher": {"enabled": true}}' '}' > "${migration_dir}/opencode.user.json"
if OPENCODE_CONFIG_DIR="${migration_dir}" python3 /app/scripts/update_opencode_config.py migrate-deprecated >/dev/null \
  && OPENCODE_CONFIG_DIR="${migration_dir}" OPENCODE_EXTRA_PLUGINS='opencode-gpt-unlocked@latest,env-plugin' \
    python3 /app/scripts/update_opencode_config.py plugin '@tarquinen/opencode-dcp@latest' >/dev/null \
  && python3 - "${migration_dir}" <<'PYEOF'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
generated = json.loads((root / "opencode.json").read_text(encoding="utf-8"))
user = json.loads((root / "opencode.user.json").read_text(encoding="utf-8"))
plugins = generated.get("plugin", [])
assert all(not isinstance(item, str) or not item.startswith("opencode-gpt-unlocked@") for item in plugins)
assert {"custom-plugin", "user-plugin", "env-plugin"}.issubset(plugins)
assert "refusal_patcher" not in generated.get("experimental", {})
assert generated["experimental"]["continue_loop_on_deny"] is True
assert any(item.startswith("opencode-gpt-unlocked@") for item in user["plugin"])
PYEOF
then
  pass "deprecated plugin and refusal-patcher entries are migrated without rewriting user overrides"
else
  fail "deprecated OpenCode config migration failed"
fi
rm -rf "${migration_dir}"

printf '[smoke] checking persistent OMO storage bridge\n'
if [[ -L "${HOME}/.omo" ]] \
  && [[ -d "${HOME}/.config/.omo" ]] \
  && [[ "$(readlink -f "${HOME}/.omo" 2>/dev/null || true)" == "$(readlink -f "${HOME}/.config/.omo" 2>/dev/null || true)" ]]; then
  pass "OMO storage is bridged into the persistent config mount"
else
  fail "OMO storage bridge is missing or points outside the persistent config mount"
fi

printf '[smoke] checking runtime mode\n'
case "${OPENCODE_RUNTIME_MODE:-acp}" in
  acp)
    printf '[smoke] runtime=acp target=%s:%s\n' "${ACP_HOST:-0.0.0.0}" "${ACP_PORT:-8765}"
    pass "runtime mode acp"
    ;;
  serve)
    printf '[smoke] runtime=serve target=%s:%s\n' "${SERVE_HOST:-0.0.0.0}" "${SERVE_PORT:-4096}"
    pass "runtime mode serve"
    ;;
  *)
    fail "unsupported OPENCODE_RUNTIME_MODE: ${OPENCODE_RUNTIME_MODE}"
    ;;
esac

printf '[smoke] checking oh-my-opencode resolver\n'
printf '[smoke] selected oh-my-opencode package: %s\n' "${omo_package}"
if ! npm exec --yes --package="${omo_package}" -- oh-my-opencode --help >/dev/null; then
  fail "oh-my-opencode help failed"
else
  pass "oh-my-opencode help"
fi

printf '[smoke] checking runtime scripts\n'
for script in /app/scripts/entrypoint.sh /app/scripts/bootstrap-opencode-userland.sh /app/scripts/install-oh-my-opencode.sh /app/scripts/doctor.sh /app/scripts/start-opencode-runtime.sh; do
  if [[ -f "$script" ]]; then
    pass "$script present"
  else
    fail "missing $script"
  fi
done

exit "${status}"
