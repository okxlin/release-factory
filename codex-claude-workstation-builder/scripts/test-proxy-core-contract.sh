#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$(cd "${SCRIPT_DIR}/../image" && pwd)/Dockerfile"
WORKFLOW="$(cd "${SCRIPT_DIR}/../../.github/workflows" && pwd)/build-codex-claude-workstation.yml"
RESOLVER="${SCRIPT_DIR}/resolve-proxy-core-versions.py"
POLICY="$(cd "${SCRIPT_DIR}/../configs" && pwd)/proxy-core-update-policy.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local text="$1"
  grep -Fq -- "$text" "${DOCKERFILE}" || fail "Dockerfile is missing: ${text}"
}

require_workflow_text() {
  local text="$1"
  grep -Fq -- "$text" "${WORKFLOW}" || fail "workflow is missing: ${text}"
}

require_workflow_occurrences() {
  local text="$1"
  local expected="$2"
  local actual
  actual="$(grep -F --count -- "$text" "${WORKFLOW}")"
  [ "${actual}" -eq "${expected}" ] || \
    fail "workflow must contain ${expected} occurrences of ${text}, got ${actual}"
}

require_pattern() {
  local pattern="$1"
  grep -Eq -- "$pattern" "${DOCKERFILE}" || fail "Dockerfile does not match: ${pattern}"
}

reject_text() {
  local text="$1"
  if grep -Fq -- "$text" "${DOCKERFILE}"; then
    fail "Dockerfile unexpectedly contains: ${text}"
  fi
}

# CI resolves current release and module inputs; the Dockerfile defaults remain
# a known-good fallback for local builds and are intentionally not the update source.
require_pattern '^ARG MIHOMO_VERSION='
require_pattern '^ARG MIHOMO_SOURCE_REF='
require_pattern '^ARG MIHOMO_SOURCE_SHA256='
require_pattern '^ARG SING_BOX_VERSION='
require_pattern '^ARG SING_BOX_SOURCE_REF='
require_pattern '^ARG SING_BOX_SOURCE_SHA256='
require_pattern '^ARG XRAY_VERSION='
require_pattern '^ARG XRAY_SOURCE_REF='
require_pattern '^ARG XRAY_SOURCE_SHA256='
require_pattern '^ARG PROXY_X_CRYPTO_VERSION='
require_pattern '^ARG PROXY_X_NET_VERSION='
require_pattern '^ARG PROXY_X_TEXT_VERSION='
require_pattern '^ARG PROXY_GRPC_VERSION='

[ -f "${RESOLVER}" ] || fail "resolver is missing: ${RESOLVER}"
[ -f "${POLICY}" ] || fail "policy is missing: ${POLICY}"
require_workflow_text 'id: proxy'
require_workflow_text 'test-resolve-proxy-core-versions.py'
require_workflow_text 'resolve-proxy-core-versions.py'
require_workflow_occurrences 'steps.proxy.outputs.build_args' 2

require_text 'https://github.com/MetaCubeX/mihomo/archive/${mihomo_source_ref}.tar.gz'
require_text 'https://github.com/SagerNet/sing-box/archive/${sing_box_source_ref}.tar.gz'
require_text 'https://github.com/XTLS/Xray-core/archive/${xray_source_ref}.tar.gz'
require_text 'go mod tidy'
require_text 'golang.org/x/crypto@v${PROXY_X_CRYPTO_VERSION}'
require_text 'golang.org/x/net@v${PROXY_X_NET_VERSION}'
require_text 'golang.org/x/text@v${PROXY_X_TEXT_VERSION}'
require_text 'google.golang.org/grpc@v${PROXY_GRPC_VERSION}'
require_text 'go version -m "/usr/local/bin/${binary}"'
require_text 'Mihomo Meta ${mihomo_version}'
require_text 'sing-box version ${sing_box_version}'
require_text 'Xray ${xray_version}'

reject_text 'releases/download/v${mihomo_version}'
reject_text 'releases/download/v${sing_box_version}'
reject_text 'releases/download/v${xray_version}'

printf 'Proxy core source-build contract passed.\n'
