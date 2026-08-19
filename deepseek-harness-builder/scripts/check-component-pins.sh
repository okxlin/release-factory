#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dockerfile="${script_dir}/../image/Dockerfile"
failures=0

usage() {
    cat <<'EOF'
Usage: check-component-pins.sh [options]

Validate the checked-in DeepSeek Harness Dockerfile component-pin contract.

Options:
  --dockerfile FILE  Dockerfile to validate
  -h, --help         Show this help
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
        --dockerfile)
            require_value "$1" "$#"
            dockerfile="$2"
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

[[ -f "${dockerfile}" ]] || {
    printf 'ERROR: Dockerfile does not exist: %s\n' "${dockerfile}" >&2
    exit 2
}

dockerfile_dir="$(cd -- "$(dirname -- "${dockerfile}")" && pwd)"
dockerfile="${dockerfile_dir}/$(basename -- "${dockerfile}")"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    ((failures += 1))
}

logical_lines() {
    awk '
        {
            line = line (line == "" ? "" : " ") $0
            if ($0 ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                next
            }
            print line
            line = ""
        }
        END {
            if (line != "") {
                print line
            }
        }
    ' "${dockerfile}"
}

mapfile -t docker_lines < <(logical_lines)

instruction_remainder() {
    local line="$1"
    local expected_instruction="$2"
    local trimmed_line
    local instruction

    trimmed_line="${line#"${line%%[![:space:]]*}"}"
    instruction="${trimmed_line%%[[:space:]]*}"
    [[ -n "${instruction}" && "${instruction^^}" == "${expected_instruction}" ]] || return 1
    printf '%s\n' "${trimmed_line:${#instruction}}"
}

normalize_official_image_name() {
    local image_name="$1"
    local official_image

    for official_image in caddy python node golang rust; do
        case "${image_name}" in
            "${official_image}" \
            | "library/${official_image}" \
            | "docker.io/${official_image}" \
            | "docker.io/library/${official_image}" \
            | "index.docker.io/library/${official_image}" \
            | "registry-1.docker.io/library/${official_image}")
                printf '%s\n' "${official_image}"
                return
                ;;
        esac
    done

    printf '%s\n' "${image_name}"
}

declare -A arg_values=()
declare -A arg_counts=()
for line in "${docker_lines[@]}"; do
    if arg_remainder="$(instruction_remainder "${line}" ARG)" \
        && [[ "${arg_remainder}" =~ ^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]#]*)[[:space:]]*(#.*)?$ ]]; then
        arg_name="${BASH_REMATCH[1]}"
        arg_value="${BASH_REMATCH[2]}"
        if [[ -v "arg_values[${arg_name}]" && "${arg_values[${arg_name}]}" != "${arg_value}" ]]; then
            fail "ARG ${arg_name} has inconsistent defaults: ${arg_values[${arg_name}]} and ${arg_value}"
        fi
        arg_values["${arg_name}"]="${arg_value}"
        arg_counts["${arg_name}"]=$(( ${arg_counts[${arg_name}]:-0} + 1 ))
    fi
done

require_arg() {
    local name="$1"
    local minimum_count="$2"
    if [[ ! -v "arg_values[${name}]" ]]; then
        fail "required ARG ${name} is missing"
        return
    fi
    if (( ${arg_counts[${name}]:-0} < minimum_count )); then
        fail "ARG ${name} must be declared at least ${minimum_count} times"
    fi
}

for name_and_count in \
    'CADDY_VERSION:2' \
    'CADDY_SECURITY_VERSION:2' \
    'DSH_VERSION:2' \
    'PYTHON_VERSION:4' \
    'PYTEST_VERSION:3' \
    'PNPM_VERSION:5' \
    'DOCKER_BUILDX_VERSION:2' \
    'DOCKER_COMPOSE_VERSION:2' \
    'DOCKER_VERSION:2' \
    'GO_VERSION:1' \
    'RUST_VERSION:1' \
    'MOBY_GO_ARCHIVE_VERSION:1'; do
    require_arg "${name_and_count%%:*}" "${name_and_count##*:}"
done

checksum_arg='CADDY_SOURCE_ARCHIVE_SHA256'
checksum_value="${arg_values[${checksum_arg}]:-}"
[[ "${checksum_value}" =~ ^[a-f0-9]{64}$ ]] \
    || fail "ARG ${checksum_arg} must be a lowercase SHA-256 digest"

[[ "${arg_values[CADDY_RATELIMIT_REF]:-}" =~ ^[a-f0-9]{40}$ ]] \
    || fail 'ARG CADDY_RATELIMIT_REF must be an immutable 40-character Git commit'

declare -A stage_names=()
declare -A image_counts=()
declare -A repeated_image_refs=()
node_tag=""

for line_number in "${!docker_lines[@]}"; do
    line="${docker_lines[${line_number}]}"
    from_remainder="$(instruction_remainder "${line}" FROM)" || continue
    if [[ ! "${from_remainder}" =~ ^[[:space:]]+(.+)$ ]]; then
        fail "Dockerfile logical line $((line_number + 1)): FROM must name an image or prior stage"
        continue
    fi

    read -r -a from_parts <<< "${BASH_REMATCH[1]}"
    from_index=0
    while (( from_index < ${#from_parts[@]} )) && [[ "${from_parts[${from_index}]}" == --* ]]; do
        from_flag="${from_parts[${from_index}]}"
        case "${from_flag}" in
            --platform=*)
                [[ -n "${from_flag#--platform=}" ]] \
                    || fail "Dockerfile logical line $((line_number + 1)): FROM --platform requires a value"
                ;;
            *)
                fail "Dockerfile logical line $((line_number + 1)): unsupported FROM flag: ${from_flag}"
                ;;
        esac
        ((from_index += 1))
    done

    if (( from_index >= ${#from_parts[@]} )); then
        fail "Dockerfile logical line $((line_number + 1)): FROM must name an image or prior stage"
        continue
    fi

    image_ref="${from_parts[${from_index}]}"
    remaining_parts=$(( ${#from_parts[@]} - from_index - 1 ))
    stage_name=""
    if (( remaining_parts == 2 )); then
        if [[ "${from_parts[from_index + 1],,}" == 'as' \
            && "${from_parts[from_index + 2]}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            stage_name="${from_parts[from_index + 2]}"
        else
            fail "Dockerfile logical line $((line_number + 1)): invalid FROM stage alias"
            continue
        fi
    elif (( remaining_parts != 0 )); then
        fail "Dockerfile logical line $((line_number + 1)): invalid FROM instruction"
        continue
    fi
    source_line=$((line_number + 1))

    if [[ -v "stage_names[${image_ref}]" ]]; then
        :
    else
        if [[ ! "${image_ref}" =~ ^[^@[:space:]]+:[^@[:space:]]+@sha256:[a-f0-9]{64}$ ]]; then
            fail "Dockerfile logical line ${source_line}: external FROM must use tag@sha256:<64-lowercase-hex>: ${image_ref}"
        else
            tag_and_repo="${image_ref%@sha256:*}"
            image_name="$(normalize_official_image_name "${tag_and_repo%:*}")"
            image_tag="${tag_and_repo##*:}"
            image_digest="${image_ref##*@sha256:}"
            canonical_image_ref="${image_name}:${image_tag}@sha256:${image_digest}"
            case "${image_tag}" in
                latest|main|master|edge|stable)
                    fail "Dockerfile logical line ${source_line}: floating base-image tag is forbidden: ${image_ref}"
                    ;;
            esac

            image_counts["${image_name}"]=$(( ${image_counts[${image_name}]:-0} + 1 ))
            if [[ -v "repeated_image_refs[${image_name}]" \
                && "${repeated_image_refs[${image_name}]}" != "${canonical_image_ref}" ]]; then
                fail "Dockerfile logical line ${source_line}: repeated ${image_name} base images must use the same tag and digest"
            fi
            repeated_image_refs["${image_name}"]="${canonical_image_ref}"

            case "${image_name}" in
                caddy)
                    [[ "${image_tag}" == "${arg_values[CADDY_VERSION]:-}-builder-alpine" ]] \
                        || fail "Caddy base-image tag ${image_tag} does not match ARG CADDY_VERSION"
                    ;;
                python)
                    [[ "${image_tag}" == "${arg_values[PYTHON_VERSION]:-}-slim-trixie" ]] \
                        || fail "Python base-image tag ${image_tag} does not match ARG PYTHON_VERSION"
                    ;;
                golang)
                    [[ "${image_tag}" == "${arg_values[GO_VERSION]:-}-trixie" ]] \
                        || fail "Go base-image tag ${image_tag} does not match ARG GO_VERSION"
                    ;;
                rust)
                    [[ "${image_tag}" == "${arg_values[RUST_VERSION]:-}-slim-trixie" ]] \
                        || fail "Rust base-image tag ${image_tag} does not match ARG RUST_VERSION"
                    ;;
                node)
                    if [[ -z "${node_tag}" ]]; then
                        node_tag="${image_tag}"
                    elif [[ "${node_tag}" != "${image_tag}" ]]; then
                        fail "Node base-image tag ${image_tag} does not match the other Node stages (${node_tag})"
                    fi
                    ;;
            esac
        fi
    fi

    if [[ -n "${stage_name}" ]]; then
        stage_names["${stage_name}"]=1
    fi
done

for required_image in caddy python node golang rust; do
    (( ${image_counts[${required_image}]:-0} > 0 )) \
        || fail "Dockerfile must retain a pinned ${required_image} base image"
done

[[ "${node_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-trixie-slim$ ]] \
    || fail "Node base-image tag must be an exact Trixie patch release, got: ${node_tag:-missing}"

declare -A expected_remote_adds=()
expected_remote_adds["https://registry.npmjs.org/pnpm/-/pnpm-${arg_values[PNPM_VERSION]:-}.tgz"]=1
expected_remote_adds["https://codeload.github.com/docker/cli/tar.gz/refs/tags/v${arg_values[DOCKER_VERSION]:-}"]=1
expected_remote_adds["https://codeload.github.com/docker/compose/tar.gz/refs/tags/v${arg_values[DOCKER_COMPOSE_VERSION]:-}"]=1
expected_remote_adds["https://codeload.github.com/docker/buildx/tar.gz/refs/tags/v${arg_values[DOCKER_BUILDX_VERSION]:-}"]=1
declare -A seen_remote_adds=()

for line_number in "${!docker_lines[@]}"; do
    line="${docker_lines[${line_number}]}"
    add_remainder="$(instruction_remainder "${line}" ADD)" || continue
    source_line=$((line_number + 1))
    if [[ ! "${add_remainder}" =~ ^[[:space:]]+ ]]; then
        fail "Dockerfile logical line ${source_line}: ADD must include source and destination arguments"
        continue
    fi
    if [[ "${line}" == *'--checksum='* \
        && ! "${line}" =~ --checksum=sha256:([a-f0-9]{64})([[:space:]]|$) ]]; then
        fail "Dockerfile logical line ${source_line}: ADD checksum must be lowercase sha256:<64-hex>"
    fi
    if [[ "${line}" =~ (https?://[^[:space:]]+) ]]; then
        remote_url="${BASH_REMATCH[1]}"
        if [[ ! "${line}" =~ --checksum=sha256:([a-f0-9]{64})([[:space:]]|$) ]]; then
            fail "Dockerfile logical line ${source_line}: remote ADD must use a lowercase SHA-256 checksum: ${remote_url}"
        fi
        if [[ ! -v "expected_remote_adds[${remote_url}]" ]]; then
            fail "Dockerfile logical line ${source_line}: unrecognized remote ADD URL: ${remote_url}"
        fi
        seen_remote_adds["${remote_url}"]=1
    fi
done

for remote_url in "${!expected_remote_adds[@]}"; do
    [[ -v "seen_remote_adds[${remote_url}]" ]] \
        || fail "Dockerfile must checksum-pin remote ADD URL: ${remote_url}"
done

require_literal() {
    local literal="$1"
    local description="$2"
    grep -Fq -- "${literal}" "${dockerfile}" \
        || fail "Dockerfile must retain ${description}"
}

require_literal \
    "https://github.com/caddyserver/caddy/archive/refs/tags/v\${CADDY_VERSION}.tar.gz" \
    'the Caddy source URL tied to CADDY_VERSION'
require_literal \
    "https://github.com/greenpau/go-authcrunch/archive/refs/tags/v\${GO_AUTHCRUNCH_VERSION}.tar.gz" \
    'the go-authcrunch source URL tied to GO_AUTHCRUNCH_VERSION'
require_literal \
    "\"\${CADDY_SOURCE_ARCHIVE_SHA256}\"" \
    'the Caddy source checksum verification'
require_literal \
    "xcaddy build \"v\${CADDY_VERSION}\"" \
    'the Caddy build version assertion'
require_literal \
    "github.com/greenpau/caddy-security@v\${CADDY_SECURITY_VERSION}" \
    'the caddy-security version pin'
require_literal \
    "github.com/moby/go-archive@v\${MOBY_GO_ARCHIVE_VERSION}" \
    'the Buildx go-archive version pin'

if grep -nE -- '(:latest|refs/heads/(main|master)|@(main|master))' "${dockerfile}" >/dev/null; then
    fail 'Dockerfile contains a forbidden floating source reference'
fi

if (( failures > 0 )); then
    printf '[component-pins] FAIL: %d contract violation(s)\n' "${failures}" >&2
    exit 1
fi

printf '[component-pins] PASS: Dockerfile component pins, checksums, and repeated version contracts are consistent\n'
