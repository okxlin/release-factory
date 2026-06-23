#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: trivy-image-gate.sh --image IMAGE [--output PATH] [--max-fixable-critical N] [--max-fixable-high N]

Scans a container image with Trivy and fails when fixable HIGH/CRITICAL
vulnerabilities exceed the configured thresholds.

Set TRIVY_TIMEOUT to override the default image analysis timeout.
EOF
}

image=""
output=""
max_fixable_critical="${TRIVY_MAX_FIXABLE_CRITICAL:-0}"
max_fixable_high="${TRIVY_MAX_FIXABLE_HIGH:-999999}"
severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
timeout="${TRIVY_TIMEOUT:-20m}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      image="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    --max-fixable-critical)
      max_fixable_critical="${2:-}"
      shift 2
      ;;
    --max-fixable-high)
      max_fixable_high="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${image}" ]]; then
  echo "ERROR: --image is required" >&2
  usage >&2
  exit 2
fi

if [[ ! "${max_fixable_critical}" =~ ^[0-9]+$ || ! "${max_fixable_high}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: thresholds must be non-negative integers" >&2
  exit 2
fi

if [[ -z "${output}" ]]; then
  safe_name="${image//[^A-Za-z0-9_.-]/_}"
  output="/tmp/trivy-${safe_name}.json"
fi

mkdir -p "$(dirname "${output}")"

if command -v trivy >/dev/null 2>&1; then
  trivy image \
    --format json \
    --output "${output}" \
    --severity "${severity}" \
    --scanners vuln \
    --skip-version-check \
    --timeout "${timeout}" \
    "${image}"
else
  trivy_image="${TRIVY_DOCKER_IMAGE:-aquasec/trivy:0.63.0}"
  cache_dir="${TRIVY_CACHE_DIR:-/tmp/trivy-cache}"
  mkdir -p "${cache_dir}"
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${cache_dir}:/root/.cache/" \
    "${trivy_image}" image \
      --format json \
      --severity "${severity}" \
      --scanners vuln \
      --skip-version-check \
      --timeout "${timeout}" \
      "${image}" > "${output}"
fi

set +e
summary="$(
  python3 - "$output" "$max_fixable_critical" "$max_fixable_high" <<'PY'
import json
import sys
from collections import Counter

path, max_critical, max_high = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = json.load(open(path, encoding="utf-8"))
counts = Counter()
fixable = Counter()

for result in data.get("Results", []):
    for vuln in result.get("Vulnerabilities") or []:
        severity = vuln.get("Severity")
        if severity not in {"CRITICAL", "HIGH"}:
            continue
        counts[severity] += 1
        if vuln.get("FixedVersion"):
            fixable[severity] += 1

print(f"critical={counts['CRITICAL']} high={counts['HIGH']} "
      f"fixable_critical={fixable['CRITICAL']} fixable_high={fixable['HIGH']}")

if fixable["CRITICAL"] > max_critical or fixable["HIGH"] > max_high:
    sys.exit(1)
PY
)"
gate_status=$?
set -e

echo "Trivy gate for ${image}: ${summary}"
echo "Trivy report: ${output}"
exit "${gate_status}"
