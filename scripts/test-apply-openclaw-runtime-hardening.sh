#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
hardening_script="${script_dir}/apply-openclaw-runtime-hardening.sh"
tmp_dir="$(mktemp -d /tmp/openclaw-runtime-hardening.XXXXXX)"

cleanup() {
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

create_fixture() {
  local fixture_dir="$1"
  local stage_source="$2"

  mkdir -p "${fixture_dir}"
  git -C "${fixture_dir}" init --quiet
  cat > "${fixture_dir}/Dockerfile" <<EOF
FROM node:24-bookworm AS dependency-inputs
FROM dependency-inputs AS production-deps
FROM dependency-inputs AS build
FROM ${stage_source} AS runtime-assets
RUN rm -rf \\
      /app/node_modules/openclaw \\
      /app/node_modules/.bin/openclaw \\
      /app/node_modules/.pnpm/openclaw@*/node_modules/openclaw
FROM node:24-bookworm-slim AS base-runtime
FROM base-runtime
USER node
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw
EOF
}

run_case() {
  local name="$1"
  local stage_source="$2"
  local fixture_dir="${tmp_dir}/${name}"
  local output_file="${tmp_dir}/${name}.output"
  local dockerfile="${fixture_dir}/Dockerfile"
  local before after

  create_fixture "${fixture_dir}" "${stage_source}"
  bash "${hardening_script}" "${fixture_dir}" > "${output_file}"
  grep -Fq -- "Applied OpenClaw runtime hardening" "${output_file}"
  grep -Fq -- "FROM ${stage_source} AS runtime-assets" "${dockerfile}"
  test "$(grep -Fc -- '/app/node_modules/@vitest' "${dockerfile}")" -eq 1
  test "$(grep -Fc -- '/app/node_modules/vitest' "${dockerfile}")" -eq 1
  test "$(grep -Fc -- 'AS openclaw-runtime-docker-tools' "${dockerfile}")" -eq 1
  test "$(grep -Fc -- 'COPY --from=openclaw-runtime-docker-tools' "${dockerfile}")" -eq 1
  test "$(grep -Fc -- "npm install --global \"npm@\${OPENCLAW_NPM_VERSION}\"" "${dockerfile}")" -eq 1

  before="$(sha256sum "${dockerfile}" | cut -d ' ' -f1)"
  bash "${hardening_script}" "${fixture_dir}" > "${output_file}"
  after="$(sha256sum "${dockerfile}" | cut -d ' ' -f1)"
  grep -Fq -- "already satisfied" "${output_file}"
  test "${before}" = "${after}"
  printf '[openclaw-hardening-test] PASS: %s\n' "${name}"
}

run_case legacy-stage-source build
run_case production-deps-stage-source production-deps
run_case platform-qualified-stage-source '--platform=linux/amd64 production-deps'

missing_anchor="${tmp_dir}/missing-anchor"
create_fixture "${missing_anchor}" production-deps
sed -i '/\/app\/node_modules\/openclaw/d' "${missing_anchor}/Dockerfile"
if bash "${hardening_script}" "${missing_anchor}" > "${tmp_dir}/missing-anchor.output" 2>&1; then
  fail 'missing runtime-assets anchor unexpectedly passed'
fi
grep -Fq -- 'expected exactly one OpenClaw runtime-assets removal anchor' "${tmp_dir}/missing-anchor.output"
printf '[openclaw-hardening-test] PASS: missing anchor fails closed\n'
