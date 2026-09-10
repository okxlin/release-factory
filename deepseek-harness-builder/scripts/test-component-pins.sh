#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
checker="${script_dir}/check-component-pins.sh"
source_dockerfile="${script_dir}/../image/Dockerfile"
tmp_dir="$(mktemp -d /tmp/deepseek-harness-component-pins.XXXXXX)"

cleanup() {
    rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local name="$1"
    local dockerfile="$2"
    local expected_message="$3"
    local output="${tmp_dir}/${name}.output"

    if bash "${checker}" --dockerfile "${dockerfile}" >"${output}" 2>&1; then
        fail "${name}: checker unexpectedly passed"
    fi
    grep -Fq -- "${expected_message}" "${output}" \
        || fail "${name}: expected failure message was not emitted"
    printf '[component-pins-test] PASS: %s\n' "${name}"
}

baseline="${tmp_dir}/baseline.Dockerfile"
cp -- "${source_dockerfile}" "${baseline}"
bash "${checker}" --dockerfile "${baseline}"
printf '[component-pins-test] PASS: baseline Dockerfile\n'

missing_x_mod_pin="${tmp_dir}/missing-x-mod-pin.Dockerfile"
cp -- "${source_dockerfile}" "${missing_x_mod_pin}"
sed -i '/^ARG X_MOD_VERSION=/d' "${missing_x_mod_pin}"
expect_failure 'missing-x-mod-pin' "${missing_x_mod_pin}" 'required ARG X_MOD_VERSION is missing'

missing_x_crypto_pin="${tmp_dir}/missing-x-crypto-pin.Dockerfile"
cp -- "${source_dockerfile}" "${missing_x_crypto_pin}"
sed -i '/^ARG X_CRYPTO_VERSION=/d' "${missing_x_crypto_pin}"
expect_failure 'missing-x-crypto-pin' "${missing_x_crypto_pin}" 'required ARG X_CRYPTO_VERSION is missing'

missing_npm_pin="${tmp_dir}/missing-npm-pin.Dockerfile"
cp -- "${source_dockerfile}" "${missing_npm_pin}"
sed -i '/^ARG NPM_VERSION=/d' "${missing_npm_pin}"
expect_failure 'missing-npm-pin' "${missing_npm_pin}" 'required ARG NPM_VERSION is missing'

missing_actionlint_pin="${tmp_dir}/missing-actionlint-pin.Dockerfile"
cp -- "${source_dockerfile}" "${missing_actionlint_pin}"
sed -i '/^ARG ACTIONLINT_VERSION=/d' "${missing_actionlint_pin}"
expect_failure 'missing-actionlint-pin' "${missing_actionlint_pin}" 'required ARG ACTIONLINT_VERSION is missing'

bad_uv_arch_checksum="${tmp_dir}/bad-uv-arch-checksum.Dockerfile"
cp -- "${source_dockerfile}" "${bad_uv_arch_checksum}"
sed -i 's/^ARG UV_SHA256_ARM64=.*/ARG UV_SHA256_ARM64=deadbeef/' "${bad_uv_arch_checksum}"
expect_failure 'bad-uv-arch-checksum' "${bad_uv_arch_checksum}" 'ARG UV_SHA256_ARM64 must be a lowercase SHA-256 digest'

bad_actionlint_source_checksum="${tmp_dir}/bad-actionlint-source-checksum.Dockerfile"
cp -- "${source_dockerfile}" "${bad_actionlint_source_checksum}"
sed -i 's/^ARG ACTIONLINT_SOURCE_SHA256=.*/ARG ACTIONLINT_SOURCE_SHA256=deadbeef/' "${bad_actionlint_source_checksum}"
expect_failure 'bad-actionlint-source-checksum' "${bad_actionlint_source_checksum}" 'ARG ACTIONLINT_SOURCE_SHA256 must be a lowercase SHA-256 digest'

missing_actionlint_source_verification="${tmp_dir}/missing-actionlint-source-verification.Dockerfile"
cp -- "${source_dockerfile}" "${missing_actionlint_source_verification}"
sed -i '/ACTIONLINT_SOURCE_SHA256.*sha256sum -c/d' "${missing_actionlint_source_verification}"
expect_failure 'missing-actionlint-source-verification' "${missing_actionlint_source_verification}" 'the actionlint source checksum verification'

restored_rust_stage="${tmp_dir}/restored-rust-stage.Dockerfile"
cp -- "${source_dockerfile}" "${restored_rust_stage}"
printf '\nFROM rust:1.97.1-slim-trixie@sha256:%s AS compiler\n' "${node_digest:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" >> "${restored_rust_stage}"
expect_failure 'restored-rust-stage' "${restored_rust_stage}" 'Dockerfile must not use a Rust base image'

floating_node="${tmp_dir}/floating-node.Dockerfile"
cp -- "${source_dockerfile}" "${floating_node}"
sed -i '0,/^FROM node:/s#node:[^@[:space:]]*#node:latest#' "${floating_node}"
expect_failure 'floating-node' "${floating_node}" 'floating base-image tag is forbidden'

inconsistent_pnpm="${tmp_dir}/inconsistent-pnpm.Dockerfile"
cp -- "${source_dockerfile}" "${inconsistent_pnpm}"
sed -i '0,/^[[:space:]]*ARG PNPM_VERSION=/s/^\([[:space:]]*ARG PNPM_VERSION=\)[^[:space:]]*/\199.99.99/' "${inconsistent_pnpm}"
expect_failure 'inconsistent-pnpm' "${inconsistent_pnpm}" 'ARG PNPM_VERSION has inconsistent defaults'

mixed_case_arg="${tmp_dir}/mixed-case-arg.Dockerfile"
cp -- "${source_dockerfile}" "${mixed_case_arg}"
sed -i '0,/^[[:space:]]*ARG PNPM_VERSION=/s/^\([[:space:]]*\)ARG PNPM_VERSION=/\1aRg PNPM_VERSION=99.99.99/' "${mixed_case_arg}"
expect_failure 'mixed-case-arg' "${mixed_case_arg}" 'ARG PNPM_VERSION has inconsistent defaults'

bad_checksum="${tmp_dir}/bad-checksum.Dockerfile"
cp -- "${source_dockerfile}" "${bad_checksum}"
sed -i 's#^ADD --checksum=sha256:${DSH_SOURCE_ARCHIVE_SHA256}#ADD --checksum=sha256:deadbeef#' "${bad_checksum}"
expect_failure 'bad-checksum' "${bad_checksum}" 'remote ADD must use a lowercase SHA-256 checksum'

mixed_case_add="${tmp_dir}/mixed-case-add.Dockerfile"
cp -- "${source_dockerfile}" "${mixed_case_add}"
sed -i 's#^ADD --checksum=sha256:${DSH_SOURCE_ARCHIVE_SHA256}#aDd --checksum=sha256:deadbeef#' "${mixed_case_add}"
expect_failure 'mixed-case-add' "${mixed_case_add}" 'remote ADD must use a lowercase SHA-256 checksum'

local_bad_checksum="${tmp_dir}/local-bad-checksum.Dockerfile"
cp -- "${source_dockerfile}" "${local_bad_checksum}"
sed -i '2iADD --checksum=sha256:deadbeef package.json /tmp/package.json' "${local_bad_checksum}"
expect_failure 'local-bad-checksum' "${local_bad_checksum}" 'ADD checksum must be lowercase sha256:<64-hex>'

dsh_default="${tmp_dir}/dsh-default.Dockerfile"
cp -- "${source_dockerfile}" "${dsh_default}"
sed -i '0,/^[[:space:]]*ARG DSH_VERSION=[^[:space:]]*$/s/^\([[:space:]]*ARG DSH_VERSION=\)[^[:space:]]*/\1unexpected-value/' "${dsh_default}"
expect_failure 'dsh-default' "${dsh_default}" 'ARG DSH_VERSION has inconsistent defaults'

platform_floating="${tmp_dir}/platform-floating.Dockerfile"
cp -- "${source_dockerfile}" "${platform_floating}"
node_digest="$(sed -n 's/^FROM node:[^@[:space:]]*@sha256:\([a-f0-9]\{64\}\).*/\1/p' "${source_dockerfile}" | head -n 1)"
[[ "${node_digest}" =~ ^[a-f0-9]{64}$ ]] || fail 'failed to find the pinned Node digest'
printf '\nFROM --platform=linux/amd64 node:main@sha256:%s AS unchecked-platform-stage\n' "${node_digest}" >> "${platform_floating}"
expect_failure 'platform-floating' "${platform_floating}" 'floating base-image tag is forbidden'

mixed_case_from="${tmp_dir}/mixed-case-from.Dockerfile"
cp -- "${source_dockerfile}" "${mixed_case_from}"
printf '\nfRoM --platform=linux/amd64 node:main@sha256:%s aS unchecked-mixed-case-stage\n' "${node_digest}" >> "${mixed_case_from}"
expect_failure 'mixed-case-from' "${mixed_case_from}" 'floating base-image tag is forbidden'

aliased_node="${tmp_dir}/aliased-node.Dockerfile"
cp -- "${source_dockerfile}" "${aliased_node}"
printf '\nFROM docker.io/library/node:99.99.99-trixie-slim@sha256:%s AS aliased-node-stage\n' "${node_digest}" >> "${aliased_node}"
expect_failure 'aliased-node' "${aliased_node}" 'Node base-image tag 99.99.99-trixie-slim does not match the other Node stages'

mismatched_source="${tmp_dir}/mismatched-source.Dockerfile"
cp -- "${source_dockerfile}" "${mismatched_source}"
sed -i 's#https://codeload.github.com/docker/cli/tar.gz/refs/tags/v[^[:space:]]*#https://codeload.github.com/docker/cli/tar.gz/refs/tags/v0.0.0#' "${mismatched_source}"
expect_failure 'mismatched-source' "${mismatched_source}" 'unrecognized remote ADD URL'

missing_dsh_pack_lifecycle="${tmp_dir}/missing-dsh-pack-lifecycle.Dockerfile"
cp -- "${source_dockerfile}" "${missing_dsh_pack_lifecycle}"
sed -i 's#npm_execpath="$(command -v pnpm)" DSH_CLIENT_COMMIT_HASH="${DSH_SOURCE_COMMIT}" CI=true pnpm exec tsx scripts/release/pack.ts --family dsh#DSH_CLIENT_COMMIT_HASH="${DSH_SOURCE_COMMIT}" CI=true pnpm exec tsx scripts/release/pack.ts --family dsh#' "${missing_dsh_pack_lifecycle}"
expect_failure 'missing-dsh-pack-lifecycle' "${missing_dsh_pack_lifecycle}" 'the DeepSeek Harness dsh release pack invocation with pnpm lifecycle metadata'

missing_vendor_pack_lifecycle="${tmp_dir}/missing-vendor-pack-lifecycle.Dockerfile"
cp -- "${source_dockerfile}" "${missing_vendor_pack_lifecycle}"
sed -i 's#npm_execpath="$(command -v pnpm)" DSH_CLIENT_COMMIT_HASH="${DSH_SOURCE_COMMIT}" CI=true pnpm exec tsx scripts/release/pack.ts --family vendor#DSH_CLIENT_COMMIT_HASH="${DSH_SOURCE_COMMIT}" CI=true pnpm exec tsx scripts/release/pack.ts --family vendor#' "${missing_vendor_pack_lifecycle}"
expect_failure 'missing-vendor-pack-lifecycle' "${missing_vendor_pack_lifecycle}" 'the DeepSeek Harness vendor release pack invocation with pnpm lifecycle metadata'

missing_fs_ext_guard="${tmp_dir}/missing-fs-ext-guard.Dockerfile"
cp -- "${source_dockerfile}" "${missing_fs_ext_guard}"
sed -i "/if find node_modules -type d -path '\*\/fs-ext' -print -quit | grep -q .; then/d" "${missing_fs_ext_guard}"
expect_failure 'missing-fs-ext-guard' "${missing_fs_ext_guard}" 'the conditional fs-ext compatibility guard'

missing_node_addon_probe="${tmp_dir}/missing-node-addon-probe.Dockerfile"
cp -- "${source_dockerfile}" "${missing_node_addon_probe}"
sed -i '/@deepseek-ai\/node-addon-system\/flock/d' "${missing_node_addon_probe}"
expect_failure 'missing-node-addon-probe' "${missing_node_addon_probe}" 'the node-addon-system native lock probe'
