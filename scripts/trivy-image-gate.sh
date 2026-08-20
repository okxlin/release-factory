#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: trivy-image-gate.sh --image IMAGE [--output PATH] [--max-fixable-critical N] [--max-fixable-high N]

Scans a container image with Trivy and fails when fixable HIGH/CRITICAL
vulnerabilities exceed the configured thresholds. Findings within the
thresholds remain visible in the log and emit a GitHub Actions warning.

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
  trivy_image="${TRIVY_DOCKER_IMAGE:-aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969}"
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

python3 - "${output}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
findings = []

for result in data.get("Results", []):
    target = str(result.get("Target") or "unknown")
    for vuln in result.get("Vulnerabilities") or []:
        severity = vuln.get("Severity")
        fixed = str(vuln.get("FixedVersion") or "")
        if severity not in {"CRITICAL", "HIGH"} or not fixed:
            continue
        findings.append(
            (
                0 if severity == "CRITICAL" else 1,
                severity,
                str(vuln.get("VulnerabilityID") or "unknown"),
                str(vuln.get("PkgName") or "unknown"),
                str(vuln.get("InstalledVersion") or "unknown"),
                fixed,
                target,
            )
        )

if findings:
    print("Fixable Trivy findings:")
    for _, severity, vulnerability, package, installed, fixed, target in sorted(findings):
        fields = [severity, vulnerability, package, installed, fixed, target]
        fields = [" ".join(field.split()) for field in fields]
        print(
            f"- {fields[0]} {fields[1]}: {fields[2]} {fields[3]} -> "
            f"{fields[4]} ({fields[5]})"
        )
PY

fixable_critical="$(sed -n 's/.*fixable_critical=\([0-9][0-9]*\).*/\1/p' <<< "${summary}")"
fixable_high="$(sed -n 's/.*fixable_high=\([0-9][0-9]*\).*/\1/p' <<< "${summary}")"
if [[ "${gate_status}" -eq 0 && "${GITHUB_ACTIONS:-}" == "true" ]] \
    && (( fixable_critical > 0 || fixable_high > 0 )); then
  echo "::warning title=Fixable image vulnerabilities within configured threshold::critical=${fixable_critical}, high=${fixable_high}; see the Trivy gate log"
fi

exit "${gate_status}"
