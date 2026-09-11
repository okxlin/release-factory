#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
builder_dir="$(cd -- "${script_dir}/.." && pwd)"
image_dir="${builder_dir}/image"
target="runtime"
tag=""
dsh_version=""
platform=""
refresh_system_packages=false

usage() {
  cat <<'EOF'
Usage: build-local.sh [options] [-- DOCKER_BUILD_ARGS...]

Options:
  --target TARGET       Docker target: runtime, workstation, or dsh-deps (default: runtime)
  --tag TAG             Local image tag; defaults by target
  --version VERSION     DeepSeek Harness npm version/dist-tag or source release;
                        defaults to the checked-in source release
  --platform PLATFORM   Optional Docker build platform
  --refresh-system-packages  Refresh APT stages while reusing source compilation caches
  -h, --help            Show this help
EOF
}

require_value() {
  local option="$1"
  local count="$2"
  (( count >= 2 )) || {
    printf 'ERROR: %s requires a value\n' "${option}" >&2
    exit 2
  }
}

docker_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      require_value "$1" "$#"
      target="$2"
      shift 2
      ;;
    --tag)
      require_value "$1" "$#"
      tag="$2"
      shift 2
      ;;
    --version)
      require_value "$1" "$#"
      dsh_version="$2"
      shift 2
      ;;
    --platform)
      require_value "$1" "$#"
      platform="$2"
      shift 2
      ;;
    --refresh-system-packages)
      refresh_system_packages=true
      shift
      ;;
    --)
      shift
      docker_args+=("$@")
      break
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

case "${target}" in
  runtime|workstation|dsh-deps) ;;
  *)
    printf 'ERROR: target must be runtime, workstation, or dsh-deps, got: %s\n' "${target}" >&2
    exit 2
    ;;
esac

bash "${script_dir}/check-component-pins.sh" --dockerfile "${image_dir}/Dockerfile"

if [[ -z "${tag}" ]]; then
  if [[ "${target}" == "workstation" ]]; then
    tag="deepseek-harness-workstation:local"
  elif [[ "${target}" == "dsh-deps" ]]; then
    tag="deepseek-harness:dsh-deps-local"
  else
    tag="deepseek-harness:local"
  fi
fi

if [[ -z "${dsh_version}" ]]; then
  dsh_version="$(node - "${image_dir}/dsh-source.json" <<'NODE'
const fs = require('fs')
const source = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (typeof source.version !== 'string' || source.version === '') {
  throw new Error('dsh-source.json does not contain a source version')
}
process.stdout.write(source.version)
NODE
)"
fi

tmp_dir="$(mktemp -d /tmp/deepseek-harness-local-build.XXXXXX)"
cleanup() {
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

tmp_image_dir="${tmp_dir}/image"
mkdir -p -- "${tmp_image_dir}"
printf '[build-local] Build context: %s -> %s\n' "${image_dir}" "${tmp_image_dir}"
cp -a "${image_dir}/." "${tmp_image_dir}/"

if [[ "${dsh_version}" == dsh-v* ]] \
  && [[ "${dsh_version#dsh-v}" != "$(node -p "require('${tmp_image_dir}/dsh-source.json').version")" ]]; then
  "${script_dir}/resolve-dsh-source.sh" --version "${dsh_version}" \
    --metadata-output "${tmp_image_dir}/dsh-source.json" --github-output /dev/null
fi

prepare_args=(--image-dir "${tmp_image_dir}")
prepare_args+=(--version "${dsh_version}")
version_output="${tmp_dir}/version-output"
"${script_dir}/prepare-dsh-version.sh" "${prepare_args[@]}" --github-output "${version_output}"
resolved_dsh_version="$(sed -n 's/^dsh_version=//p' "${version_output}" | tail -n 1)"
[[ -n "${resolved_dsh_version}" ]] || {
  printf 'ERROR: failed to resolve DeepSeek Harness version\n' >&2
  exit 1
}

build_cmd=(
  docker build
  --target "${target}"
  -t "${tag}"
)
component_inputs="$(python3 "${script_dir}/component-inputs.py" \
  --image-dir "${tmp_image_dir}" --dsh-version "${resolved_dsh_version}")"
while IFS= read -r input; do
  build_cmd+=(--build-arg "${input}")
done <<< "${component_inputs}"
if [[ -n "${platform}" ]]; then
  build_cmd+=(--platform "${platform}")
fi
if [[ "${refresh_system_packages}" == true ]]; then
  case "${target}" in
    runtime) refresh_stages=runtime-base ;;
    workstation) refresh_stages=runtime-base,workstation ;;
    dsh-deps) refresh_stages=dsh-deps ;;
  esac
  build_cmd+=(--no-cache-filter "${refresh_stages}")
fi
build_cmd+=("${docker_args[@]}" "${tmp_image_dir}")

printf '[build-local] DeepSeek Harness: %s\n' "${resolved_dsh_version}"
printf '[build-local] Target: %s\n' "${target}"
printf '[build-local] Tag: %s\n' "${tag}"
"${build_cmd[@]}"
