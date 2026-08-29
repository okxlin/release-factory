#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
prepare_script="${script_dir}/prepare-dsh-version.sh"
tmp_dir="$(mktemp -d /tmp/deepseek-harness-dsh-version.XXXXXX)"
stub_dir="${tmp_dir}/bin"

cleanup() {
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${stub_dir}"

cat > "${stub_dir}/npm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${NPM_CALL_LOG}"
case "$*" in
  'view @deepseek-ai/dsh versions --json --prefer-online')
    printf '%s\n' '["0.1.0-rc.6","0.1.0-rc.7","0.1.0-rc.8"]'
    ;;
  'view @deepseek-ai/dsh@latest version --json --prefer-online')
    printf '%s\n' '"0.1.0-rc.7"'
    ;;
  'view @deepseek-ai/dsh@next version --json --prefer-online')
    printf '%s\n' '"0.1.0-rc.8"'
    ;;
  *)
    printf 'unexpected npm invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat > "${stub_dir}/corepack" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

cat > "${stub_dir}/pnpm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

chmod +x "${stub_dir}/npm" "${stub_dir}/corepack" "${stub_dir}/pnpm"

run_case() {
  local name="$1"
  local requested_version="$2"
  local expected_version="$3"
  local expected_npm_call="$4"
  local with_source_metadata="${5:-false}"
  local image_dir="${tmp_dir}/${name}"
  local github_output="${image_dir}/github-output"
  local npm_call_log="${image_dir}/npm-calls"
  local -a args=()

  mkdir -p "${image_dir}"
  cat > "${image_dir}/package.json" <<'EOF'
{
  "name": "deepseek-harness-version-test",
  "version": "0.1.0-rc.7",
  "dependencies": {
    "@deepseek-ai/dsh": "0.1.0-rc.7"
  },
  "packageManager": "pnpm@11.22.0"
}
EOF
  if [[ "${with_source_metadata}" == true ]]; then
    cat > "${image_dir}/dsh-source.json" <<'EOF'
{
  "version": "0.1.2-alpha.1",
  "repository": "deepseek-ai/deepseek-harness",
  "ref": "dsh-v0.1.2-alpha.1",
  "commit": "cd5ef8148158c3a752a658978873241fdf8e2bbc",
  "archiveSha256": "08aaf69a036d893fbc63a8feb59acd293c6970f7ccc4d77779243e8140fa359e",
  "archiveUrl": "https://codeload.github.com/deepseek-ai/deepseek-harness/tar.gz/refs/tags/dsh-v0.1.2-alpha.1"
}
EOF
  fi

  if [[ -n "${requested_version}" ]]; then
    args+=(--version "${requested_version}")
  fi

  PATH="${stub_dir}:${PATH}" \
    NPM_CALL_LOG="${npm_call_log}" \
    bash "${prepare_script}" \
      --image-dir "${image_dir}" \
      "${args[@]}" \
      --github-output "${github_output}" \
      >/dev/null

  actual_version="$(
    node -p "require(process.argv[1]).dependencies['@deepseek-ai/dsh']" \
      "${image_dir}/package.json"
  )"
  [[ "${actual_version}" == "${expected_version}" ]] \
    || fail "${name}: resolved ${actual_version}, expected ${expected_version}"
  grep -Fxq "dsh_version=${expected_version}" "${github_output}" \
    || fail "${name}: GitHub output does not contain ${expected_version}"
  if [[ -n "${expected_npm_call}" ]]; then
    grep -Fxq "${expected_npm_call}" "${npm_call_log}" \
      || fail "${name}: npm query did not match the expected resolution mode"
  fi
  printf '[dsh-version-test] PASS: %s -> %s\n' "${name}" "${expected_version}"
}

run_case \
  highest-published \
  '' \
  '0.1.0-rc.8' \
  'view @deepseek-ai/dsh versions --json --prefer-online'
run_case \
  explicit-latest-tag \
  latest \
  '0.1.0-rc.7' \
  'view @deepseek-ai/dsh@latest version --json --prefer-online'
run_case \
  explicit-next-tag \
  next \
  '0.1.0-rc.8' \
  'view @deepseek-ai/dsh@next version --json --prefer-online'
run_case \
  source-alpha-release \
  v0.1.2-alpha.1 \
  '0.1.2-alpha.1' \
  '' \
  true
