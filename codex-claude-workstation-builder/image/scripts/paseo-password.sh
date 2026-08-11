#!/usr/bin/env bash
# Shared Paseo password checks. Paseo's browser client sends the password in
# Sec-WebSocket-Protocol as "paseo.bearer.<password>", so it must be an HTTP
# token rather than an arbitrary password string.

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
