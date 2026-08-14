#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${CADDY_SCAN_IMAGE:-deepseek-harness:ci-amd64}"
EXPECTED_STRIPPED_BINARY_FINDING="GO-2026-5932"

usage() {
    cat <<'EOF'
Usage: check-caddy-vulnerabilities.sh [--image IMAGE]

Runs govulncheck against the Caddy binary embedded in the image. Caddy's
production build is stripped, so govulncheck can fall back to module-level
findings. The only accepted fallback is GO-2026-5932 when the build-produced Go
package manifest proves that no openpgp package is linked.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -ge 2 ]] || { printf 'ERROR: --image requires a value\n' >&2; exit 2; }
            IMAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unsupported argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for command_name in docker go govulncheck; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'ERROR: required command is missing: %s\n' "${command_name}" >&2
        exit 1
    }
done

docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
    printf 'ERROR: image does not exist locally: %s\n' "${IMAGE}" >&2
    exit 1
}

temp_dir="$(mktemp -d /tmp/deepseek-harness-caddy-scan.XXXXXX)"
container_id=""

cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "${container_id}" ]]; then
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
    fi
    for temp_file in caddy CADDY_GO_PACKAGES.txt; do
        if [[ -f "${temp_dir}/${temp_file}" ]]; then
            unlink "${temp_dir}/${temp_file}"
        fi
    done
    rmdir "${temp_dir}" 2>/dev/null || true
    exit "${status}"
}
trap cleanup EXIT

container_id="$(docker create "${IMAGE}")"
docker cp "${container_id}:/usr/bin/caddy" "${temp_dir}/caddy" >/dev/null
docker cp \
    "${container_id}:/usr/share/licenses/deepseek-harness-caddy/CADDY_GO_PACKAGES.txt" \
    "${temp_dir}/CADDY_GO_PACKAGES.txt" >/dev/null
docker rm "${container_id}" >/dev/null
container_id=""

grep -Fxq 'golang.org/x/crypto/ssh' "${temp_dir}/CADDY_GO_PACKAGES.txt" || {
    printf 'ERROR: Caddy package manifest does not contain the retained SSH implementation\n' >&2
    exit 1
}
if grep -Eq '^golang\.org/x/crypto/openpgp(/|$)' "${temp_dir}/CADDY_GO_PACKAGES.txt"; then
    printf 'ERROR: an OpenPGP package is linked into Caddy\n' >&2
    exit 1
fi
printf '[caddy-scan] PASS: OpenPGP packages are absent from the linked Go dependency graph\n'

set +e
scan_output="$(govulncheck -mode=binary "${temp_dir}/caddy" 2>&1)"
scan_status=$?
set -e
printf '%s\n' "${scan_output}"

if (( scan_status == 0 )); then
    printf '[caddy-scan] PASS: govulncheck reported no reachable vulnerabilities\n'
    exit 0
fi
if (( scan_status != 3 )); then
    printf 'ERROR: govulncheck failed with unexpected status %d\n' "${scan_status}" >&2
    exit "${scan_status}"
fi

mapfile -t finding_ids < <(
    sed -nE 's/.*(GO-[0-9]{4}-[0-9]+).*/\1/p' <<< "${scan_output}" \
        | LC_ALL=C sort -u
)
finding_count="$(grep -Ec '^Vulnerability #[0-9]+:' <<< "${scan_output}" || true)"

if (( finding_count != 1 )) \
    || (( ${#finding_ids[@]} != 1 )) \
    || [[ "${finding_ids[0]:-}" != "${EXPECTED_STRIPPED_BINARY_FINDING}" ]]; then
    printf 'ERROR: govulncheck reported an unaccepted Caddy finding\n' >&2
    exit 1
fi

if go tool nm "${temp_dir}/caddy" >/dev/null 2>&1; then
    printf 'ERROR: refusing the stripped-binary exception because Go symbols are available\n' >&2
    exit 1
fi

printf '%s\n' \
    "[caddy-scan] PASS: accepted ${EXPECTED_STRIPPED_BINARY_FINDING} only as a stripped-binary module-level finding; the linked package manifest excludes OpenPGP"
printf '%s\n' \
    '[caddy-scan] Reference: https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck#hdr-Limitations'
