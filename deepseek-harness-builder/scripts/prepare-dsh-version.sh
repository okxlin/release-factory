#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image_dir="$(cd -- "${script_dir}/../image" && pwd)"
dsh_version=""
github_output_path="${GITHUB_OUTPUT:-/dev/null}"
version_resolver="${script_dir}/resolve-latest-npm-version.mjs"
source_version=""
source_ref=""
source_commit=""
source_archive_sha256=""
source_archive_url=""
source_mode=false

usage() {
  cat <<'EOF'
Usage: prepare-dsh-version.sh [options]

Options:
  --image-dir DIR        Image build context directory
  --version VERSION       DeepSeek Harness version or dist-tag; defaults to the
                          highest published npm semantic version
  --github-output FILE    GitHub Actions output file
  -h, --help              Show this help
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-dir)
      require_value "$1" "$#"
      image_dir="$(cd -- "$2" && pwd)"
      shift 2
      ;;
    --version)
      require_value "$1" "$#"
      dsh_version="$2"
      shift 2
      ;;
    --github-output)
      require_value "$1" "$#"
      github_output_path="$2"
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

if [[ -f "${image_dir}/dsh-source.json" ]]; then
  source_version="$(node - "${image_dir}/dsh-source.json" <<'NODE'
const fs = require('fs')

const sourcePath = process.argv[2]
const source = JSON.parse(fs.readFileSync(sourcePath, 'utf8'))
const semver = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/
const digest = /^[a-f0-9]{64}$/
const commit = /^[a-f0-9]{40}$/
if (source === null || typeof source !== 'object' || Array.isArray(source)) {
  throw new Error('source metadata must be a JSON object')
}
for (const field of ['version', 'repository', 'ref', 'commit', 'archiveSha256', 'archiveUrl']) {
  if (typeof source[field] !== 'string' || source[field] === '') {
    throw new Error('source metadata field ' + field + ' must be a non-empty string')
  }
}
if (!semver.test(source.version)) throw new Error('source metadata version is not valid semantic version: ' + source.version)
if (source.repository !== 'deepseek-ai/deepseek-harness') throw new Error('unexpected source repository: ' + source.repository)
if (source.ref !== 'dsh-v' + source.version) throw new Error('source ref does not match source version: ' + source.ref)
if (!commit.test(source.commit)) throw new Error('source commit is not an immutable Git commit: ' + source.commit)
if (!digest.test(source.archiveSha256)) throw new Error('source archive checksum is not a lowercase SHA-256 digest: ' + source.archiveSha256)
const expectedUrl = 'https://codeload.github.com/' + source.repository + '/tar.gz/' + source.commit
if (source.archiveUrl !== expectedUrl) throw new Error('source archive URL does not match source commit: ' + source.archiveUrl)
process.stdout.write(source.version)
NODE
)"
  source_ref="$(node -e 'const fs = require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).ref)' "${image_dir}/dsh-source.json")"
  source_commit="$(node -e 'const fs = require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).commit)' "${image_dir}/dsh-source.json")"
  source_archive_sha256="$(node -e 'const fs = require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).archiveSha256)' "${image_dir}/dsh-source.json")"
  source_archive_url="$(node -e 'const fs = require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).archiveUrl)' "${image_dir}/dsh-source.json")"
fi

if [[ -n "${dsh_version}" && -n "${source_version}" ]]; then
  case "${dsh_version}" in
    "${source_version}"|"v${source_version}"|"dsh-v${source_version}")
      dsh_version="${source_version}"
      source_mode=true
      ;;
  esac
fi

if [[ -z "${dsh_version}" ]]; then
  dsh_version="$(
    npm view @deepseek-ai/dsh versions --json --prefer-online \
      | node "${version_resolver}"
  )"
elif [[ "${source_mode}" != true ]]; then
  dsh_version="$(
    npm view "@deepseek-ai/dsh@${dsh_version}" version --json --prefer-online \
      | node "${version_resolver}"
  )"
fi

if [[ ! "${dsh_version}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf 'ERROR: invalid DeepSeek Harness version for an OCI tag: %s\n' "${dsh_version}" >&2
  exit 1
fi

node - "${image_dir}/package.json" "${dsh_version}" <<'NODE'
const fs = require('fs');

const packagePath = process.argv[2];
const dshVersion = process.argv[3];
const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
const componentPath = require('path').join(require('path').dirname(packagePath), 'components.lock.json');
if (fs.existsSync(componentPath)) {
  const pins = JSON.parse(fs.readFileSync(componentPath, 'utf8')).build_args;
  pkg.packageManager = `pnpm@${pins.PNPM_VERSION}`;
  pkg.engines = { ...pkg.engines, node: pins.NODE_VERSION };
}

pkg.version = dshVersion;
pkg.dependencies = pkg.dependencies || {};
pkg.dependencies['@deepseek-ai/dsh'] = dshVersion;

fs.writeFileSync(packagePath, `${JSON.stringify(pkg, null, 2)}\n`);
NODE

if [[ "${source_mode}" != true ]]; then
(
  cd -- "${image_dir}"
  corepack enable
  package_manager="$(node -p "require('./package.json').packageManager")"
  corepack prepare "${package_manager}" --activate
  pnpm install --lockfile-only --ignore-scripts
)
fi

resolved_version="$(cd -- "${image_dir}" && node -p "require('./package.json').dependencies['@deepseek-ai/dsh']")"
if [[ "${resolved_version}" != "${dsh_version}" ]]; then
  printf 'ERROR: package.json resolved %s, expected %s\n' "${resolved_version}" "${dsh_version}" >&2
  exit 1
fi

if [[ -n "${github_output_path}" && "${github_output_path}" != "/dev/null" ]]; then
  printf 'dsh_version=%s\n' "${dsh_version}" >> "${github_output_path}"
  printf 'dsh_source_mode=%s\n' "${source_mode}" >> "${github_output_path}"
  if [[ -n "${source_version}" ]]; then
    printf 'dsh_source_version=%s\n' "${source_version}" >> "${github_output_path}"
    printf 'dsh_source_ref=%s\n' "${source_ref}" >> "${github_output_path}"
    printf 'dsh_source_commit=%s\n' "${source_commit}" >> "${github_output_path}"
    printf 'dsh_source_archive_sha256=%s\n' "${source_archive_sha256}" >> "${github_output_path}"
    printf 'dsh_source_archive_url=%s\n' "${source_archive_url}" >> "${github_output_path}"
  fi
fi

printf 'dsh_version=%s\n' "${dsh_version}"
