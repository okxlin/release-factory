#!/usr/bin/env bash
# configure-provider.sh — 非交互式生成 Codex 自定义 provider 配置
# 由 entrypoint.sh 在 ENABLE_CUSTOM_PROVIDER=true 时调用
# 读取环境变量，写入 ~/.codex/config.toml provider 段落

set -euo pipefail

CODEX_HOME="${CODEX_HOME:-/home/dev}"
CODEX_CONFIG="${CODEX_HOME}/.codex/config.toml"
PROVIDER_DIR="${CODEX_HOME}/.codex"

ENABLE_CUSTOM_PROVIDER="${ENABLE_CUSTOM_PROVIDER:-false}"
CUSTOM_PROVIDER_NAME="${CUSTOM_PROVIDER_NAME:-custom}"
CUSTOM_PROVIDER_BASE_URL="${CUSTOM_PROVIDER_BASE_URL:-}"
CUSTOM_PROVIDER_MODEL="${CUSTOM_PROVIDER_MODEL:-}"
CUSTOM_PROVIDER_ENV_KEY="${CUSTOM_PROVIDER_ENV_KEY:-CUSTOM_API_KEY}"

if [ "${ENABLE_CUSTOM_PROVIDER}" != "true" ]; then
  exit 0
fi

if [ -z "${CUSTOM_PROVIDER_BASE_URL}" ] || [ -z "${CUSTOM_PROVIDER_MODEL}" ]; then
  echo "ERROR: ENABLE_CUSTOM_PROVIDER=true but CUSTOM_PROVIDER_BASE_URL or CUSTOM_PROVIDER_MODEL is empty." >&2
  echo "       Set both variables or set ENABLE_CUSTOM_PROVIDER=false." >&2
  exit 1
fi

mkdir -p "${PROVIDER_DIR}"

# Ensure config.toml exists
touch "${CODEX_CONFIG}"

# Check if provider section already exists
if grep -q "\\[model_providers\\.${CUSTOM_PROVIDER_NAME}\\]" "${CODEX_CONFIG}" 2>/dev/null; then
  echo "Provider [model_providers.${CUSTOM_PROVIDER_NAME}] already exists in ${CODEX_CONFIG}, skipping."
  exit 0
fi

# Append provider section
# Use env_key — never write API key plaintext into config
{
  echo ""
  echo "[model_providers.${CUSTOM_PROVIDER_NAME}]"
  echo "name = \"${CUSTOM_PROVIDER_NAME}\""
  echo "base_url = \"${CUSTOM_PROVIDER_BASE_URL}\""
  echo "env_key = \"${CUSTOM_PROVIDER_ENV_KEY}\""
  echo "wire_api = \"responses\""
} >> "${CODEX_CONFIG}"

echo "Provider [model_providers.${CUSTOM_PROVIDER_NAME}] written to ${CODEX_CONFIG}"