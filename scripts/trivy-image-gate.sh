#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: trivy-image-gate.sh --image IMAGE [--output PATH] [--max-fixable-critical N] [--max-fixable-high N]
       trivy-image-gate.sh --image IMAGE --policy FILE --profile NAME [--output PATH]
       trivy-image-gate.sh --filesystem DIR --policy FILE --profile NAME [--output PATH]

Scans a container image with Trivy and fails when fixable HIGH/CRITICAL
vulnerabilities exceed the configured thresholds. Findings within the
thresholds remain visible in the log and emit a GitHub Actions warning.
An explicit policy selects thresholds, protected paths, and scoped exceptions.

Set TRIVY_TIMEOUT to override the default image analysis timeout.
EOF
}

image=""
filesystem=""
output=""
policy=""
profile=""
explicit_threshold=false
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
    --filesystem)
      filesystem="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    --max-fixable-critical)
      max_fixable_critical="${2:-}"
      explicit_threshold=true
      shift 2
      ;;
    --max-fixable-high)
      max_fixable_high="${2:-}"
      explicit_threshold=true
      shift 2
      ;;
    --policy)
      policy="${2:-}"
      shift 2
      ;;
    --profile)
      profile="${2:-}"
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

if [[ -z "${image}${filesystem}" || ( -n "${image}" && -n "${filesystem}" ) ]]; then
  echo "ERROR: select exactly one of --image or --filesystem" >&2
  usage >&2
  exit 2
fi

scan_kind=image
scan_target="${image}"
if [[ -n "${filesystem}" ]]; then
  [[ -d "${filesystem}" ]] || { echo 'ERROR: filesystem scan target must be a directory' >&2; exit 2; }
  scan_kind=fs
  scan_target="$(realpath -e -- "${filesystem}")"
fi

scan_policy_args=()
if [[ -n "${policy}${profile}" ]]; then
  if [[ ! -f "${policy}" || -z "${profile}" || "${explicit_threshold}" == true ]]; then
    echo 'ERROR: use --policy FILE and --profile NAME together, without threshold overrides' >&2
    exit 2
  fi
  severity="HIGH,CRITICAL"
  # Evaluate the raw findings; implicit local ignore files must not bypass policy.
  scan_policy_args=(--ignorefile /dev/null --ignore-unfixed=false)
fi

if [[ ! "${max_fixable_critical}" =~ ^[0-9]+$ || ! "${max_fixable_high}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: thresholds must be non-negative integers" >&2
  exit 2
fi

if [[ -z "${output}" ]]; then
  safe_name="${scan_target//[^A-Za-z0-9_.-]/_}"
  output="/tmp/trivy-${safe_name}.json"
fi

mkdir -p "$(dirname "${output}")"

if command -v trivy >/dev/null 2>&1; then
  trivy "${scan_kind}" \
    --format json \
    --output "${output}" \
    --severity "${severity}" \
    --scanners vuln \
    --skip-version-check \
    --timeout "${timeout}" \
    "${scan_policy_args[@]}" \
    "${scan_target}"
else
  trivy_image="${TRIVY_DOCKER_IMAGE:-aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969}"
  cache_dir="${TRIVY_CACHE_DIR:-/tmp/trivy-cache}"
  mkdir -p "${cache_dir}"
  if [[ "${scan_kind}" == fs ]]; then
    scan_mounts=(-v "${scan_target}:/scan:ro")
    container_target=/scan
  else
    scan_mounts=(-v /var/run/docker.sock:/var/run/docker.sock)
    container_target="${image}"
  fi
  docker run --rm \
    "${scan_mounts[@]}" \
    -v "${cache_dir}:/root/.cache/" \
    "${trivy_image}" "${scan_kind}" \
      --format json \
      --severity "${severity}" \
      --scanners vuln \
      --skip-version-check \
      --timeout "${timeout}" \
      "${scan_policy_args[@]}" \
      "${container_target}" > "${output}"
fi

if [[ -n "${policy}" ]]; then
  echo "Trivy gate for ${scan_target}; report: ${output}"
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  exec python3 "${script_dir}/evaluate-trivy-policy.py" \
    --report "${output}" --policy "${policy}" --profile "${profile}"
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

echo "Trivy gate for ${scan_target}: ${summary}"
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
