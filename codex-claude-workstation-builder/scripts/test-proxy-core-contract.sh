#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$(cd "${SCRIPT_DIR}/../image" && pwd)/Dockerfile"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local text="$1"
  grep -Fq -- "$text" "${DOCKERFILE}" || fail "Dockerfile is missing: ${text}"
}

reject_text() {
  local text="$1"
  if grep -Fq -- "$text" "${DOCKERFILE}"; then
    fail "Dockerfile unexpectedly contains: ${text}"
  fi
}

# Keep proxy-core inputs immutable and reviewable. Updating one of these pins
# requires updating this contract and rechecking the resulting binaries.
require_text 'ARG MIHOMO_VERSION=1.19.30'
require_text 'ARG MIHOMO_SOURCE_REF=ac017cdd246ce8bd547653d927e7bf77d7ee73d5'
require_text 'ARG MIHOMO_SOURCE_SHA256=971dd4533e4e2c3dad7473e8115200da8c0d7471b4b61da54da896345c5b3850'
require_text 'ARG SING_BOX_VERSION=1.14.0'
require_text 'ARG SING_BOX_SOURCE_REF=0b8995879f29a9b98ee027bc17b75e101445b238'
require_text 'ARG SING_BOX_SOURCE_SHA256=faa17ef1634429371401b495f32c498fa35b92e5872dce245ba44a9155f95f14'
require_text 'ARG XRAY_VERSION=26.7.28'
require_text 'ARG XRAY_SOURCE_REF=5ca6f4b7d4dc20a881d4330e498892697627ec0c'
require_text 'ARG XRAY_SOURCE_SHA256=45de3ead5186fea442b04c662c554a1ffd1d7bd9093a83410f2edabe74fb766e'
require_text 'ARG PROXY_X_CRYPTO_VERSION=0.55.0'
require_text 'ARG PROXY_X_NET_VERSION=0.58.0'
require_text 'ARG PROXY_X_TEXT_VERSION=0.41.0'
require_text 'ARG PROXY_GRPC_VERSION=1.83.1'

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
