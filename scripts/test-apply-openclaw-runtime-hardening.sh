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
COPY . .
RUN pnpm canvas:a2ui:bundle
RUN pnpm build:docker && pnpm ui:build
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
  test "$(grep -Fc -- 'node /tmp/prune-native-typescript.mjs /app' "${dockerfile}")" -eq 1
  test -f "${fixture_dir}/.release-factory-runtime/prune-native-typescript.mjs"
  python3 - "${dockerfile}" <<'PY'
from pathlib import Path
import sys
stage = ''
copy_line = build_patch_line = cache_line = canvas_line = runtime_patch_line = None
mount_counts = {'build': 0, 'runtime': 0}
for index, line in enumerate(Path(sys.argv[1]).read_text().splitlines()):
    if line.startswith('FROM '):
        stage = line
    if stage.endswith(' AS build') and line == 'COPY . .':
        copy_line = index
    if 'RUN --mount=type=bind,source=.release-factory-runtime,target=/tmp/release-factory-runtime ' in line:
        mount_counts['build' if stage.endswith(' AS build') else 'runtime'] += 1
    if 'node /tmp/release-factory-runtime/patch-vendored-deps.mjs --build' in line:
        assert stage.endswith(' AS build'), stage
        build_patch_line = index
    elif 'node /tmp/release-factory-runtime/patch-vendored-deps.mjs' in line:
        assert stage == 'FROM base-runtime', stage
        runtime_patch_line = index
    if '&& rm -f extensions/canvas/src/host/a2ui/.bundle.hash' in line:
        assert stage.endswith(' AS build'), stage
        cache_line = index
    if 'RUN pnpm canvas:a2ui:bundle' in line:
        canvas_line = index
    if 'node /tmp/prune-native-typescript.mjs /app' in line:
        assert stage.endswith(' AS runtime-assets'), stage
assert copy_line < build_patch_line < cache_line < canvas_line < runtime_patch_line
assert cache_line == build_patch_line + 1
assert mount_counts == {'build': 1, 'runtime': 1}, mount_counts
PY
  test "$(grep -Fc -- 'AS openclaw-runtime-docker-tools' "${dockerfile}")" -eq 1
  test "$(grep -Fc -- 'ARG SECURITY_REFRESH=manual' "${dockerfile}")" -eq 1
  test "$(grep -Fc -- 'RUN --mount=type=bind,from=openclaw-runtime-docker-tools' "${dockerfile}")" -eq 1
  if grep -Fq -- 'COPY --from=openclaw-runtime-docker-tools' "${dockerfile}"; then
    fail 'temporary Docker tool binaries would be retained in an image layer'
  fi
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

assert_rejected() {
  local fixture_dir="$1"
  local message="$2"
  local name="$3"
  local before after
  before="$(sha256sum "${fixture_dir}/Dockerfile" | cut -d ' ' -f1)"
  if bash "${hardening_script}" "${fixture_dir}" > "${tmp_dir}/${name}.output" 2>&1; then
    fail "${name} unexpectedly passed"
  fi
  grep -Fq -- "${message}" "${tmp_dir}/${name}.output"
  after="$(sha256sum "${fixture_dir}/Dockerfile" | cut -d ' ' -f1)"
  test "${before}" = "${after}"
  printf '[openclaw-hardening-test] PASS: %s fails closed\n' "${name}"
}

missing_build="${tmp_dir}/missing-build-stage"
create_fixture "${missing_build}" production-deps
sed -i 's/FROM dependency-inputs AS build/FROM dependency-inputs AS compiler/' "${missing_build}/Dockerfile"
assert_rejected "${missing_build}" 'expected exactly one FROM ... AS build stage' missing-build-stage

missing_copy="${tmp_dir}/missing-build-copy"
create_fixture "${missing_copy}" production-deps
sed -i '/^COPY \. \.$/d' "${missing_copy}/Dockerfile"
assert_rejected "${missing_copy}" 'expected exactly one full COPY . . anchor in the build stage' missing-build-copy

duplicate_build="${tmp_dir}/duplicate-build-stage"
create_fixture "${duplicate_build}" production-deps
sed -i '/^FROM dependency-inputs AS build$/a FROM dependency-inputs AS build' "${duplicate_build}/Dockerfile"
assert_rejected "${duplicate_build}" 'expected exactly one FROM ... AS build stage' duplicate-build-stage

duplicate_copy="${tmp_dir}/duplicate-build-copy"
create_fixture "${duplicate_copy}" production-deps
sed -i '/^COPY \. \.$/a COPY . .' "${duplicate_copy}/Dockerfile"
assert_rejected "${duplicate_copy}" 'expected exactly one full COPY . . anchor in the build stage' duplicate-build-copy

partial_build="${tmp_dir}/partial-build-patch"
create_fixture "${partial_build}" production-deps
bash "${hardening_script}" "${partial_build}" > "${tmp_dir}/partial-build-setup.output"
sed -i '/node \/tmp\/release-factory-runtime\/patch-vendored-deps.mjs --build/d' "${partial_build}/Dockerfile"
assert_rejected "${partial_build}" 'OpenClaw build dependency hardening is only partially present' partial-build-patch

partial_cache="${tmp_dir}/partial-build-cache"
create_fixture "${partial_cache}" production-deps
bash "${hardening_script}" "${partial_cache}" > "${tmp_dir}/partial-cache-setup.output"
sed -i '/&& rm -f extensions\/canvas\/src\/host\/a2ui\/.bundle.hash/d' "${partial_cache}/Dockerfile"
assert_rejected "${partial_cache}" 'OpenClaw build dependency hardening is only partially present' partial-build-cache

duplicate_patch="${tmp_dir}/duplicate-build-patch"
create_fixture "${duplicate_patch}" production-deps
bash "${hardening_script}" "${duplicate_patch}" > "${tmp_dir}/duplicate-patch-setup.output"
sed -i '/node \/tmp\/release-factory-runtime\/patch-vendored-deps.mjs --build/p' "${duplicate_patch}/Dockerfile"
assert_rejected "${duplicate_patch}" 'OpenClaw build dependency hardening is duplicated' duplicate-build-patch

partial_runtime="${tmp_dir}/partial-runtime-patch"
create_fixture "${partial_runtime}" production-deps
bash "${hardening_script}" "${partial_runtime}" > "${tmp_dir}/partial-runtime-setup.output"
sed -i '/^    node \/tmp\/release-factory-runtime\/patch-vendored-deps.mjs$/d' "${partial_runtime}/Dockerfile"
assert_rejected "${partial_runtime}" 'OpenClaw runtime dependency hardening is only partially present' partial-runtime-patch

early_bundle="${tmp_dir}/early-build-bundle"
create_fixture "${early_bundle}" production-deps
sed -i '/^COPY \. \.$/i RUN pnpm canvas:a2ui:bundle' "${early_bundle}/Dockerfile"
assert_rejected "${early_bundle}" 'build bundle command precedes the full source COPY anchor' early-build-bundle
