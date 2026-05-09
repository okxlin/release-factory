#!/bin/bash
set -euo pipefail

STATE_DIR="$HOME/.local/share/opencode/state/oh-my-opencode-bootstrap"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$STATE_DIR"

cat <<MSG
[oh-my-opencode:init] Workspace container initialized.
[oh-my-opencode:init] This app is a TTY-first OpenCode workstation, not a web service.
[oh-my-opencode:init] Runtime follows the official OpenCode HOME layout:
  - ~/.config
  - ~/.agents
  - ~/.claude
  - ~/.opencode
  - ~/.local/share
[oh-my-opencode:init] Persistent runtime state example:
  ~/.local/share/opencode/state/oh-my-opencode-bootstrap
[oh-my-opencode:init] Important:
  - Install/update OpenCode and oh-my-opencode into persistent HOME paths.
  - Do NOT rely on image-baked versions as the long-term source of truth.
  - Container rebuilds should reuse persisted HOME directories.
[oh-my-opencode:init] App helper scripts are stored with this installed instance:
  ${SCRIPT_DIR}
[oh-my-opencode:init] Note:
  - /opt/1panel/scripts is not reachable inside this container.
  - Container startup now uses inline ACP bootstrap instead of depending on that path.
[oh-my-opencode:init] Recommended next steps from host or panel terminal:
  1) bash "${SCRIPT_DIR}/bootstrap-opencode-userland.sh"
  2) bash "${SCRIPT_DIR}/update-opencode-userland.sh"   # when you want to upgrade
  3) bunx oh-my-opencode install --no-tui ...
  4) Complete provider authentication
  5) Verify with: bunx oh-my-opencode doctor
MSG
