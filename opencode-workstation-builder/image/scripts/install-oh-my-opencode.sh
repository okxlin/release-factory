#!/usr/bin/env bash
set -euo pipefail

: "${OMO_INSTALL_DIR:=$HOME/.local/share/oh-my-opencode}"
: "${OMO_INSTALL_ARGS:=}"
: "${OPENCODE_CONFIG_DIR:=$HOME/.config/opencode}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t _omo_lines < <(bash "${SCRIPT_DIR}/resolve-omo-package.sh")
resolved_omo_package="${_omo_lines[0]}"
_needs_baseline="${_omo_lines[1]:-0}"
unset _omo_lines

# When baseline is needed, the Bun binary baked into the image may SIGILL
# on non-AVX2 CPUs. Bun's install script auto-detects /proc/cpuinfo and
# installs the correct baseline variant, so re-run it before npm exec.
if [[ "${_needs_baseline}" == "1" ]]; then
  export OH_MY_OPENCODE_FORCE_BASELINE=1
  _bun_bin="${BUN_INSTALL:-/opt/bun}/bin/bun"
  if ! "${_bun_bin}" --version >/dev/null 2>&1; then
    echo "[install-oh-my-opencode] reinstalling Bun baseline for non-AVX2 CPU"
    curl -fsSL https://bun.sh/install | bash -s -- "bun-v${BUN_VERSION:-1.3.14}"
    if ! "${_bun_bin}" --version >/dev/null 2>&1; then
      echo "[install-oh-my-opencode] Bun baseline reinstall failed" >&2
      exit 1
    fi
  fi
fi

mkdir -p "${OMO_INSTALL_DIR}" "$OPENCODE_CONFIG_DIR"

if ! command -v npm >/dev/null 2>&1; then
  echo "[install-oh-my-opencode] npm not found in PATH" >&2
  exit 1
fi

if [[ -n "${OMO_INSTALL_ARGS}" ]]; then
  install_cmd=(npm exec --yes --package="${resolved_omo_package}" -- oh-my-opencode install --no-tui)
  # shellcheck disable=SC2206
  extra_args=( ${OMO_INSTALL_ARGS} )
  install_cmd+=("${extra_args[@]}")
else
  rendered_command="$("${SCRIPT_DIR}/render-install-command.sh")"
  # shellcheck disable=SC2206
  install_cmd=( ${rendered_command} )
fi

echo "[install-oh-my-opencode] selected package: ${resolved_omo_package}"
echo "[install-oh-my-opencode] running: ${install_cmd[*]}"
cd "${OMO_INSTALL_DIR}"
"${install_cmd[@]}"

# oh-my-opencode >= v4.7 removed the 'mcp start' subcommand; the installer
# still writes a stale local MCP config entry.  Built-in MCPs (websearch,
# context7, grep_app, lsp) are remote HTTP servers registered by the plugin.
python3 - "${OPENCODE_CONFIG_DIR}/opencode.json" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
mcp = cfg.get("mcp", {})
if "oh-my-opencode" in mcp:
    print("[install-oh-my-opencode] removing stale oh-my-opencode MCP entry")
    del mcp["oh-my-opencode"]
    json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PYEOF

python3 /app/scripts/update_opencode_config.py oh-my-opencode register
python3 /app/scripts/update_oh_my_openagent_config.py
python3 /app/scripts/update_opencode_config.py plugin opencode-gpt-unlocked@latest
python3 /app/scripts/update_opencode_config.py oh-my-opencode register
python3 /app/scripts/update_oh_my_openagent_config.py
