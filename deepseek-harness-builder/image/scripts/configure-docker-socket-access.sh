#!/usr/bin/env bash
set -Eeuo pipefail

app_user="node"
socket_path="/var/run/docker.sock"

log() {
    printf '[docker-socket] %s\n' "$*"
}

warn() {
    printf '[docker-socket] WARNING: %s\n' "$*" >&2
}

if [[ ! -S "${socket_path}" ]]; then
    exit 0
fi

if (( EUID != 0 )); then
    warn "${socket_path} is mounted, but socket-group setup requires a root entrypoint"
    exit 0
fi

socket_gid="$(stat -c '%g' "${socket_path}" 2>/dev/null || true)"
if [[ ! "${socket_gid}" =~ ^[0-9]+$ ]]; then
    warn "failed to read the numeric group of ${socket_path}"
    exit 0
fi

if [[ "${socket_gid}" == "0" ]]; then
    warn "${socket_path} uses the root group; refusing to add ${app_user} to that broad group"
    exit 0
fi

if id -G "${app_user}" | tr ' ' '\n' | grep -Fxq "${socket_gid}"; then
    exit 0
fi

group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
if [[ -z "${group_name}" ]]; then
    group_name="docker-host"
    if getent group "${group_name}" >/dev/null 2>&1; then
        group_name="docker-host-${socket_gid}"
    fi
    if ! groupadd --gid "${socket_gid}" "${group_name}" 2>/dev/null; then
        group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
    fi
fi

if [[ -z "${group_name}" ]]; then
    warn "could not create or resolve a group for ${socket_path} (GID ${socket_gid})"
    exit 0
fi

if ! usermod --append --groups "${group_name}" "${app_user}"; then
    warn "could not add ${app_user} to ${group_name}; Docker daemon access remains disabled"
    exit 0
fi

if ! id -G "${app_user}" | tr ' ' '\n' | grep -Fxq "${socket_gid}"; then
    warn "${app_user} did not acquire Docker socket group ${socket_gid}"
    exit 0
fi

log "mapped ${socket_path} group ${socket_gid} to ${app_user}"
