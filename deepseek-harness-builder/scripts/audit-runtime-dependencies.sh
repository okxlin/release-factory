#!/usr/bin/env bash
set -Eeuo pipefail

image=""

usage() {
    cat <<'EOF'
Usage: audit-runtime-dependencies.sh --image IMAGE

Audit the production dependency tree in a DeepSeek Harness dependency stage.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            (( $# >= 2 )) || {
                printf 'ERROR: --image requires a value\n' >&2
                exit 2
            }
            image="$2"
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

[[ -n "${image}" ]] || {
    printf 'ERROR: --image is required\n' >&2
    usage >&2
    exit 2
}

audit_mode="$(docker run --rm --entrypoint sh "${image}" -c '
    if test -f /opt/dsh/node_modules/.package-lock.json; then
        printf npm
    else
        printf pnpm
    fi
')"

case "${audit_mode}" in
    npm)
        printf '%s\n' 'Auditing the npm-installed production dependency tree'
        docker run --rm --workdir /opt/dsh --entrypoint npm "${image}" \
            audit --omit=dev --audit-level high --package-lock=false
        ;;
    pnpm)
        printf '%s\n' 'Auditing the frozen pnpm production dependency tree'
        docker run --rm --workdir /opt/dsh --entrypoint pnpm "${image}" \
            audit --prod --audit-level high
        ;;
    *)
        printf 'ERROR: dependency audit mode is invalid: %s\n' "${audit_mode}" >&2
        exit 1
        ;;
esac
