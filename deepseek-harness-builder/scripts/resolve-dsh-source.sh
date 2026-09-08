#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_repo="deepseek-ai/deepseek-harness"
requested_version=""
github_output_path="${GITHUB_OUTPUT:-/dev/null}"
metadata_output_path=""

usage() {
    cat <<'EOF'
Usage: resolve-dsh-source.sh [options]

Resolve and verify the highest published DeepSeek Harness GitHub source release.

Options:
  --version VERSION       Exact source release, version, or dsh-v tag; defaults to highest
  --github-output FILE    GitHub Actions output file
  --metadata-output FILE Write verified source metadata JSON to this file
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
        --version)
            require_value "$1" "$#"
            requested_version="$2"
            shift 2
            ;;
        --github-output)
            require_value "$1" "$#"
            github_output_path="$2"
            shift 2
            ;;
        --metadata-output)
            require_value "$1" "$#"
            metadata_output_path="$2"
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

command -v curl >/dev/null 2>&1 || {
    printf 'ERROR: curl is required\n' >&2
    exit 2
}
command -v node >/dev/null 2>&1 || {
    printf 'ERROR: node is required\n' >&2
    exit 2
}
command -v sha256sum >/dev/null 2>&1 || {
    printf 'ERROR: sha256sum is required\n' >&2
    exit 2
}
command -v tar >/dev/null 2>&1 || {
    printf 'ERROR: tar is required\n' >&2
    exit 2
}

tmp_dir="$(mktemp -d /tmp/deepseek-harness-source.XXXXXX)"
cleanup() {
    rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

curl_common_args=(
    --fail
    --location
    --retry 3
    --silent
    --show-error
    --proto '=https'
    --tlsv1.2
    --connect-timeout 15
    --max-time 120
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_common_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

github_api() {
    curl "${curl_common_args[@]}" \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        "$1"
}

releases_json="${tmp_dir}/releases.json"
github_api "https://api.github.com/repos/${source_repo}/releases?per_page=100" >"${releases_json}"

selection_json="${tmp_dir}/selection.json"
selection_args=(--select "${releases_json}")
if [[ -n "${requested_version}" ]]; then
    selection_args+=("${requested_version}")
fi
node "${script_dir}/resolve-dsh-source.mjs" "${selection_args[@]}" >"${selection_json}"

source_version="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version)' "${selection_json}")"
source_ref="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).tag)' "${selection_json}")"
[[ "${source_ref}" == "dsh-v${source_version}" ]] || {
    printf 'ERROR: resolved source tag does not match version: %s / %s\n' "${source_ref}" "${source_version}" >&2
    exit 1
}

commit_json="${tmp_dir}/commit.json"
github_api "https://api.github.com/repos/${source_repo}/commits/${source_ref}" >"${commit_json}"
source_commit="$(node -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")).sha; if (typeof value !== "string") throw new Error("GitHub commit response has no sha"); process.stdout.write(value)' "${commit_json}")"
[[ "${source_commit}" =~ ^[a-f0-9]{40}$ ]] || {
    printf 'ERROR: resolved source commit is not an immutable Git commit: %s\n' "${source_commit}" >&2
    exit 1
}

archive_url="https://codeload.github.com/${source_repo}/tar.gz/refs/tags/${source_ref}"
archive_path="${tmp_dir}/dsh-source.tar.gz"
curl "${curl_common_args[@]}" "${archive_url}" -o "${archive_path}"
source_archive_sha256="$(sha256sum "${archive_path}" | awk '{print $1}')"
[[ "${source_archive_sha256}" =~ ^[a-f0-9]{64}$ ]] || {
    printf 'ERROR: failed to compute source archive SHA-256\n' >&2
    exit 1
}

source_root="${tmp_dir}/source"
mkdir -p -- "${source_root}"
tar --extract --gzip --file "${archive_path}" --directory "${source_root}" --strip-components=1 --no-same-owner
SOURCE_ROOT="${source_root}" SOURCE_VERSION="${source_version}" node <<'NODE'
const fs = require('fs')

const root = process.env.SOURCE_ROOT
const expectedVersion = process.env.SOURCE_VERSION
for (const relativePath of ['package.json', 'apps/cli/package.json']) {
  const packagePath = `${root}/${relativePath}`
  const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
  if (packageJson.version !== expectedVersion) {
    throw new Error(`${relativePath} version ${packageJson.version} does not match ${expectedVersion}`)
  }
}
NODE

if [[ -n "${metadata_output_path}" ]]; then
    SOURCE_VERSION="${source_version}" \
    SOURCE_REPOSITORY="${source_repo}" \
    SOURCE_REF="${source_ref}" \
    SOURCE_COMMIT="${source_commit}" \
    SOURCE_ARCHIVE_SHA256="${source_archive_sha256}" \
    SOURCE_ARCHIVE_URL="${archive_url}" \
    node - "${metadata_output_path}" <<'NODE'
const fs = require('fs')

const metadataPath = process.argv[2]
const metadata = {
  version: process.env.SOURCE_VERSION,
  repository: process.env.SOURCE_REPOSITORY,
  ref: process.env.SOURCE_REF,
  commit: process.env.SOURCE_COMMIT,
  archiveSha256: process.env.SOURCE_ARCHIVE_SHA256,
  archiveUrl: process.env.SOURCE_ARCHIVE_URL,
}
fs.writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`)
NODE
fi

write_output() {
    local name="$1"
    local value="$2"
    if [[ -n "${github_output_path}" && "${github_output_path}" != "/dev/null" ]]; then
        printf '%s=%s\n' "${name}" "${value}" >>"${github_output_path}"
    fi
}

write_output dsh_source_version "${source_version}"
write_output dsh_source_ref "${source_ref}"
write_output dsh_source_commit "${source_commit}"
write_output dsh_source_archive_sha256 "${source_archive_sha256}"
write_output dsh_source_archive_url "${archive_url}"
write_output dsh_source_mode true

printf 'dsh_source_version=%s\n' "${source_version}"
printf 'dsh_source_ref=%s\n' "${source_ref}"
printf 'dsh_source_commit=%s\n' "${source_commit}"
printf 'dsh_source_archive_sha256=%s\n' "${source_archive_sha256}"
