#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$(cd "${SCRIPT_DIR}/../image" && pwd)/Dockerfile"
WORKFLOW="$(cd "${SCRIPT_DIR}/../../.github/workflows" && pwd)/release-workstations.yml"
CALLER="$(dirname "${WORKFLOW}")/build-codex-claude-workstation.yml"
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
require_pattern '^ARG PROXY_X_MOD_VERSION='
require_pattern '^ARG PROXY_GRPC_VERSION='
require_pattern '^ARG MIHOMO_COMPRESS_VERSION='
require_pattern '^ARG SING_BOX_GO_JOSE_VERSION='
require_pattern '^ARG PROXY_DHCP_VERSION='

[ -f "${RESOLVER}" ] || fail "resolver is missing: ${RESOLVER}"
[ -f "${POLICY}" ] || fail "policy is missing: ${POLICY}"
require_workflow_text 'id: proxy'
require_workflow_text 'test-resolve-proxy-core-versions.py'
require_workflow_text 'resolve-proxy-core-versions.py'
grep -Fq 'uses: ./.github/workflows/release-workstations.yml' "${CALLER}" || fail 'Codex must call the shared native build workflow'
require_workflow_occurrences 'steps.proxy.outputs.build_args' 1
require_workflow_occurrences 'needs.prepare.outputs.build_args' 1

require_text 'https://github.com/MetaCubeX/mihomo/archive/${mihomo_source_ref}.tar.gz'
require_text 'https://github.com/SagerNet/sing-box/archive/${sing_box_source_ref}.tar.gz'
require_text 'https://github.com/XTLS/Xray-core/archive/${xray_source_ref}.tar.gz'
require_text 'go mod tidy'
require_text 'golang.org/x/crypto@v${PROXY_X_CRYPTO_VERSION}'
require_text 'golang.org/x/net@v${PROXY_X_NET_VERSION}'
require_text 'golang.org/x/text@v${PROXY_X_TEXT_VERSION}'
require_text 'golang.org/x/mod@v${PROXY_X_MOD_VERSION}'
require_text 'google.golang.org/grpc@v${PROXY_GRPC_VERSION}'
require_text 'github.com/klauspost/compress@v${MIHOMO_COMPRESS_VERSION}'
require_text 'github.com/go-jose/go-jose/v4@v${SING_BOX_GO_JOSE_VERSION}'
require_text 'github.com/insomniacslk/dhcp@v${PROXY_DHCP_VERSION}'
require_text '${GOMODCACHE}/github.com/insomniacslk/dhcp@v${PROXY_DHCP_VERSION}/LICENSE'
require_text '/usr/share/doc/release-factory-go-tools/dhcp.LICENSE'
require_text 'test -s /usr/share/doc/release-factory-go-tools/dhcp.LICENSE'
require_text 'for binary in mihomo sing-box; do'
require_text 'go version -m /usr/local/bin/sing-box'
require_text 'go version -m /usr/local/bin/mihomo'
require_text 'go version -m "/usr/local/bin/${binary}"'
require_text 'Mihomo Meta ${mihomo_version}'
require_text 'sing-box version ${sing_box_version}'
require_text 'Xray ${xray_version}'

reject_text 'releases/download/v${mihomo_version}'
reject_text 'releases/download/v${sing_box_version}'
reject_text 'releases/download/v${xray_version}'

python3 - "${DOCKERFILE}" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pin = re.search(r"^ARG PROXY_DHCP_VERSION=(\S+)$", text, re.MULTILINE)
if pin is None:
    raise SystemExit("FAIL: DHCP pin is missing")
version = pin.group(1)
override = '-require="github.com/insomniacslk/dhcp@v${PROXY_DHCP_VERSION}"'
if text.count(override) != 2:
    raise SystemExit("FAIL: both proxy source builds must require the DHCP pin")
guards = [line.strip().removesuffix(" \\") for line in text.splitlines()
          if "go version -m" in line and "github.com/insomniacslk/dhcp" in line]
if len(guards) != 1:
    raise SystemExit("FAIL: the shared DHCP linked-version guard is missing")

fixture = r'''
set -o pipefail
go() {
    printf '%s\n' "$DHCP_BUILDINFO"
    return "$DHCP_INSPECT_STATUS"
}
'''
cases = [
    ("current", "v" + version, 0, True),
    ("old-mihomo", "v0.0.0-20250109001534-8abf58130905", 0, False),
    ("old-sing-box", "v0.0.0-20260220084031-5adc3eb26f91", 0, False),
    ("version-suffix", "v" + version + ".0", 0, False),
    ("missing", None, 0, False),
    ("inspection-error", "v" + version, 2, False),
]
for binary in ("mihomo", "sing-box"):
    for name, installed, status, accepted in cases:
        metadata = ("\tdep\tgithub.com/insomniacslk/dhcp\t" + installed + "\th1:fixture"
                    if installed is not None else "\tdep\tgolang.org/x/net\tv0.63.0\th1:fixture")
        env = {**os.environ, "binary": binary, "PROXY_DHCP_VERSION": version,
               "DHCP_BUILDINFO": metadata, "DHCP_INSPECT_STATUS": str(status)}
        command = fixture + guards[0] + "\nprintf 'DHCP guard continued\\n'\n"
        result = subprocess.run(["bash", "-c", command], env=env,
                                capture_output=True, text=True)
        if (result.returncode == 0) != accepted:
            raise SystemExit(f"FAIL: DHCP metadata control {binary}/{name}: {result.stderr}")
print("DHCP linked module controls passed (12 cases)")
PY

printf 'Proxy core source-build contract passed.\n'
