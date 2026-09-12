#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
checker="${script_dir}/check-component-pins.sh"
source_dockerfile="${script_dir}/../image/Dockerfile"
source_components="${script_dir}/../image/components.lock.json"
source_metadata="${script_dir}/../image/dsh-source.json"
node_digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_args"]["NODE_IMAGE"].split("@sha256:")[1])' "${source_components}")"
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

    if bash "${checker}" --dockerfile "${dockerfile}" \
        --components-file "${4:-${source_components}}" --source-file "${5:-${source_metadata}}" >"${output}" 2>&1; then
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
sed -i '/^ARG X_MOD_VERSION$/d' "${missing_x_mod_pin}"
expect_failure 'missing-x-mod-pin' "${missing_x_mod_pin}" 'required ARG X_MOD_VERSION is missing'

missing_x_crypto_pin="${tmp_dir}/missing-x-crypto-pin.Dockerfile"
cp -- "${source_dockerfile}" "${missing_x_crypto_pin}"
sed -i '/^ARG X_CRYPTO_VERSION$/d' "${missing_x_crypto_pin}"
expect_failure 'missing-x-crypto-pin' "${missing_x_crypto_pin}" 'required ARG X_CRYPTO_VERSION is missing'

missing_npm_pin="${tmp_dir}/missing-npm-pin.Dockerfile"
cp -- "${source_dockerfile}" "${missing_npm_pin}"
sed -i '/^ARG NPM_VERSION$/d' "${missing_npm_pin}"
expect_failure 'missing-npm-pin' "${missing_npm_pin}" 'required ARG NPM_VERSION is missing'

missing_actionlint_pin="${tmp_dir}/missing-actionlint-pin.Dockerfile"
cp -- "${source_dockerfile}" "${missing_actionlint_pin}"
sed -i '/^ARG ACTIONLINT_VERSION$/d' "${missing_actionlint_pin}"
expect_failure 'missing-actionlint-pin' "${missing_actionlint_pin}" 'required ARG ACTIONLINT_VERSION is missing'

bad_uv_arch_checksum="${tmp_dir}/bad-uv-arch-checksum.Dockerfile"
cp -- "${source_dockerfile}" "${bad_uv_arch_checksum}"
python3 - "${source_components}" "${bad_uv_arch_checksum}.json" <<'PYLOCK'
import json, sys
lock=json.load(open(sys.argv[1])); lock['build_args']['UV_SHA256_ARM64']='deadbeef'
open(sys.argv[2], 'w').write(json.dumps(lock))
PYLOCK
expect_failure 'bad-uv-arch-checksum' "${bad_uv_arch_checksum}" 'ARG UV_SHA256_ARM64 must be a lowercase SHA-256 digest' "${bad_uv_arch_checksum}.json"

bad_actionlint_source_checksum="${tmp_dir}/bad-actionlint-source-checksum.Dockerfile"
cp -- "${source_dockerfile}" "${bad_actionlint_source_checksum}"
python3 - "${source_components}" "${bad_actionlint_source_checksum}.json" <<'PYLOCK'
import json, sys
lock=json.load(open(sys.argv[1])); lock['build_args']['ACTIONLINT_SOURCE_SHA256']='deadbeef'
open(sys.argv[2], 'w').write(json.dumps(lock))
PYLOCK
expect_failure 'bad-actionlint-source-checksum' "${bad_actionlint_source_checksum}" 'ARG ACTIONLINT_SOURCE_SHA256 must be a lowercase SHA-256 digest' "${bad_actionlint_source_checksum}.json"

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
sed -i '0,/^FROM ${NODE_IMAGE}/s#${NODE_IMAGE}#node:latest@sha256:'"${node_digest}"'#' "${floating_node}"
expect_failure 'floating-node' "${floating_node}" 'floating base-image tag is forbidden'

inconsistent_pnpm="${tmp_dir}/inconsistent-pnpm.Dockerfile"
cp -- "${source_dockerfile}" "${inconsistent_pnpm}"
sed -i '0,/^ARG PNPM_VERSION$/s/^ARG PNPM_VERSION$/ARG PNPM_VERSION=99.99.99/' "${inconsistent_pnpm}"
expect_failure 'inconsistent-pnpm' "${inconsistent_pnpm}" 'ARG PNPM_VERSION default belongs in the component lock'

mixed_case_arg="${tmp_dir}/mixed-case-arg.Dockerfile"
cp -- "${source_dockerfile}" "${mixed_case_arg}"
sed -i '0,/^ARG PNPM_VERSION$/s/^ARG PNPM_VERSION$/aRg PNPM_VERSION=99.99.99/' "${mixed_case_arg}"
expect_failure 'mixed-case-arg' "${mixed_case_arg}" 'ARG PNPM_VERSION default belongs in the component lock'

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
sed -i '0,/^ARG DSH_VERSION$/s/^ARG DSH_VERSION$/ARG DSH_VERSION=unexpected-value/' "${dsh_default}"
expect_failure 'dsh-default' "${dsh_default}" 'ARG DSH_VERSION default belongs in the component lock'

platform_floating="${tmp_dir}/platform-floating.Dockerfile"
cp -- "${source_dockerfile}" "${platform_floating}"
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

missing_runtime_closure="${tmp_dir}/missing-runtime-closure.Dockerfile"
cp -- "${source_dockerfile}" "${missing_runtime_closure}"
sed -i 's#node /tmp/install-dsh-runtime.mjs#npm install --ignore-scripts#' "${missing_runtime_closure}"
expect_failure 'missing-runtime-closure' "${missing_runtime_closure}" 'the DeepSeek Harness local runtime dependency closure installer'

missing_fs_ext_guard="${tmp_dir}/missing-fs-ext-guard.Dockerfile"
cp -- "${source_dockerfile}" "${missing_fs_ext_guard}"
sed -i "/if find node_modules -type d -path '\*\/fs-ext' -print -quit | grep -q .; then/d" "${missing_fs_ext_guard}"
expect_failure 'missing-fs-ext-guard' "${missing_fs_ext_guard}" 'the conditional fs-ext compatibility guard'

missing_node_addon_probe="${tmp_dir}/missing-node-addon-probe.Dockerfile"
cp -- "${source_dockerfile}" "${missing_node_addon_probe}"
sed -i '/@deepseek-ai\/node-addon-system\/flock/d' "${missing_node_addon_probe}"
expect_failure 'missing-node-addon-probe' "${missing_node_addon_probe}" 'the node-addon-system native lock probe'

missing_x_text_verification="${tmp_dir}/missing-x-text-verification.Dockerfile"
cp -- "${source_dockerfile}" "${missing_x_text_verification}"
sed -i '/grep -Eq.*x\/text.*X_TEXT_VERSION/d' "${missing_x_text_verification}"
expect_failure 'missing-x-text-verification' "${missing_x_text_verification}" 'the Caddy x/text module verification'

for version in 0.1.5 0.1.5-rc.2; do
    metadata="${tmp_dir}/source-${version}.json"
    python3 - "${source_metadata}" "${metadata}" "${version}" <<'PYSOURCE'
import json, sys
source=json.load(open(sys.argv[1])); source['version']=sys.argv[3]; source['ref']='dsh-v'+sys.argv[3]
open(sys.argv[2], 'w').write(json.dumps(source))
PYSOURCE
    bash "${checker}" --source-file "${metadata}"
    printf '[component-pins-test] PASS: stable/prerelease source version %s needs no Dockerfile edit\n' "${version}"
done

python3 - "${source_components}" "${tmp_dir}/component-update.json" <<'PYLOCK'
import json, sys
lock=json.load(open(sys.argv[1])); args=lock['build_args']
args['PNPM_VERSION']='99.99.99'; args['PNPM_ARCHIVE_SHA256']='a'*64
args['NODE_IMAGE']=args['NODE_IMAGE'].split('@sha256:')[0]+'@sha256:'+'b'*64
open(sys.argv[2], 'w').write(json.dumps(lock))
PYLOCK
bash "${checker}" --components-file "${tmp_dir}/component-update.json"
printf '[component-pins-test] PASS: component version, archive hash, and image digest update only the lock file\n'

python3 "${script_dir}/component-inputs.py" --github-output "${tmp_dir}/github-output" > "${tmp_dir}/local-inputs"
sed -n '/^build_args<<COMPONENT_INPUTS$/,/^COMPONENT_INPUTS$/p' "${tmp_dir}/github-output" | sed '1d;$d' > "${tmp_dir}/ci-inputs"
cmp "${tmp_dir}/local-inputs" "${tmp_dir}/ci-inputs"
printf '[component-pins-test] PASS: local and CI resolve identical build arguments\n'

python3 - "${script_dir}/component-inputs.py" "${source_metadata}" "${tmp_dir}" <<'PYINVALID'
import json, pathlib, subprocess, sys
script, original, directory = sys.argv[1:]
source=json.load(open(original))
for field, value in [('version', '0.1'), ('version', '0.1.5-01'), ('repository', 'other/project'),
                     ('archiveUrl', 'https://codeload.github.com/deepseek-ai/deepseek-harness/tar.gz/refs/tags/'+source['ref']),
                     ('archiveSha256', 'deadbeef'), ('commit', 'main')]:
    invalid=pathlib.Path(directory)/'invalid-source.json'
    invalid.write_text(json.dumps({**source, field:value}))
    result=subprocess.run([sys.executable,script,'--source-file',str(invalid)],capture_output=True,text=True)
    assert result.returncode==2, (field, value, result.stdout)
    print('[component-pins-test] PASS: reject invalid source '+field+'='+value)
PYINVALID
