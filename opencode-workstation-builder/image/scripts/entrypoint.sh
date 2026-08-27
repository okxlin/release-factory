#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${HOME:-}" ]]; then
  runtime_home="$(getent passwd "$(id -u)" | cut -d: -f6 2>/dev/null || true)"
  export HOME="${runtime_home}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_USER="${OPENCODE_USER:-opencode}"
OPENCODE_GROUP="${OPENCODE_GROUP:-$(id -gn "${OPENCODE_USER}" 2>/dev/null || printf '%s' "${OPENCODE_USER}")}"
OPENCODE_HOME_DIR="${OPENCODE_HOME_DIR:-/home/${OPENCODE_USER}}"

: "${OPENCODE_BOOTSTRAP:=1}"
: "${OMO_AUTO_INSTALL:=0}"
: "${ACP_AUTO_START:=0}"
: "${OPENCODE_RUNTIME_MODE:=acp}"
: "${CONTAINER_WORKSPACE:=/workspace}"
: "${CONTAINER_CACHE:=/cache}"
: "${KEEPALIVE_COMMAND:=sleep infinity}"
: "${OPENCODE_INSTALL_DIR:=${OPENCODE_HOME_DIR}/.local/share/opencode}"
: "${OPENCODE_NPM_BIN_DIR:=${OPENCODE_HOME_DIR}/.local/bin}"
: "${OPENCODE_CONFIG_DIR:=${OPENCODE_HOME_DIR}/.config/opencode}"
: "${OMO_INSTALL_DIR:=${OPENCODE_HOME_DIR}/.local/share/oh-my-opencode}"

export OPENCODE_CONFIG_DIR OPENCODE_INSTALL_DIR OPENCODE_NPM_BIN_DIR OMO_INSTALL_DIR
export HOME="${OPENCODE_HOME_DIR}"
export USER="${OPENCODE_USER}"
export PATH="/opt/bun/bin:/usr/local/go/bin:${HOME}/.cargo/bin:${OPENCODE_NPM_BIN_DIR}:${HOME}/.local/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}"

log() {
  printf '[entrypoint] %s\n' "$*"
}

ensure_owned_dir() {
  local dir="$1"
  if ! sudo install -d -o "${OPENCODE_USER}" -g "${OPENCODE_GROUP}" "${dir}"; then
    log "failed to prepare ${dir}"
  fi
}

configure_docker_socket_access() {
  local socket="/var/run/docker.sock"
  local socket_gid group_name

  [[ -S "${socket}" ]] || return 0

  socket_gid="$(stat -c '%g' "${socket}" 2>/dev/null || true)"
  if [[ -z "${socket_gid}" ]]; then
    log "failed to inspect ${socket}"
    return 0
  fi

  if [[ "${socket_gid}" == "0" ]]; then
    log "${socket} is owned by root group; use sudo docker inside the container"
    return 0
  fi

  if id -G "${OPENCODE_USER}" | tr ' ' '\n' | grep -qx "${socket_gid}"; then
    return 0
  fi

  group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
  if [[ -z "${group_name}" ]]; then
    group_name="docker-host"
    if getent group "${group_name}" >/dev/null 2>&1; then
      group_name="docker-host-${socket_gid}"
    fi
    if ! sudo groupadd -g "${socket_gid}" "${group_name}" 2>/dev/null; then
      group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
    fi
  fi

  if [[ -z "${group_name}" ]]; then
    log "failed to create group for ${socket}; use sudo docker inside the container"
    return 0
  fi

  if ! sudo usermod -aG "${group_name}" "${OPENCODE_USER}"; then
    log "failed to add ${OPENCODE_USER} to ${group_name}; use sudo docker inside the container"
    return 0
  fi

  export OPENCODE_GROUP_REFRESH_NEEDED=1
}

prepare_directories() {
  for dir in \
    "${CONTAINER_WORKSPACE}" \
    "${CONTAINER_CACHE}" \
    "$HOME/.config" \
    "$HOME/.config/opencode" \
    "$HOME/.agents" \
    "$HOME/.cache" \
    "$HOME/.cache/npm" \
    "$HOME/.cargo" \
    "$HOME/.cargo/bin" \
    "$HOME/.claude" \
    "$HOME/.opencode" \
    "$HOME/.local" \
    "$HOME/.local/bin" \
    "$HOME/.local/share" \
    "$HOME/.local/share/opencode" \
    "$HOME/.local/share/oh-my-opencode" \
    "$HOME/.npm"; do
    ensure_owned_dir "$dir"
  done
}

repair_recursive_ownership() {
  if [[ "${FIX_WORKSPACE_OWNERSHIP_RECURSIVE:-false}" == "true" ]]; then
    if [[ "${CONTAINER_WORKSPACE}" == "/workspace" ]]; then
      sudo chown -R "${OPENCODE_USER}:${OPENCODE_GROUP}" "${CONTAINER_WORKSPACE}" || true
    else
      log "recursive workspace ownership repair is only allowed for /workspace; skipped ${CONTAINER_WORKSPACE}"
    fi
  fi

  if [[ "${FIX_CACHE_OWNERSHIP_RECURSIVE:-false}" == "true" ]]; then
    if [[ "${CONTAINER_CACHE}" == "/cache" ]]; then
      sudo chown -R "${OPENCODE_USER}:${OPENCODE_GROUP}" "${CONTAINER_CACHE}" || true
    else
      log "recursive cache ownership repair is only allowed for /cache; skipped ${CONTAINER_CACHE}"
    fi
  fi
}

drop_to_runtime_user() {
  if [[ "$(id -u)" == "0" || "${OPENCODE_GROUP_REFRESH_NEEDED:-0}" == "1" ]]; then
    if [[ "${OPENCODE_RUNTIME_USER_READY:-0}" != "1" ]]; then
      export OPENCODE_RUNTIME_USER_READY=1
      exec sudo -E -u "${OPENCODE_USER}" -g "${OPENCODE_GROUP}" \
        env HOME="${OPENCODE_HOME_DIR}" USER="${OPENCODE_USER}" "$0" "$@"
    fi
  fi
}

prepare_directories
configure_docker_socket_access
repair_recursive_ownership
drop_to_runtime_user "$@"

log "migrating deprecated OpenCode configuration"
python3 "${SCRIPT_DIR}/update_opencode_config.py" migrate-deprecated

ensure_omo_storage() {
  local persistent_omo_dir="${HOME}/.config/.omo"
  local legacy_omo_dir="${HOME}/.omo"
  local backup_dir

  mkdir -p "${persistent_omo_dir}"

  if [[ -L "${legacy_omo_dir}" ]]; then
    if [[ "$(readlink -f "${legacy_omo_dir}" 2>/dev/null || true)" == "$(readlink -f "${persistent_omo_dir}")" ]]; then
      return 0
    fi
    log "leaving custom ${legacy_omo_dir} symlink unchanged"
    return 0
  fi

  if [[ -d "${legacy_omo_dir}" ]]; then
    log "migrating legacy OMO data into persistent config storage"
    cp -a -n "${legacy_omo_dir}/." "${persistent_omo_dir}/"
    backup_dir="${HOME}/.omo.migrated.$(date +%s%N)"
    mv "${legacy_omo_dir}" "${backup_dir}"
    log "legacy OMO data preserved at ${backup_dir}"
  elif [[ -e "${legacy_omo_dir}" ]]; then
    log "cannot replace non-directory ${legacy_omo_dir}; leaving it unchanged"
    return 0
  fi

  ln -s "${persistent_omo_dir}" "${legacy_omo_dir}"
}

ensure_omo_storage

sample_user_config="$HOME/.config/opencode/opencode.user.sample.json"
if [[ ! -f "${sample_user_config}" ]]; then
  cat > "${sample_user_config}" <<'EOF'
{
  "plugin": [
    "your-plugin-name"
  ],
  "provider": {
    "mimo": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Mimo",
      "options": {
        "baseURL": "{env:OPENAI_BASE_URL}",
        "apiKey": "{env:OPENAI_API_KEY}"
      },
      "models": {
        "mimo-v2.5": {
          "name": "mimo-v2.5"
        }
      }
    }
  }
}
EOF
fi

for dir in \
  "${CONTAINER_WORKSPACE}" \
  "${CONTAINER_CACHE}" \
  "$HOME/.config" \
  "$HOME/.agents" \
  "$HOME/.claude" \
  "$HOME/.opencode" \
  "$HOME/.local/share"; do
  if [[ -d "$dir" && ! -w "$dir" ]]; then
    log "mount not writable for current user: $dir"
  fi
done

if [[ "${OPENCODE_BOOTSTRAP}" == "1" ]]; then
  log "bootstrapping OpenCode userland"
  "${SCRIPT_DIR}/bootstrap-opencode-userland.sh"
  log "installing OpenCode plugins and config hooks"
  "${SCRIPT_DIR}/install-opencode-plugins.sh"
fi

if [[ "${OMO_AUTO_INSTALL}" == "1" ]]; then
  log "installing or refreshing oh-my-opencode"
  "${SCRIPT_DIR}/install-oh-my-opencode.sh"
fi

log "runtime versions"
if command -v node >/dev/null 2>&1; then node --version; fi
if command -v npm >/dev/null 2>&1; then npm --version; fi
if command -v bun >/dev/null 2>&1; then bun --version; fi
if command -v opencode >/dev/null 2>&1; then opencode --version; fi

if [[ "${ACP_AUTO_START}" == "1" ]]; then
  log "starting OpenCode runtime in background (mode=${OPENCODE_RUNTIME_MODE})"
  "${SCRIPT_DIR}/start-opencode-runtime.sh" &
fi

case "${1:-shell}" in
  shell)
    log "keeping container alive via: ${KEEPALIVE_COMMAND}"
    exec bash -lc "${KEEPALIVE_COMMAND}"
    ;;
  doctor)
    exec "${SCRIPT_DIR}/doctor.sh"
    ;;
  smoke)
    exec "${SCRIPT_DIR}/smoke-test.sh"
    ;;
  runtime)
    exec "${SCRIPT_DIR}/start-opencode-runtime.sh"
    ;;
  *)
    exec "$@"
    ;;
esac
