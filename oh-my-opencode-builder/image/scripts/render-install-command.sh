#!/usr/bin/env bash
set -euo pipefail

claude_mode="${OMO_CLAUDE_MODE:-no}"
gemini_mode="${OMO_GEMINI_MODE:-${OMO_GEMINI:-0}}"
copilot_mode="${OMO_COPILOT_MODE:-${OMO_COPILOT:-0}}"

normalize_yes_no() {
  case "$1" in
    1|yes|true|on) printf 'yes' ;;
    0|no|false|off|'') printf 'no' ;;
    *) printf '%s' "$1" ;;
  esac
}

claude_mode_normalized="$claude_mode"
case "$claude_mode" in
  ''|0|no|false|off) claude_mode_normalized='no' ;;
  1|yes|true|on) claude_mode_normalized='yes' ;;
  max|pro|team|max20) claude_mode_normalized='max20' ;;
esac

gemini_mode_normalized="$(normalize_yes_no "$gemini_mode")"
copilot_mode_normalized="$(normalize_yes_no "$copilot_mode")"

args=(
  install
  --no-tui
  --claude "$claude_mode_normalized"
  --gemini "$gemini_mode_normalized"
  --copilot "$copilot_mode_normalized"
)

append_if_enabled() {
  local env_name="$1"
  local flag="$2"
  if [[ "${!env_name:-0}" == "1" ]]; then
    args+=("${flag}")
  fi
}

append_if_enabled OMO_OPENAI --openai
append_if_enabled OMO_OPENCODE_GO --opencode-go
append_if_enabled OMO_OPENCODE_ZEN --opencode-zen
append_if_enabled OMO_VERCEL_AI_GATEWAY --vercel-ai-gateway

printf 'bunx --bun oh-my-opencode'
printf ' %q' "${args[@]}"
printf '\n'
