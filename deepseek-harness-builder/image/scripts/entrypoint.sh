#!/usr/bin/env bash
set -Eeuo pipefail

APP_USER="node"
APP_GROUP="node"
AUTH_STATE_DIR="${AUTH_STATE_DIR:-/data/auth}"
AUTH_DB_PATH="${AUTH_STATE_DIR}/users.json"
AUTH_JWT_SECRET_PATH="${AUTH_STATE_DIR}/jwt-secret"
CADDY_CONFIG_HOME="${CADDY_CONFIG_HOME:-/data/caddy/config}"
CADDY_DATA_HOME="${CADDY_DATA_HOME:-/data/caddy/data}"
DSH_HOME="${DSH_HOME:-/data/dsh}"
DSH_VERSION_FILE="${DSH_VERSION_FILE:-/etc/deepseek-harness-version}"
DSH_WORKSPACE="${DSH_WORKSPACE:-/workspace}"
LEGACY_WORKSTATION_STATE_DIR="${LEGACY_WORKSTATION_STATE_DIR:-/home/node/.local/share/deepseek-harness}"
CADDY_AUTH_CONFIG="/etc/caddy/Caddyfile"
CADDY_PASSTHROUGH_CONFIG="/etc/caddy/Caddyfile.passthrough"

if [[ -z "${DSH_VERSION:-}" && -r "${DSH_VERSION_FILE}" ]]; then
    while IFS='=' read -r key value; do
        if [[ "${key}" == "DSH_VERSION" ]]; then
            DSH_VERSION="${value}"
            break
        fi
    done < "${DSH_VERSION_FILE}"
fi
export DSH_VERSION

log() {
    printf '[entrypoint] %s\n' "$*"
}

fatal() {
    printf '[entrypoint] ERROR: %s\n' "$*" >&2
    exit 1
}

require_persistent_data_mount() {
    if [[ ! -r /proc/self/mountinfo ]] \
        || ! awk '$5 == "/data" { found = 1 } END { exit found ? 0 : 1 }' /proc/self/mountinfo; then
        printf '[entrypoint] ERROR: persistence path has changed: this image now stores application state under /data, but /data is not mounted. Mounting only the legacy /home/node/.local/share/deepseek-harness path does not persist the new layout; recreate the container with a persistent /data mount.\n' >&2
        printf '[entrypoint] 错误：持久化路径已变更：此镜像现在将应用状态保存到 /data，但当前未挂载 /data。仅映射旧的 /home/node/.local/share/deepseek-harness 无法持久化新版本；请重新创建容器并挂载持久化的 /data。\n' >&2
        printf '[entrypoint] Example / 示例：-v /opt/deepseek-harness/data:/data\n' >&2
        exit 1
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

validate_port() {
    local name="$1"
    local value="$2"
    local numeric
    [[ "${value}" =~ ^[0-9]{1,5}$ ]] || fatal "${name} must be an integer between 1 and 65535"
    numeric=$((10#${value}))
    (( numeric >= 1 && numeric <= 65535 )) || fatal "${name} must be between 1 and 65535"
}

prepare_owned_directory() {
    local path="$1"
    local current=""
    local part
    local -a parts=()

    [[ "${path}" == /* ]] || fatal "persistent directory paths must be absolute: ${path}"
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "${part}" ]] || continue
        current="${current}/${part}"
        if [[ -L "${current}" ]]; then
            fatal "${current} must be a regular directory, not a symbolic link"
        fi
        if [[ -e "${current}" && ! -d "${current}" ]]; then
            fatal "${current} must be a regular directory"
        fi
    done

    install -d -m 0750 -o "${APP_USER}" -g "${APP_GROUP}" "${path}"
}

prepare_directories() {
    local path
    for path in \
        /data \
        /home/node \
        "${DSH_WORKSPACE}" \
        "${AUTH_STATE_DIR}" \
        "${CADDY_CONFIG_HOME}" \
        "${CADDY_DATA_HOME}" \
        "${DSH_HOME}"; do
        prepare_owned_directory "${path}"
    done
}

validate_auth_state_files() {
    if [[ -L "${AUTH_DB_PATH}" || -L "${AUTH_JWT_SECRET_PATH}" ]]; then
        fatal "authentication state files must not be symbolic links"
    fi
    if [[ -e "${AUTH_DB_PATH}" && ! -f "${AUTH_DB_PATH}" ]]; then
        fatal "authentication user database path must be a regular file"
    fi
    if [[ -e "${AUTH_JWT_SECRET_PATH}" && ! -f "${AUTH_JWT_SECRET_PATH}" ]]; then
        fatal "authentication signing key path must be a regular file"
    fi
}

migrate_legacy_workstation_state() {
    local legacy_root="${LEGACY_WORKSTATION_STATE_DIR}"

    [[ "${AUTH_STATE_DIR}" == /data/* ]] || return 0
    [[ -d "${legacy_root}" ]] || return 0
    [[ ! -L "${legacy_root}" ]] \
        || fatal "legacy workstation state path must be a regular directory, not a symbolic link"

    if [[ -e "${AUTH_DB_PATH}" || -e "${AUTH_JWT_SECRET_PATH}" ]]; then
        return 0
    fi

    if ! find "${legacy_root}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        return 0
    fi

    log "migrating legacy workstation application state from ${legacy_root} to /data"
    cp -a -n "${legacy_root}/." /data/
}

parse_public_url() {
    [[ -n "${PUBLIC_URL:-}" ]] || fatal "PUBLIC_URL is required (for example https://dsh.example.com)"

    local parsed
    if ! parsed="$(node -e '
      const value = process.argv[1]
      let url
      try { url = new URL(value) } catch { process.exit(2) }
      if (!["http:", "https:"].includes(url.protocol)) process.exit(3)
      if (url.username || url.password || url.pathname !== "/" || url.search || url.hash) process.exit(4)
      process.stdout.write(url.origin + "\n" + url.host + "\n")
    ' "${PUBLIC_URL}")"; then
        fatal "PUBLIC_URL must be an http(s) origin without credentials, path, query, or fragment"
    fi

    PUBLIC_URL="$(sed -n '1p' <<< "${parsed}")"
    AUTH_PUBLIC_AUTHORITY="$(sed -n '2p' <<< "${parsed}")"
    [[ -n "${AUTH_PUBLIC_AUTHORITY}" ]] || fatal "PUBLIC_URL has no authority"

    if [[ "${PUBLIC_URL}" == http://* && "${AUTH_COOKIE_INSECURE}" != "true" ]]; then
        fatal "PUBLIC_URL uses HTTP; set AUTH_COOKIE_INSECURE=true only for an explicitly trusted local network"
    fi

    export PUBLIC_URL AUTH_PUBLIC_AUTHORITY
}

resolve_password_hash() {
    local password=""
    local hash="${AUTH_PASSWORD_HASH:-}"
    local password_file="${AUTH_PASSWORD_FILE:-}"

    if [[ -n "${hash}" && ( -n "${AUTH_PASSWORD:-}" || -n "${password_file}" ) ]]; then
        fatal "AUTH_PASSWORD_HASH cannot be combined with AUTH_PASSWORD or AUTH_PASSWORD_FILE"
    fi
    if [[ -n "${AUTH_PASSWORD:-}" && -n "${password_file}" ]]; then
        fatal "AUTH_PASSWORD and AUTH_PASSWORD_FILE are mutually exclusive"
    fi

    if [[ -n "${hash}" ]]; then
        # The JavaScript regular expression intentionally contains literal dollar signs.
        # shellcheck disable=SC2016
        if ! node -e '
          const value = process.argv[1]
          const match = /^bcrypt:(\d{2}):(\$2[aby]\$(\d{2})\$[./A-Za-z0-9]{53})$/.exec(value)
          if (!match) process.exit(1)
          const declaredCost = Number(match[1])
          const embeddedCost = Number(match[3])
          if (declaredCost < 12 || declaredCost > 31 || declaredCost !== embeddedCost) process.exit(1)
        ' "${hash}"; then
            fatal "AUTH_PASSWORD_HASH must be an exact bcrypt:<cost>:<hash> value with matching cost 12-31"
        fi
        AUTH_PASSWORD_HASH="${hash}"
        export AUTH_PASSWORD_HASH
        unset AUTH_PASSWORD AUTH_PASSWORD_FILE
        return
    fi

    if [[ -n "${password_file}" ]]; then
        [[ -f "${password_file}" && -r "${password_file}" ]] \
            || fatal "AUTH_PASSWORD_FILE must point to a readable regular file"
        password="$(<"${password_file}")"
    else
        password="${AUTH_PASSWORD:-}"
    fi

    [[ -n "${password}" ]] || fatal "AUTH_PASSWORD, AUTH_PASSWORD_FILE, or AUTH_PASSWORD_HASH is required"
    if [[ "${password}" =~ [[:cntrl:]] ]]; then
        fatal "the authentication password must not contain control characters"
    fi
    (( ${#password} >= 12 )) || fatal "the authentication password must contain at least 12 characters"
    (( ${#password} <= 1024 )) || fatal "the authentication password is too long"

    hash="$(printf '%s\n' "${password}" | caddy hash-password --algorithm bcrypt --bcrypt-cost 12)"
    [[ "${hash}" =~ ^\$2[aby]\$12\$ ]] || fatal "failed to generate a bcrypt password hash"

    AUTH_PASSWORD_HASH="bcrypt:12:${hash}"
    export AUTH_PASSWORD_HASH
    unset AUTH_PASSWORD AUTH_PASSWORD_FILE password hash
}

resolve_jwt_secret() {
    local secret="${AUTH_JWT_SECRET:-}"
    local temp_path

    if [[ -z "${secret}" && -f "${AUTH_JWT_SECRET_PATH}" ]]; then
        secret="$(<"${AUTH_JWT_SECRET_PATH}")"
    fi

    if [[ -z "${secret}" ]]; then
        temp_path="${AUTH_JWT_SECRET_PATH}.tmp.$$"
        umask 077
        node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))' > "${temp_path}"
        chown "${APP_USER}:${APP_GROUP}" "${temp_path}"
        chmod 0600 "${temp_path}"
        mv -f "${temp_path}" "${AUTH_JWT_SECRET_PATH}"
        secret="$(<"${AUTH_JWT_SECRET_PATH}")"
        log "generated a persistent authentication signing key"
    fi

    if [[ ! "${secret}" =~ ^[A-Za-z0-9_-]{32,256}$ ]]; then
        fatal "AUTH_JWT_SECRET must contain 32-256 base64url-safe characters"
    fi

    if [[ -f "${AUTH_JWT_SECRET_PATH}" ]]; then
        chown "${APP_USER}:${APP_GROUP}" "${AUTH_JWT_SECRET_PATH}"
        chmod 0600 "${AUTH_JWT_SECRET_PATH}"
    fi

    AUTH_JWT_SECRET="${secret}"
    export AUTH_JWT_SECRET
    unset secret
}

append_trusted_hosts() {
    local raw_hosts="${DSH_TRUSTED_HOSTS:-}"
    local item
    local normalized
    local trusted_port
    local -A seen=()
    local web_help

    DSH_ARGS=(web --host 127.0.0.1 --port "${DSH_INTERNAL_PORT}")
    web_help="$(gosu "${APP_USER}" dsh web --help 2>&1)"
    if [[ "${web_help}" == *'--no-open'* ]]; then
        DSH_ARGS+=(--no-open)
    fi
    raw_hosts="${AUTH_PUBLIC_AUTHORITY},${raw_hosts}"
    IFS=',' read -r -a host_items <<< "${raw_hosts}"

    for item in "${host_items[@]}"; do
        normalized="$(trim "${item}")"
        [[ -n "${normalized}" ]] || continue
        if [[ ! "${normalized}" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:([0-9]{1,5}))?$ ]]; then
            fatal "invalid DSH trusted host authority: ${normalized}"
        fi
        trusted_port="${BASH_REMATCH[3]:-}"
        if [[ -n "${trusted_port}" ]] && (( 10#${trusted_port} > 65535 || 10#${trusted_port} < 1 )); then
            fatal "invalid DSH trusted host port: ${normalized}"
        fi
        if [[ -z "${seen[${normalized}]:-}" ]]; then
            DSH_ARGS+=(--trusted-host "${normalized}")
            seen["${normalized}"]=1
        fi
    done
}

configure_trusted_proxies() {
    local raw="${CADDY_TRUSTED_PROXIES:-private_ranges}"
    local token
    local -a proxy_tokens=()

    raw="$(trim "${raw}")"
    [[ -n "${raw}" ]] || raw="private_ranges"
    if [[ "${raw}" == "none" ]]; then
        # Keep the static Caddy stanza valid without trusting any possible peer.
        CADDY_TRUSTED_PROXIES="0.0.0.0/32"
        export CADDY_TRUSTED_PROXIES
        log "trusted proxy parsing disabled; authentication limits use the direct peer address"
        return
    fi
    if [[ "${raw}" =~ [[:cntrl:]] ]]; then
        fatal "CADDY_TRUSTED_PROXIES must be a space-separated list of CIDRs or private_ranges"
    fi

    read -r -a proxy_tokens <<< "${raw}"
    (( ${#proxy_tokens[@]} <= 256 )) \
        || fatal "CADDY_TRUSTED_PROXIES accepts at most 256 entries"
    for token in "${proxy_tokens[@]}"; do
        [[ "${token}" != "none" ]] \
            || fatal "CADDY_TRUSTED_PROXIES=none cannot be combined with other entries"
        [[ ! "${token}" =~ /0+$ ]] \
            || fatal "CADDY_TRUSTED_PROXIES must not include unrestricted /0 ranges"
    done
    if ! node - "${proxy_tokens[@]}" <<'NODE'
const net = require('node:net');
const tokens = process.argv.slice(2);

for (const token of tokens) {
  if (token === 'private_ranges') continue;
  const separator = token.lastIndexOf('/');
  if (separator <= 0) process.exit(1);
  const address = token.slice(0, separator);
  const prefix = token.slice(separator + 1);
  const family = net.isIP(address);
  const maximum = family === 4 ? 32 : family === 6 ? 128 : -1;
  if (!/^\d{1,3}$/.test(prefix) || Number(prefix) > maximum) process.exit(1);
}
NODE
    then
        fatal "CADDY_TRUSTED_PROXIES must be a space-separated list of CIDRs or private_ranges"
    fi

    CADDY_TRUSTED_PROXIES="${proxy_tokens[*]}"
    export CADDY_TRUSTED_PROXIES
    log "configured ${#proxy_tokens[@]} trusted proxy range entries for authentication limits"
}

wait_for_dsh() {
    local _
    local status
    for _ in {1..60}; do
        if ! kill -0 "${DSH_PID}" 2>/dev/null; then
            wait "${DSH_PID}" || true
            fatal "DeepSeek Harness exited before becoming ready"
        fi
        if status="$(curl --silent --show-error --max-time 2 \
            --output /dev/null --write-out '%{http_code}' \
            "http://127.0.0.1:${DSH_INTERNAL_PORT}/" 2>/dev/null)" \
            && [[ "${status}" =~ ^[1-4][0-9]{2}$ ]]; then
            return 0
        fi
        sleep 1
    done
    fatal "DeepSeek Harness did not become ready within 60 seconds"
}

resolve_dsh_launch_token() {
    local _
    local line
    local token=""

    for _ in {1..60}; do
        while IFS= read -r line; do
            if [[ "${line}" =~ ^dsh\ web:\ http://127\.0\.0\.1:${DSH_INTERNAL_PORT}/\?token=([A-Za-z0-9_-]{20,256})$ ]]; then
                token="${BASH_REMATCH[1]}"
                DSH_UPSTREAM_HOST="${AUTH_PUBLIC_AUTHORITY}"
                export DSH_UPSTREAM_HOST
            elif [[ "${line}" == "dsh web: http://127.0.0.1:${DSH_INTERNAL_PORT}" ]]; then
                # Published releases before the browser launch-token flow
                # print the plain local URL. Their outer Caddy authentication
                # is sufficient, so keep the legacy path working without
                # inventing a token.
                DSH_LAUNCH_TOKEN=""
                DSH_UPSTREAM_HOST="127.0.0.1:${DSH_INTERNAL_PORT}"
                export DSH_LAUNCH_TOKEN
                export DSH_UPSTREAM_HOST
                return 0
            fi
        done < "${DSH_LAUNCH_LOG}"
        if [[ -n "${token}" ]]; then
            DSH_LAUNCH_TOKEN="${token}"
            export DSH_LAUNCH_TOKEN
            return 0
        fi
        if ! kill -0 "${DSH_PID}" 2>/dev/null; then
            wait "${DSH_PID}" || true
            fatal "DeepSeek Harness exited without publishing its browser launch token"
        fi
        sleep 1
    done
    fatal "DeepSeek Harness did not publish its browser launch token within 60 seconds"
}

shutdown_children() {
    local pid
    for pid in "${CADDY_PID:-}" "${DSH_PID:-}"; do
        if [[ -n "${pid}" ]]; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    rm -f "${DSH_LAUNCH_LOG:-}" 2>/dev/null || true
}

PORT="${PORT:-8080}"
DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3080}"
AUTH_MODE="${AUTH_MODE:-caddy-security}"
AUTH_USERNAME="${AUTH_USERNAME:-admin}"
AUTH_TOKEN_LIFETIME="${AUTH_TOKEN_LIFETIME:-3600}"
AUTH_COOKIE_INSECURE="${AUTH_COOKIE_INSECURE:-false}"
DSH_UPSTREAM_HOST="127.0.0.1:${DSH_INTERNAL_PORT}"

validate_port PORT "${PORT}"
validate_port DSH_INTERNAL_PORT "${DSH_INTERNAL_PORT}"
PORT=$((10#${PORT}))
DSH_INTERNAL_PORT=$((10#${DSH_INTERNAL_PORT}))
(( PORT != DSH_INTERNAL_PORT )) \
    || fatal "PORT and DSH_INTERNAL_PORT must be different"
[[ "${AUTH_TOKEN_LIFETIME}" =~ ^[0-9]{1,7}$ ]] || fatal "AUTH_TOKEN_LIFETIME must be an integer"
AUTH_TOKEN_LIFETIME=$((10#${AUTH_TOKEN_LIFETIME}))
(( AUTH_TOKEN_LIFETIME >= 300 && AUTH_TOKEN_LIFETIME <= 2592000 )) \
    || fatal "AUTH_TOKEN_LIFETIME must be between 300 and 2592000 seconds"
[[ "${AUTH_COOKIE_INSECURE}" == "true" || "${AUTH_COOKIE_INSECURE}" == "false" ]] \
    || fatal "AUTH_COOKIE_INSECURE must be true or false"
[[ "${AUTH_USERNAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] \
    || fatal "AUTH_USERNAME contains unsupported characters"

require_persistent_data_mount
prepare_directories
validate_auth_state_files
migrate_legacy_workstation_state
validate_auth_state_files
if [[ -x /usr/local/bin/configure-docker-socket-access.sh ]]; then
    /usr/local/bin/configure-docker-socket-access.sh
fi
parse_public_url
append_trusted_hosts

case "${AUTH_MODE}" in
    caddy-security)
        configure_trusted_proxies
        resolve_password_hash
        resolve_jwt_secret
        CADDY_CONFIG="${CADDY_AUTH_CONFIG}"
        ;;
    none)
        CADDY_CONFIG="${CADDY_PASSTHROUGH_CONFIG}"
        log "WARNING: AUTH_MODE=none exposes DeepSeek Harness without authentication"
        ;;
    dsh)
        fatal "AUTH_MODE=dsh is reserved for a future DeepSeek Harness native-auth release; this image fails closed"
        ;;
    *)
        fatal "AUTH_MODE must be caddy-security, dsh, or none"
        ;;
esac

export PORT DSH_INTERNAL_PORT AUTH_MODE AUTH_USERNAME AUTH_TOKEN_LIFETIME AUTH_COOKIE_INSECURE
export AUTH_DB_PATH DSH_UPSTREAM_HOST

trap shutdown_children TERM INT

umask 077
DSH_LAUNCH_LOG="${TMPDIR:-/tmp}/deepseek-harness-dsh-${BASHPID}.log"
: > "${DSH_LAUNCH_LOG}"

log "starting DeepSeek Harness ${DSH_VERSION:-unknown} on 127.0.0.1:${DSH_INTERNAL_PORT}"
(
    cd "${DSH_WORKSPACE}"
    exec env -u AUTH_JWT_SECRET -u AUTH_PASSWORD_HASH \
        gosu "${APP_USER}" dsh "${DSH_ARGS[@]}" \
        > >(tee "${DSH_LAUNCH_LOG}") 2>&1
) &
DSH_PID=$!

wait_for_dsh
resolve_dsh_launch_token

gosu "${APP_USER}" env \
    XDG_CONFIG_HOME="${CADDY_CONFIG_HOME}" \
    XDG_DATA_HOME="${CADDY_DATA_HOME}" \
    caddy validate --config "${CADDY_CONFIG}" --adapter caddyfile

log "starting Caddy on 0.0.0.0:${PORT} with AUTH_MODE=${AUTH_MODE}"
gosu "${APP_USER}" env \
    XDG_CONFIG_HOME="${CADDY_CONFIG_HOME}" \
    XDG_DATA_HOME="${CADDY_DATA_HOME}" \
    caddy run --config "${CADDY_CONFIG}" --adapter caddyfile &
CADDY_PID=$!

set +e
wait -n "${DSH_PID}" "${CADDY_PID}"
status=$?
set -e

shutdown_children
wait "${DSH_PID}" 2>/dev/null || true
wait "${CADDY_PID}" 2>/dev/null || true
exit "${status}"
