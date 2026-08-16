#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
builder_dir="$(cd -- "${script_dir}/.." && pwd)"
compose_file="${builder_dir}/compose.workstation.yml"
example_env="${builder_dir}/image/.env.example"
data_source="$(realpath -m -- "${builder_dir}/data/data")"
workspace_source="$(realpath -m -- "${builder_dir}/data/workspace")"

fail() {
    printf '[compose-contract] FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf '[compose-contract] PASS: %s\n' "$*"
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
docker compose version >/dev/null 2>&1 || fail "docker compose is required"
[[ -f "${compose_file}" ]] || fail "Compose file is missing"
[[ -f "${example_env}" ]] || fail "example runtime environment file is missing"

render_compose() {
    local socket_source="$1"
    if [[ -n "${socket_source}" ]]; then
        DOCKER_SOCK_SRC="${socket_source}" \
            RUNTIME_ENV_FILE="${example_env}" \
            docker compose -f "${compose_file}" config --format json
    else
        env -u DOCKER_SOCK_SRC \
            RUNTIME_ENV_FILE="${example_env}" \
            docker compose -f "${compose_file}" config --format json
    fi
}

assert_socket_mount() {
    local rendered="$1"
    local expected_source="$2"

    jq -e --arg source "${expected_source}" '
      [.services["deepseek-harness"].volumes[]
        | select(.target == "/var/run/docker.sock")] as $mounts
      | ($mounts | length) == 1
        and $mounts[0].type == "bind"
        and $mounts[0].source == $source
    ' <<<"${rendered}" >/dev/null ||
        fail "Docker socket mount did not resolve to ${expected_source}"
}

default_config="$(render_compose "")"
jq -e '
  .services["deepseek-harness"].image == "ghcr.io/okxlin/deepseek-harness:workstation"
' <<<"${default_config}" >/dev/null ||
    fail "Compose must use the unified deepseek-harness workstation tag by default"
pass "workstation defaults to the unified deepseek-harness image repository"

jq -e --arg source "${data_source}" '
  [.services["deepseek-harness"].volumes[]
    | select(.target == "/data")] as $mounts
  | ($mounts | length) == 1
    and $mounts[0].type == "bind"
    and $mounts[0].target == "/data"
    and $mounts[0].source == $source
' <<<"${default_config}" >/dev/null ||
    fail "Compose must persist authentication, Caddy, JWT, and DSH state through the package-local data bind at /data"
pass "application state uses the package-local /data bind mount"

jq -e '
  [.services["deepseek-harness"].volumes[]
    | select(.type == "volume")] as $mounts
  | ($mounts | length) == 1
    and $mounts[0].source == "dsh-home"
    and $mounts[0].target == "/home/node"
    and (.volumes | length) == 1
    and .volumes["dsh-home"].name == "dsh-home"
' <<<"${default_config}" >/dev/null ||
    fail "Compose must persist the workstation user home through one named volume"
pass "workstation user installations use one persistent HOME volume"

jq -e --arg source "${workspace_source}" '
  [.services["deepseek-harness"].volumes[]
    | select(.target == "/workspace")] as $mounts
  | ($mounts | length) == 1
    and $mounts[0].type == "bind"
    and $mounts[0].source == $source
' <<<"${default_config}" >/dev/null ||
    fail "Compose must bind the package-local data/workspace directory to /workspace"
pass "workspace uses a package-local bind mount for 1Panel backup and file access"

jq -e '
  [.services["deepseek-harness"].volumes[].target]
  | index("/data") != null
' <<<"${default_config}" >/dev/null ||
    fail "Compose must include the shared /data application-state mount"
pass "Compose includes the shared /data application-state mount"

assert_socket_mount "${default_config}" "/dev/null"
pass "Docker daemon access is disabled by default through a /dev/null bind"

enabled_config="$(render_compose "/var/run/docker.sock")"
assert_socket_mount "${enabled_config}" "/var/run/docker.sock"
pass "Docker daemon access requires the explicit host socket source"

jq -e '
  [.services["deepseek-harness"].ports[]
    | select(.target == 8080)] as $ports
  | ($ports | length) == 1
    and $ports[0].host_ip == "127.0.0.1"
' <<<"${default_config}" >/dev/null ||
    fail "Compose must bind the HTTP port to host loopback by default"
pass "HTTP exposure is bound to host loopback by default"
