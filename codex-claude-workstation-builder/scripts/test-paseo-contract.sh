#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_DIR="${PROJECT_DIR}/image"
RUNTIME_DIR="${IMAGE_DIR}/paseo-runtime"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing required file: $1"
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "${file} is missing: ${text}"
}

require_file "${RUNTIME_DIR}/package.json"
require_file "${RUNTIME_DIR}/package-lock.json"
require_file "${RUNTIME_DIR}/LICENSE"
require_file "${RUNTIME_DIR}/UPSTREAM.md"
require_file "${IMAGE_DIR}/config/nginx/nginx.conf"
require_file "${IMAGE_DIR}/config/supervisord/conf.d/paseo.conf"
require_file "${IMAGE_DIR}/config/supervisord/conf.d/paseo-nginx.conf"
require_file "${IMAGE_DIR}/scripts/paseo-password.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../image/scripts/paseo-password.sh
source "${IMAGE_DIR}/scripts/paseo-password.sh"

for value in \
  'safe-Password_123.~' \
  "safe!#$%&'*+.^_\`|~-123"; do
  paseo_password_is_websocket_token "${value}" || \
    fail "WebSocket-token-safe Paseo password was rejected"
done

for value in \
  '' \
  'has space' \
  'has@sign' \
  'has:colon' \
  'has/slash' \
  'has=equals' \
  'has,comma'; do
  if paseo_password_is_websocket_token "${value}"; then
    fail "WebSocket-token-unsafe Paseo password was accepted"
  fi
done

too_long_password="$(printf 'a%.0s' {1..129})"
if paseo_password_is_websocket_token "${too_long_password}"; then
  fail "overlong Paseo password was accepted"
fi

license_sha256="$(sha256sum "${RUNTIME_DIR}/LICENSE" | cut -d' ' -f1)"
[ "${license_sha256}" = "2d29a730f15470509f7a36e63a024c2f121958471474dfcd6b272c99586fc337" ] || \
  fail "unexpected Paseo LICENSE digest: ${license_sha256}"

node - "${RUNTIME_DIR}/package-lock.json" <<'NODE'
const fs = require("node:fs");

const lockPath = process.argv[2];
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
const root = lock.packages?.[""];
if (root?.dependencies?.["@getpaseo/cli"] !== "0.3.1") {
  throw new Error("@getpaseo/cli must be pinned to 0.3.1");
}
if (lock.packages?.["node_modules/@getpaseo/cli"]?.version !== "0.3.1") {
  throw new Error("package-lock does not resolve @getpaseo/cli 0.3.1");
}

const installScripts = [];
for (const [name, metadata] of Object.entries(lock.packages ?? {})) {
  if (!metadata || name === "") continue;
  if (metadata.resolved) {
    if (!metadata.resolved.startsWith("https://registry.npmjs.org/")) {
      throw new Error(`non-registry package source: ${name} -> ${metadata.resolved}`);
    }
    if (!metadata.integrity) {
      throw new Error(`registry package lacks integrity: ${name}`);
    }
  }
  if (metadata.hasInstallScript) installScripts.push(name);
}

const expected = ["node_modules/@parcel/watcher", "node_modules/node-pty"];
installScripts.sort();
if (JSON.stringify(installScripts) !== JSON.stringify(expected)) {
  throw new Error(`unexpected lifecycle-script packages: ${installScripts.join(", ")}`);
}
NODE

require_text "${IMAGE_DIR}/Dockerfile" 'npm ci --omit=dev --ignore-scripts'
require_text "${IMAGE_DIR}/Dockerfile" 'npm audit signatures'
require_text "${IMAGE_DIR}/Dockerfile" 'npm audit --omit=dev --audit-level=high'
require_text "${IMAGE_DIR}/Dockerfile" 'paseo --version'
require_text "${IMAGE_DIR}/Dockerfile" 'rm -f /run/codex/nginx.pid'
require_text "${IMAGE_DIR}/Dockerfile" 'COPY scripts/paseo-password.sh /usr/local/lib/codex-workstation/paseo-password.sh'

require_text "${IMAGE_DIR}/config/nginx/nginx.conf" 'listen 6767;'
require_text "${IMAGE_DIR}/config/nginx/nginx.conf" 'proxy_pass http://127.0.0.1:6768;'
require_text "${IMAGE_DIR}/config/nginx/nginx.conf" 'proxy_set_header Host paseo.internal;'
require_text "${IMAGE_DIR}/config/nginx/nginx.conf" 'proxy_set_header Origin http://paseo.internal;'
require_text "${IMAGE_DIR}/config/nginx/nginx.conf" 'proxy_hide_header X-Powered-By;'

require_text "${IMAGE_DIR}/config/supervisord/conf.d/paseo.conf" '--listen 127.0.0.1:6768'
require_text "${IMAGE_DIR}/config/supervisord/conf.d/paseo.conf" '--no-relay'
require_text "${IMAGE_DIR}/config/supervisord/conf.d/paseo.conf" '--web-ui'
require_text "${IMAGE_DIR}/config/supervisord/conf.d/paseo.conf" '--hostnames paseo.internal'

# This is an exact source-code contract, not an expression to expand here.
# shellcheck disable=SC2016
require_text "${IMAGE_DIR}/scripts/entrypoint.sh" 'PASEO_PASSWORD="${PASEO_PASSWORD:-${PASSWORD:-change-me}}"'
require_text "${IMAGE_DIR}/scripts/entrypoint.sh" 'PASEO_VOICE_MODE_ENABLED=false'
require_text "${IMAGE_DIR}/scripts/entrypoint.sh" 'PASEO_DICTATION_ENABLED=false'
require_text "${IMAGE_DIR}/scripts/entrypoint.sh" 'PASEO_LOCAL_SPEECH_AUTO_DOWNLOAD=false'
require_text "${IMAGE_DIR}/scripts/entrypoint.sh" 'fixed-Host Nginx listener on 6767'
require_text "${IMAGE_DIR}/scripts/entrypoint.sh" 'paseo_password_is_websocket_token'
require_text "${IMAGE_DIR}/scripts/healthcheck.sh" 'fake--route.localhost'
require_text "${IMAGE_DIR}/scripts/healthcheck.sh" 'Paseo password is not browser WebSocket-token-safe'
require_text "${IMAGE_DIR}/scripts/smoke-test.sh" 'Paseo proxy hides the upstream X-Powered-By header'

if grep -Eq '^CODEX_HOME=' "${IMAGE_DIR}/scripts/entrypoint.sh"; then
  fail "entrypoint must not repurpose the Codex CODEX_HOME setting"
fi

require_text "${RUNTIME_DIR}/UPSTREAM.md" 'https://github.com/getpaseo/paseo/tree/bfec7ac3adc5e8835e873ee75c7b325af6c7a8c3'

printf 'Paseo integration contract passed.\n'
