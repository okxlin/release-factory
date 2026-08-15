#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${WORKSTATION_SMOKE_IMAGE:-deepseek-harness-workstation:ci-test}"
SKIP_SANDBOX_PROBE=false

usage() {
    cat <<'EOF'
Usage: workstation-smoke-test.sh [options]

Options:
  --image IMAGE          Workstation image to test
  --skip-sandbox-probe   Skip the host-kernel sandbox probe (for QEMU user-mode CI)
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -ge 2 ]] || { printf 'ERROR: --image requires a value\n' >&2; exit 2; }
            IMAGE="$2"
            shift 2
            ;;
        --skip-sandbox-probe)
            SKIP_SANDBOX_PROBE=true
            shift
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

command -v docker >/dev/null 2>&1 || {
    printf 'ERROR: docker is required\n' >&2
    exit 1
}
docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
    printf 'ERROR: image does not exist locally: %s\n' "${IMAGE}" >&2
    exit 1
}

declared_volumes="$(
    docker image inspect \
        --format '{{range $path, $value := .Config.Volumes}}{{println $path}}{{end}}' \
        "${IMAGE}" | sed '/^$/d' | LC_ALL=C sort
)"
if [[ "${declared_volumes}" != "/home/node" ]]; then
    printf 'ERROR: workstation image must declare only /home/node, got: %s\n' "${declared_volumes}" >&2
    exit 1
fi
printf '[workstation-smoke] PASS: workstation image declares one persistent HOME volume\n'

docker run --rm --entrypoint bash -i "${IMAGE}" -s <<'SOCKET_TEST'
set -Eeuo pipefail

socket_gid=42420
while getent group "${socket_gid}" >/dev/null 2>&1; do
    socket_gid=$((socket_gid + 1))
done

node -e '
  const net = require("node:net");
  const server = net.createServer(() => {});
  server.listen("/var/run/docker.sock");
' &
socket_server_pid=$!
trap 'kill "${socket_server_pid}" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 20); do
    [[ -S /var/run/docker.sock ]] && break
    sleep 0.1
done
[[ -S /var/run/docker.sock ]]
chown "root:${socket_gid}" /var/run/docker.sock
chmod 0660 /var/run/docker.sock

/usr/local/bin/configure-docker-socket-access.sh
gosu node sh -c "id -G | tr ' ' '\n' | grep -Fxq '${socket_gid}'"
gosu node test -w /var/run/docker.sock
SOCKET_TEST
printf '[workstation-smoke] PASS: optional Docker socket group is mapped to node\n'

if [[ "${SKIP_SANDBOX_PROBE}" == "true" ]]; then
    printf '[workstation-smoke] SKIP: DSH sandbox enforcement probe requires the host kernel and is unavailable under QEMU user-mode emulation\n'
else
docker run --rm --security-opt no-new-privileges:true --user node \
    --workdir /workspace --entrypoint node -i "${IMAGE}" --input-type=module - <<'SANDBOX_TEST'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { basename, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { mkdir, readFile, rm } from 'node:fs/promises'

const require = createRequire('/opt/dsh/node_modules/.pnpm/anchor.js')
const load = async name => import(pathToFileURL(require.resolve(name)).href)
const [cordis, sandboxLocal, sandboxPolicy, subprocessLocal, bashSandbox] = await Promise.all([
  load('@deepseek-ai/cordis'),
  load('@deepseek-ai/dsh-sandbox-local'),
  load('@deepseek-ai/dsh-sandbox-policy'),
  load('@deepseek-ai/dsh-subprocess-local'),
  load('@deepseek-ai/dsh-bash-sandbox'),
])

const workspace = '/workspace/dsh-sandbox-probe'
const outside = '/home/node/dsh-sandbox-outside'
await rm(workspace, { recursive: true, force: true })
await rm(outside, { recursive: true, force: true })
await mkdir(workspace, { recursive: true })
await mkdir(outside, { recursive: true })

const ctx = new cordis.Context()
try {
  await ctx.plugin(sandboxLocal.LocalSandboxProvider, {})
  await ctx.plugin(sandboxPolicy.SandboxPolicyService, {
    mode: 'workspace-write',
    workspaceRoot: workspace,
  })
  await ctx.plugin(subprocessLocal.LocalSubprocessRuntime)
  await ctx.plugin(bashSandbox.SandboxBashExecutor, {
    cwd: workspace,
    timeoutMs: 30_000,
  })

  const wrap = ctx.sandbox.confine(['true'], {
    mode: 'workspace-write',
    workspaceRoot: workspace,
  })
  assert.equal(basename(wrap.argv[0]), 'landlock-run')

  const bash = ctx.shell
  const insidePath = join(workspace, 'allowed.txt')
  const deniedPath = join(outside, 'blocked.txt')
  const fullPath = join(outside, 'full-access.txt')

  const inside = await bash.run(bash.resolve({
    command: `printf workspace-ok > ${insidePath}`,
  }))
  assert.equal(inside.exitCode, 0)
  assert.deepEqual(inside.sandbox, {
    mode: 'workspace-write',
    denied: false,
    enforcement: wrap.enforcement,
  })
  assert.equal(await readFile(insidePath, 'utf8'), 'workspace-ok')

  const denied = await bash.run(bash.resolve({
    command: `printf should-not-exist > ${deniedPath}`,
  }))
  assert.notEqual(denied.exitCode, 0)
  assert.equal(denied.sandbox?.mode, 'workspace-write')
  assert.equal(denied.sandbox?.denied, true)
  await assert.rejects(readFile(deniedPath, 'utf8'), error => error?.code === 'ENOENT')

  const full = await bash.run(bash.resolve({
    command: `printf full-access-ok > ${fullPath}`,
    sandboxPolicy: {
      mode: 'danger-full-access',
      workspaceRoot: workspace,
    },
  }))
  assert.equal(full.exitCode, 0)
  assert.deepEqual(full.sandbox, {
    mode: 'danger-full-access',
    denied: false,
  })
  assert.equal(await readFile(fullPath, 'utf8'), 'full-access-ok')

  const status = await readFile('/proc/self/status', 'utf8')
  assert.equal(status.match(/^NoNewPrivs:\s+(\d+)$/m)?.[1], '1')
  process.stdout.write(
    `[workstation-smoke] sandbox backend=${basename(wrap.argv[0])} enforcement=${wrap.enforcement}\n`,
  )
} finally {
  await ctx.fiber.dispose()
  await rm(workspace, { recursive: true, force: true })
  await rm(outside, { recursive: true, force: true })
}
SANDBOX_TEST
printf '[workstation-smoke] PASS: DSH switches between confined workspace writes and explicit full access under no-new-privileges\n'
fi

docker run --rm --user node --entrypoint bash -i "${IMAGE}" -s <<'CONTAINER'
set -Eeuo pipefail

pass() {
    printf '[workstation-smoke] PASS: %s\n' "$*"
}

fail() {
    printf '[workstation-smoke] FAIL: %s\n' "$*" >&2
    exit 1
}

tmp_dir="$(mktemp -d /tmp/deepseek-harness-workstation.XXXXXX)"
trap 'rm -rf "${tmp_dir}"' EXIT

[[ "${DSH_IMAGE_VARIANT:-}" == "workstation" ]] \
    || fail "image variant metadata is not workstation"
for persistent_dir in \
    /home/node \
    /home/node/.local/share/deepseek-harness/auth \
    /home/node/.local/share/deepseek-harness/caddy/config \
    /home/node/.local/share/deepseek-harness/caddy/data \
    /home/node/.local/share/deepseek-harness/dsh \
    /workspace; do
    [[ -d "${persistent_dir}" && ! -L "${persistent_dir}" ]] \
        || fail "workstation directory is missing or symbolic: ${persistent_dir}"
done
[[ "${AUTH_STATE_DIR}" == "/home/node/.local/share/deepseek-harness/auth" ]] \
    || fail "authentication state is not stored under the persistent home"
[[ "${DSH_HOME}" == "/home/node/.local/share/deepseek-harness/dsh" ]] \
    || fail "DeepSeek Harness state is not stored under the persistent home"
pass "home, application state, and workspace use direct directories without symbolic links"
[[ "$(node --version)" == "v24.18.0" ]] || fail "Node.js version drifted"
[[ "$(pnpm --version)" == "11.21.0" ]] || fail "pnpm version drifted"
[[ "$(go version)" == go\ version\ go1.26.6* ]] || fail "Go version drifted"
[[ "$(rustc --version)" == rustc\ 1.97.1* ]] || fail "Rust version drifted"
python3 --version | grep -Eq '^Python 3\.' || fail "Python 3 is unavailable"
pass "pinned language runtimes are executable"

docker --version | grep -Fq 'Docker version 29.7.2,' || fail "Docker CLI version drifted"
docker compose version | grep -Fq 'Docker Compose version v5.4.0' \
    || fail "Docker Compose version drifted"
docker buildx version | grep -Fq 'github.com/docker/buildx v0.36.1 ' \
    || fail "Docker Buildx version drifted"
[[ ! -S /var/run/docker.sock ]] || fail "Docker socket is unexpectedly present by default"
for docker_binary in \
    /usr/local/bin/docker \
    /usr/local/libexec/docker/cli-plugins/docker-buildx \
    /usr/local/libexec/docker/cli-plugins/docker-compose; do
    binary_metadata="$(go version -m "${docker_binary}")"
    grep -Fq 'go1.26.6' <<< "${binary_metadata}" \
        || fail "Docker tool was not built with the pinned fixed Go release: ${docker_binary}"
    if grep -Eq '^[[:space:]]*dep[[:space:]]+github.com/docker/docker[[:space:]]' \
        <<< "${binary_metadata}"; then
        fail "Docker tool retains the unrelated legacy daemon module: ${docker_binary}"
    fi
done
pass "Docker CLI, Compose, and Buildx use the hardened client-only dependency graph without default daemon access"

bash -lc 'command -v go >/dev/null && command -v rustc >/dev/null && command -v pnpm >/dev/null' \
    || fail "login shells lose workstation tool paths"
pass "login shells retain workstation tool paths"

cat > "${tmp_dir}/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("c-ok"); return 0; }
EOF
gcc -Wall -Wextra -Werror "${tmp_dir}/hello.c" -o "${tmp_dir}/hello-c"
[[ "$("${tmp_dir}/hello-c")" == "c-ok" ]] || fail "C compiler output is invalid"

cat > "${tmp_dir}/hello.cpp" <<'EOF'
#include <iostream>
int main() { std::cout << "cpp-ok\n"; }
EOF
g++ -std=c++17 -Wall -Wextra -Werror "${tmp_dir}/hello.cpp" -o "${tmp_dir}/hello-cpp"
[[ "$("${tmp_dir}/hello-cpp")" == "cpp-ok" ]] || fail "C++ compiler output is invalid"
pass "C and C++ compilation works"

cat > "${tmp_dir}/hello.go" <<'EOF'
package main
import "fmt"
func main() { fmt.Println("go-ok") }
EOF
[[ "$(go run "${tmp_dir}/hello.go")" == "go-ok" ]] || fail "Go compilation output is invalid"

cat > "${tmp_dir}/hello.rs" <<'EOF'
fn main() { println!("rust-ok"); }
EOF
rustc "${tmp_dir}/hello.rs" -o "${tmp_dir}/hello-rust"
[[ "$("${tmp_dir}/hello-rust")" == "rust-ok" ]] || fail "Rust compilation output is invalid"
pass "Go and Rust compilation works"

python3 -m venv "${tmp_dir}/venv"
[[ "$("${tmp_dir}/venv/bin/python" -c 'print("python-ok")')" == "python-ok" ]] \
    || fail "Python virtual environment is unusable"
"${tmp_dir}/venv/bin/pip" --version >/dev/null
pass "Python venv and pip work"

for command_name in \
    bat clang cmake direnv fd fzf gdb gh git-lfs htop lsof ninja \
    patch pipx pkg-config pre-commit rsync shellcheck shfmt sqlite3 \
    strace tmux tree vim wget yamllint zip zstd; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "development CLI is missing: ${command_name}"
done
pass "workstation development CLI set is present"

for command_name in npm corepack; do
    if command -v "${command_name}" >/dev/null 2>&1; then
        fail "${command_name} should not coexist with the standalone pinned pnpm bundle"
    fi
done
if command -v sudo >/dev/null 2>&1; then
    fail "workstation unexpectedly grants a sudo path"
fi
pass "workstation omits npm, Corepack, and sudo"

touch "${HOME}/.workstation-write-probe"
rm -f "${HOME}/.workstation-write-probe"
touch /workspace/.workstation-write-probe
rm -f /workspace/.workstation-write-probe
pass "node user can write its persistent home and workspace"
CONTAINER

printf '[workstation-smoke] ALL TESTS PASSED\n'
