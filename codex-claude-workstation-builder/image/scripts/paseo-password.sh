#!/usr/bin/env bash
# Shared Paseo password checks. Paseo's browser client sends the password in
# Sec-WebSocket-Protocol as "paseo.bearer.<password>", so it must be an HTTP
# token rather than an arbitrary password string.

configure_workstation_passwords() {
    local password="${PASSWORD:-}"
    if [[ -z "${password//[[:space:]]/}" || "${password}" = change-me ]]; then
        echo 'ERROR: set a unique non-empty PASSWORD before starting the workstation.' >&2
        return 1
    fi

    # Preserve existing deployments that use one password for both services.
    PASEO_PASSWORD="${PASEO_PASSWORD:-${password}}"
    if [[ -z "${PASEO_PASSWORD//[[:space:]]/}" ]]; then
        PASEO_PASSWORD="${password}"
    fi
    if [[ "${PASEO_PASSWORD}" = change-me ]]; then
        echo 'ERROR: replace the example PASEO_PASSWORD before starting the workstation.' >&2
        return 1
    fi
    export PASEO_PASSWORD
}

paseo_password_is_websocket_token() {
    local value="${1-}"
    local token_pattern="^[A-Za-z0-9!#\$%&'*+.^_\`|~-]+$"

    [ "${#value}" -ge 1 ] \
        && [ "${#value}" -le 128 ] \
        && [[ "${value}" =~ ${token_pattern} ]]
}

paseo_password_has_recommended_length() {
    local value="${1-}"

    [ "${#value}" -ge 20 ]
}
