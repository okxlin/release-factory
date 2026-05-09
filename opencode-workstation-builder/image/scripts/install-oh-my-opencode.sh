#!/usr/bin/env bash
set -euo pipefail

: "${OMO_INSTALL_DIR:=$HOME/.local/share/oh-my-opencode}"
: "${OMO_PACKAGE:=oh-my-opencode}"
: "${OMO_INSTALL_ARGS:=}"
: "${OPENCODE_CONFIG_DIR:=$HOME/.config/opencode}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${OMO_INSTALL_DIR}" "$OPENCODE_CONFIG_DIR"

if ! command -v bunx >/dev/null 2>&1; then
  echo "[install-oh-my-opencode] bunx not found in PATH" >&2
  exit 1
fi

if [[ -n "${OMO_INSTALL_ARGS}" ]]; then
  install_cmd=(bunx --bun "${OMO_PACKAGE}" install --no-tui)
  # shellcheck disable=SC2206
  extra_args=( ${OMO_INSTALL_ARGS} )
  install_cmd+=("${extra_args[@]}")
else
  rendered_command="$(${SCRIPT_DIR}/render-install-command.sh)"
  # shellcheck disable=SC2206
  install_cmd=( ${rendered_command} )
fi

echo "[install-oh-my-opencode] running: ${install_cmd[*]}"
cd "${OMO_INSTALL_DIR}"
"${install_cmd[@]}"
python3 /app/scripts/update_opencode_config.py oh-my-opencode register
python3 /app/scripts/update_oh_my_openagent_config.py
python3 /app/scripts/update_opencode_config.py plugin opencode-gpt-unlocked@latest
python3 /app/scripts/update_opencode_config.py oh-my-opencode register
python3 /app/scripts/update_oh_my_openagent_config.py
