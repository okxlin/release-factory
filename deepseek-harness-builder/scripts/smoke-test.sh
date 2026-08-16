#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${SMOKE_IMAGE:-deepseek-harness:ci-test}"
PROFILE="${SMOKE_PROFILE:-full}"
PUBLIC_URL="${SMOKE_PUBLIC_URL:-https://dsh.example.test}"
VARIANT="${SMOKE_VARIANT:-runtime}"
MAX_IDLE_MEMORY_MIB="${SMOKE_MAX_IDLE_MEMORY_MIB:-256}"
MAX_IDLE_PIDS="${SMOKE_MAX_IDLE_PIDS:-64}"
TOKEN_LIFETIME="${SMOKE_TOKEN_LIFETIME:-2592000}"
EXPECTED_DSH_VERSION="${SMOKE_EXPECTED_DSH_VERSION:-}"

usage() {
    cat <<'EOF'
Usage: smoke-test.sh [options]

Options:
  --image IMAGE          Image to test (default: deepseek-harness:ci-test)
  --profile PROFILE      full or minimal (default: full)
  --public-url URL       HTTPS origin simulated through proxy headers
  --variant VARIANT      runtime or workstation (default: runtime)
  -h, --help             Show this help

Environment overrides:
  SMOKE_MAX_IDLE_MEMORY_MIB  Full-profile idle memory ceiling (default: 256)
  SMOKE_MAX_IDLE_PIDS        Full-profile idle PID ceiling (default: 64)
  SMOKE_TOKEN_LIFETIME       Login lifetime exercised by the smoke test (default: 2592000)
  SMOKE_EXPECTED_DSH_VERSION Expected DSH version; defaults to image DSH_VERSION
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -ge 2 ]] || { printf 'ERROR: --image requires a value\n' >&2; exit 2; }
            IMAGE="$2"
            shift 2
            ;;
        --profile)
            [[ $# -ge 2 ]] || { printf 'ERROR: --profile requires a value\n' >&2; exit 2; }
            PROFILE="$2"
            shift 2
            ;;
        --public-url)
            [[ $# -ge 2 ]] || { printf 'ERROR: --public-url requires a value\n' >&2; exit 2; }
            PUBLIC_URL="$2"
            shift 2
            ;;
        --variant)
            [[ $# -ge 2 ]] || { printf 'ERROR: --variant requires a value\n' >&2; exit 2; }
            VARIANT="$2"
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

case "${PROFILE}" in
    full|minimal) ;;
    *)
        printf 'ERROR: profile must be full or minimal, got: %s\n' "${PROFILE}" >&2
        exit 2
        ;;
esac
case "${VARIANT}" in
    runtime|workstation) ;;
    *)
        printf 'ERROR: variant must be runtime or workstation, got: %s\n' "${VARIANT}" >&2
        exit 2
        ;;
esac

if [[ ! "${PUBLIC_URL}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
    printf 'ERROR: smoke public URL must be an HTTPS origin without a path: %s\n' "${PUBLIC_URL}" >&2
    exit 2
fi
if [[ ! "${MAX_IDLE_MEMORY_MIB}" =~ ^[0-9]+$ ]] || (( MAX_IDLE_MEMORY_MIB < 128 )); then
    printf 'ERROR: SMOKE_MAX_IDLE_MEMORY_MIB must be an integer of at least 128\n' >&2
    exit 2
fi
if [[ ! "${MAX_IDLE_PIDS}" =~ ^[0-9]+$ ]] || (( MAX_IDLE_PIDS < 1 )); then
    printf 'ERROR: SMOKE_MAX_IDLE_PIDS must be a positive integer\n' >&2
    exit 2
fi
if [[ ! "${TOKEN_LIFETIME}" =~ ^[0-9]{1,7}$ ]] \
    || (( 10#${TOKEN_LIFETIME} < 300 || 10#${TOKEN_LIFETIME} > 2592000 )); then
    printf 'ERROR: SMOKE_TOKEN_LIFETIME must be an integer between 300 and 2592000\n' >&2
    exit 2
fi
TOKEN_LIFETIME=$((10#${TOKEN_LIFETIME}))

for command_name in docker timeout; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        printf 'ERROR: required command is missing: %s\n' "${command_name}" >&2
        exit 1
    }
done

docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
    printf 'ERROR: image does not exist locally: %s\n' "${IMAGE}" >&2
    exit 1
}

run_id="${SMOKE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
run_id="$(printf '%s' "${run_id}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
run_id="${run_id:0:28}"
[[ -n "${run_id}" ]] || {
    printf 'ERROR: smoke run ID is empty after normalization\n' >&2
    exit 1
}

container_name="deepseek-harness-smoke-${run_id}"
data_volume="deepseek-harness-smoke-data-${run_id}"
home_volume="deepseek-harness-smoke-home-${run_id}"
workspace_volume="deepseek-harness-smoke-workspace-${run_id}"
secret_volume="deepseek-harness-smoke-secret-${run_id}"
layout_attack_volume="deepseek-harness-smoke-layout-${run_id}"
test_username="smoke-admin"
test_password="smoke-password-12345"
failure_counter=0

pass() {
    printf '[smoke] PASS: %s\n' "$*"
}

fail() {
    printf '[smoke] FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT

    if (( status != 0 )) && docker container inspect "${container_name}" >/dev/null 2>&1; then
        printf '[smoke] container logs after failure:\n' >&2
        docker logs "${container_name}" >&2 || true
    fi

    docker rm -f "${container_name}" >/dev/null 2>&1 || true
    docker volume rm \
        "${data_volume}" \
        "${home_volume}" \
        "${layout_attack_volume}" \
        "${workspace_volume}" \
        "${secret_volume}" >/dev/null 2>&1 || true
    exit "${status}"
}
trap cleanup EXIT

wait_for_health() {
    local healthy=false
    local _

    for _ in $(seq 1 75); do
        if docker exec "${container_name}" healthcheck.sh >/dev/null 2>&1; then
            healthy=true
            break
        fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "${container_name}" 2>/dev/null || true)" != "true" ]]; then
            break
        fi
        sleep 1
    done

    [[ "${healthy}" == "true" ]] || fail "container did not become healthy"
}

expect_start_failure() {
    local label="$1"
    local expected_message="$2"
    shift 2

    failure_counter=$((failure_counter + 1))
    local failure_name="${container_name}-failure-${failure_counter}"
    local output
    local status

    set +e
    output="$(timeout 25s docker run --rm --name "${failure_name}" "$@" "${IMAGE}" 2>&1)"
    status=$?
    set -e
    docker rm -f "${failure_name}" >/dev/null 2>&1 || true

    if (( status == 0 )); then
        fail "${label}: container unexpectedly exited successfully"
    fi
    if (( status == 124 )); then
        fail "${label}: container unexpectedly kept running"
    fi
    if ! grep -Fq "${expected_message}" <<< "${output}"; then
        printf '%s\n' "${output}" >&2
        fail "${label}: expected error was not reported"
    fi
    pass "${label}"
}

run_http_contract() {
    docker exec \
        -e SMOKE_PROFILE="${PROFILE}" \
        -e TEST_PASSWORD="${test_password}" \
        -e TEST_PUBLIC_URL="${PUBLIC_URL}" \
        -e TEST_TOKEN_LIFETIME="${TOKEN_LIFETIME}" \
        -e TEST_USERNAME="${test_username}" \
        -i "${container_name}" node - <<'NODE'
const crypto = require('node:crypto');
const http = require('node:http');

const profile = process.env.SMOKE_PROFILE;
const password = process.env.TEST_PASSWORD;
const publicUrl = process.env.TEST_PUBLIC_URL;
const tokenLifetime = Number(process.env.TEST_TOKEN_LIFETIME);
const username = process.env.TEST_USERNAME;
const publicOrigin = new URL(publicUrl);
const proxyHeaders = {
  Host: publicOrigin.host,
  'X-Forwarded-Host': publicOrigin.host,
  'X-Forwarded-Proto': publicOrigin.protocol.slice(0, -1),
};

class CookieJar {
  constructor() {
    this.cookies = new Map();
    this.setCookieLines = [];
  }

  store(lines = []) {
    for (const line of lines) {
      this.setCookieLines.push(line);
      const first = line.split(';', 1)[0];
      const separator = first.indexOf('=');
      if (separator < 1) continue;
      const name = first.slice(0, separator);
      const value = first.slice(separator + 1);
      if (/Max-Age=0|Expires=Thu, 01 Jan 1970/i.test(line)) {
        this.cookies.delete(name);
      } else {
        this.cookies.set(name, value);
      }
    }
  }

  header() {
    return [...this.cookies]
      .map(([name, value]) => `${name}=${value}`)
      .join('; ');
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
  process.stdout.write(`[smoke] PASS: ${message}\n`);
}

function request(path, options = {}, jar = new CookieJar()) {
  return new Promise((resolve, reject) => {
    const headers = {...proxyHeaders, ...(options.headers || {})};
    const cookie = jar.header();
    if (cookie) headers.Cookie = cookie;

    const req = http.request({
      host: '127.0.0.1',
      port: 8080,
      path,
      method: options.method || 'GET',
      headers,
      timeout: 10000,
    }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        jar.store(res.headers['set-cookie']);
        resolve({
          status: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks).toString('utf8'),
          jar,
        });
      });
    });

    req.on('timeout', () => req.destroy(new Error('HTTP request timed out')));
    req.on('error', reject);
    req.end(options.body);
  });
}

function publicPath(location) {
  const parsed = new URL(location, publicOrigin);
  if (parsed.origin !== publicOrigin.origin) {
    throw new Error(`redirect left the configured public origin: ${parsed.origin}`);
  }
  return parsed.pathname + parsed.search;
}

async function followToPage(response, jar) {
  for (let redirect = 0; redirect < 8; redirect += 1) {
    if (response.status < 300 || response.status >= 400) return response;
    if (!response.headers.location) throw new Error('redirect response omitted Location');
    response = await request(publicPath(response.headers.location), {}, jar);
  }
  throw new Error('redirect limit exceeded');
}

async function passwordForm(jar) {
  let response = await request('/', {}, jar);
  assert(response.status === 302, 'unauthenticated root redirects to authentication');

  const authRedirect = new URL(response.headers.location, publicOrigin);
  assert(authRedirect.pathname === '/auth/', 'authentication redirect uses the portal path');
  assert(authRedirect.searchParams.get('redirect_url') === `${publicOrigin.origin}/`,
    'forwarded HTTPS host determines the login return URL');

  response = await followToPage(response, jar);
  assert(response.status === 200, 'username login page loads');
  assert(response.body.includes('autocomplete="username"'),
    'username field supports browser password managers');

  const usernameBody = new URLSearchParams({username, realm: 'local'}).toString();
  response = await request(`/auth/login?redirect_url=${encodeURIComponent(`${publicOrigin.origin}/`)}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(usernameBody),
    },
    body: usernameBody,
  }, jar);
  assert(response.status === 303, 'username phase advances to the password sandbox');

  response = await request(publicPath(response.headers.location), {}, jar);
  assert(response.status === 200, 'password page loads');
  assert(response.body.includes('autocomplete="current-password"'),
    'password field supports browser password managers');

  const action = (response.body.match(/<form[^>]+action="([^"]+)"/) || [])[1];
  const sandboxId = (response.body.match(/name="sandbox_id"[^>]+value="([^"]+)"/) || [])[1];
  assert(Boolean(action && sandboxId), 'password form exposes the expected sandbox contract');
  return {action, jar, sandboxId};
}

async function submitPassword(form, secret) {
  const passwordBody = new URLSearchParams({
    secret,
    sandbox_id: form.sandboxId,
    submit: 'Sign In',
  }).toString();
  return request(form.action, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(passwordBody),
    },
    body: passwordBody,
  }, form.jar);
}

async function login() {
  const jar = new CookieJar();
  const form = await passwordForm(jar);
  let response = await submitPassword(form, password);
  assert(response.status === 303, 'correct password is accepted');
  response = await followToPage(response, jar);
  assert(response.status === 200, 'authenticated DeepSeek Harness loads');

  assert((response.headers['strict-transport-security'] || '').includes('max-age='),
    'forwarded HTTPS responses carry HSTS');
  assert((response.headers['content-security-policy'] || '').includes("frame-ancestors 'none'"),
    'responses carry the configured CSP');
  assert((response.headers['x-frame-options'] || '').toUpperCase() === 'DENY',
    'responses deny framing');
  assert((response.headers['x-content-type-options'] || '').toLowerCase() === 'nosniff',
    'responses disable MIME sniffing');
  assert(!response.headers.server, 'Caddy does not disclose a Server header');

  const accessCookie = jar.setCookieLines.find(line => line.startsWith('DSH_ACCESS_TOKEN='));
  const refreshCookie = jar.setCookieLines.find(line => line.startsWith('DSH_REFRESH_TOKEN='));
  assert(Boolean(accessCookie), 'login sets the access cookie');
  assert(Boolean(refreshCookie), 'login sets the refresh cookie');
  assert(/;\s*Secure/i.test(accessCookie), 'access cookie is Secure');
  assert(/;\s*HttpOnly/i.test(accessCookie), 'access cookie is HttpOnly');
  assert(/;\s*SameSite=Strict/i.test(accessCookie), 'access cookie is SameSite=Strict');
  assert(new RegExp(`;\\s*Max-Age=${tokenLifetime}(?:;|$)`, 'i').test(accessCookie),
    'access cookie uses the configured login lifetime');
  assert(new RegExp(`;\\s*Max-Age=${tokenLifetime}(?:;|$)`, 'i').test(refreshCookie),
    'refresh cookie uses the configured login lifetime');

  const accessToken = jar.cookies.get('DSH_ACCESS_TOKEN');
  const payload = JSON.parse(Buffer.from(accessToken.split('.')[1], 'base64url').toString('utf8'));
  assert(payload.exp - payload.iat === tokenLifetime,
    'signed access token uses the configured login lifetime');
  return jar;
}

async function settingsDescribe(jar) {
  const body = JSON.stringify({
    type: 'client-request',
    rpcId: 'smoke-settings-describe',
    method: 'settings.describe',
    payload: {},
  });
  return request('/api/settings.describe', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      Origin: publicOrigin.origin,
    },
    body,
  }, jar);
}

function websocket(path, jar) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port: 8080,
      path,
      method: 'GET',
      headers: {
        ...proxyHeaders,
        Cookie: jar.header(),
        Origin: publicOrigin.origin,
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64'),
      },
      timeout: 10000,
    });

    req.on('upgrade', (response, socket) => {
      const status = response.statusCode;
      socket.destroy();
      resolve(status);
    });
    req.on('response', response => {
      response.resume();
      resolve(response.statusCode);
    });
    req.on('timeout', () => req.destroy(new Error('WebSocket request timed out')));
    req.on('error', reject);
    req.end();
  });
}

(async () => {
  const health = await request('/healthz');
  assert(health.status === 200 && health.body === 'ok', 'public health endpoint responds');

  if (profile === 'full') {
    const spoof = await request('/', {
      headers: {
        Authorization: 'Bearer forged-token',
        'Remote-User': username,
        'X-Auth-User': username,
        'X-Forwarded-User': username,
        'X-Remote-User': username,
      },
    });
    assert(spoof.status === 302,
      'forged bearer and identity headers cannot bypass authentication');

    const wrongJar = new CookieJar();
    const wrongForm = await passwordForm(wrongJar);
    const wrong = await submitPassword(wrongForm, 'definitely-wrong-password');
    assert(wrong.status === 401, 'wrong password is rejected');
  }

  const jar = await login();

  if (profile === 'full') {
    const settings = await settingsDescribe(jar);
    assert(settings.status === 200,
      'authenticated settings API reaches DeepSeek Harness through Caddy');
    assert(JSON.parse(settings.body).result?.ok === true,
      'authenticated settings API returns the provider catalog payload');

    assert(await websocket('/api/events.mux', jar) === 101,
      'multiplex WebSocket upgrades through the proxy contract');
    assert(await websocket('/api/events.host', jar) === 101,
      'host WebSocket upgrades through the proxy contract');

    const logout = await request('/auth/logout', {}, jar);
    assert(logout.status === 302, 'logout clears the authenticated session');
    assert(new URL(logout.headers.location, publicOrigin).origin === publicOrigin.origin,
      'logout redirect remains on the HTTPS public origin');
    const afterLogout = await request('/', {}, jar);
    assert(afterLogout.status === 302, 'logged-out session cannot access DeepSeek Harness');
  }
})().catch(error => {
  process.stderr.write(`[smoke] FAIL: ${error.message}\n`);
  process.exit(1);
});
NODE
}

run_process_contract() {
    docker exec --user node -i "${container_name}" node - <<'NODE'
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');

function assert(condition, message) {
  if (!condition) throw new Error(message);
  process.stdout.write(`[smoke] PASS: ${message}\n`);
}

function processRecords() {
  return fs.readdirSync('/proc')
    .filter(name => /^\d+$/.test(name))
    .flatMap(pid => {
      try {
        const command = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8')
          .split('\0')
          .filter(Boolean);
        return [{pid, command}];
      } catch {
        return [];
      }
    });
}

function connect(port, host) {
  return new Promise(resolve => {
    const socket = net.connect({port, host});
    const finish = result => {
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(3000, () => finish(false));
    socket.once('connect', () => finish(true));
    socket.once('error', () => finish(false));
  });
}

(async () => {
  const records = processRecords();
  const dsh = records.find(record => {
    const args = record.command;
    return args.includes('web') && args.includes('--host') && args.includes('127.0.0.1')
      && args.includes('--port') && args.includes('3080');
  });
  assert(Boolean(dsh), 'DeepSeek Harness process uses the loopback bind arguments');

  const environment = fs.readFileSync(`/proc/${dsh.pid}/environ`, 'utf8').split('\0');
  const secretNames = ['AUTH_JWT_SECRET', 'AUTH_PASSWORD', 'AUTH_PASSWORD_FILE', 'AUTH_PASSWORD_HASH'];
  const inheritedSecrets = secretNames.filter(name => environment.some(item => item.startsWith(`${name}=`)));
  assert(inheritedSecrets.length === 0, 'DeepSeek Harness does not inherit authentication secrets');

  const addresses = Object.values(os.networkInterfaces())
    .flat()
    .filter(Boolean)
    .filter(address => address.family === 'IPv4' && !address.internal)
    .map(address => address.address);
  assert(addresses.length > 0, 'container has a non-loopback IPv4 address');
  assert(!(await connect(3080, addresses[0])), 'DeepSeek Harness is unreachable on the container interface');
  assert(await connect(8080, addresses[0]), 'Caddy listens on the container interface');
})().catch(error => {
  process.stderr.write(`[smoke] FAIL: ${error.message}\n`);
  process.exit(1);
});
NODE
}

check_auth_file_permissions() {
    docker exec -i "${container_name}" node - "${auth_state_dir}" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const authStateDir = process.argv[2];

for (const name of ['users.json', 'jwt-secret']) {
  const statePath = path.join(authStateDir, name);
  const stat = fs.lstatSync(statePath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${statePath} must be a regular non-symlink file`);
  }
  if ((stat.mode & 0o777) !== 0o600 || stat.uid !== 1000 || stat.gid !== 1000) {
    throw new Error(`${statePath} must be mode 0600 and owned by node:node`);
  }
  process.stdout.write(`[smoke] PASS: ${statePath} is a protected node-owned file\n`);
}
NODE
}

check_runtime_versions() {
    local image_arch
    local runtime_arch
    local expected_runtime_arch
    local command_name

    image_arch="$(docker image inspect --format '{{.Architecture}}' "${IMAGE}")"
    case "${image_arch}" in
        amd64) expected_runtime_arch="x64" ;;
        arm64) expected_runtime_arch="arm64" ;;
        *) fail "unexpected image architecture: ${image_arch}" ;;
    esac
    runtime_arch="$(docker exec "${container_name}" node -p 'process.arch')"
    [[ "${runtime_arch}" == "${expected_runtime_arch}" ]] \
        || fail "runtime architecture ${runtime_arch} does not match image architecture ${image_arch}"
    pass "image architecture ${image_arch} runs as Node.js ${runtime_arch}"

    if [[ -z "${EXPECTED_DSH_VERSION}" ]]; then
        EXPECTED_DSH_VERSION="$(docker exec "${container_name}" sh -c '
          if [ -n "${DSH_VERSION:-}" ]; then
            printf %s "${DSH_VERSION}"
          elif [ -r "${DSH_VERSION_FILE:-/etc/deepseek-harness-version}" ]; then
            sed -n "s/^DSH_VERSION=//p" "${DSH_VERSION_FILE:-/etc/deepseek-harness-version}" | head -n 1
          fi
        ')"
    fi
    [[ -n "${EXPECTED_DSH_VERSION}" ]] || fail "DeepSeek Harness expected version is empty"
    [[ "$(docker exec "${container_name}" dsh --version)" == "${EXPECTED_DSH_VERSION}" ]] \
        || fail "DeepSeek Harness version is not ${EXPECTED_DSH_VERSION}"
    pass "DeepSeek Harness version matches ${EXPECTED_DSH_VERSION}"

    [[ "$(docker exec "${container_name}" node --version)" == "v24.18.0" ]] \
        || fail "Node.js version is not pinned to v24.18.0"
    pass "Node.js version is pinned"

    [[ "$(docker exec "${container_name}" pnpm --version)" == "11.21.0" ]] \
        || fail "pnpm version is not pinned to 11.21.0"
    pass "standalone pnpm version is pinned"

    if docker exec "${container_name}" sh -c 'command -v corepack >/dev/null 2>&1'; then
        fail "Corepack is present even though pnpm is installed independently"
    fi
    if docker exec "${container_name}" sh -c 'command -v npm >/dev/null 2>&1'; then
        fail "npm is present even though pnpm is the sole bundled Node.js package manager"
    fi
    pass "npm and Corepack are absent"

    for command_name in bash git curl ssh jq rg less ps file unzip; do
        docker exec "${container_name}" sh -c "command -v '${command_name}' >/dev/null 2>&1" \
            || fail "development basic is missing: ${command_name}"
    done
    pass "development basics are present"

    [[ "$(docker exec "${container_name}" sh -c 'printf %s "$DSH_IMAGE_VARIANT"')" == "${VARIANT}" ]] \
        || fail "image variant metadata does not match ${VARIANT}"

    if [[ "${VARIANT}" == "runtime" ]]; then
        for command_name in gcc g++ make python3 go rustc cargo; do
            if docker exec "${container_name}" sh -c "command -v '${command_name}' >/dev/null 2>&1"; then
                fail "workstation tool unexpectedly present in runtime image: ${command_name}"
            fi
        done
        pass "lightweight runtime omits npm and compiler toolchains"
    else
        [[ "$(docker exec "${container_name}" go version)" == go\ version\ go1.26.6* ]] \
            || fail "Go version is not pinned to 1.26.6"
        [[ "$(docker exec "${container_name}" rustc --version)" == rustc\ 1.97.1* ]] \
            || fail "Rust version is not pinned to 1.97.1"
        [[ "$(docker exec "${container_name}" docker --version)" == Docker\ version\ 29.7.2,* ]] \
            || fail "Docker CLI is not pinned to 29.7.2"
        docker exec "${container_name}" docker compose version | grep -Fq 'Docker Compose version v5.4.0' \
            || fail "Docker Compose is not pinned to 5.4.0"
        docker exec "${container_name}" docker buildx version | grep -Fq 'github.com/docker/buildx v0.36.1 ' \
            || fail "Docker Buildx is not pinned to 0.36.1"
        if docker exec "${container_name}" test -S /var/run/docker.sock; then
            fail "Docker daemon socket is unexpectedly mounted by default"
        fi
        for command_name in python3 gcc g++ make cargo cmake clang docker gh shellcheck shfmt fd bat fzf tmux sqlite3; do
            docker exec "${container_name}" sh -c "command -v '${command_name}' >/dev/null 2>&1" \
                || fail "workstation tool is missing: ${command_name}"
        done
        pass "workstation language toolchains and development CLI are present"
    fi

    docker exec "${container_name}" caddy version | grep -Fq 'v2.11.4' \
        || fail "Caddy version is not pinned to v2.11.4"
    local caddy_modules
    caddy_modules="$(docker exec "${container_name}" caddy list-modules)"
    for module in security http.handlers.authenticator http.authentication.providers.authorizer; do
        grep -Fxq "${module}" <<< "${caddy_modules}" \
            || fail "Caddy module is missing: ${module}"
    done
    pass "Caddy and caddy-security modules are present"
}

check_idle_resources() {
    local stats
    local memory_field
    local memory_used
    local memory_number
    local memory_unit
    local memory_mib
    local pids

    stats="$(docker stats --no-stream --format '{{.MemUsage}}|{{.PIDs}}' "${container_name}")"
    memory_field="${stats%%|*}"
    pids="${stats##*|}"
    memory_used="${memory_field%% / *}"
    memory_number="$(sed -E 's/^([0-9.]+).*/\1/' <<< "${memory_used}")"
    memory_unit="$(sed -E 's/^[0-9.]+//' <<< "${memory_used}")"

    case "${memory_unit}" in
        B) memory_mib="$(awk -v value="${memory_number}" 'BEGIN {printf "%.2f", value / 1048576}')" ;;
        KiB) memory_mib="$(awk -v value="${memory_number}" 'BEGIN {printf "%.2f", value / 1024}')" ;;
        MiB) memory_mib="${memory_number}" ;;
        GiB) memory_mib="$(awk -v value="${memory_number}" 'BEGIN {printf "%.2f", value * 1024}')" ;;
        *) fail "could not parse Docker memory usage: ${memory_used}" ;;
    esac

    awk -v actual="${memory_mib}" -v maximum="${MAX_IDLE_MEMORY_MIB}" \
        'BEGIN {exit !(actual <= maximum)}' \
        || fail "idle memory ${memory_mib} MiB exceeds ${MAX_IDLE_MEMORY_MIB} MiB"
    (( pids <= MAX_IDLE_PIDS )) \
        || fail "idle PID count ${pids} exceeds ${MAX_IDLE_PIDS}"
    pass "idle resources stay within ${MAX_IDLE_MEMORY_MIB} MiB and ${MAX_IDLE_PIDS} PIDs (${memory_mib} MiB, ${pids} PIDs)"
}

printf '[smoke] image=%s profile=%s variant=%s public_url=%s\n' \
    "${IMAGE}" "${PROFILE}" "${VARIANT}" "${PUBLIC_URL}"

mount_args=(
    -v "${secret_volume}:/run/secrets:ro"
)
if [[ "${VARIANT}" == "runtime" ]]; then
    auth_state_dir="/data/auth"
    docker volume create "${data_volume}" >/dev/null
    mount_args+=( -v "${data_volume}:/data" )
else
    auth_state_dir="/home/node/.local/share/deepseek-harness/auth"
    docker volume create "${home_volume}" >/dev/null
    mount_args+=( -v "${home_volume}:/home/node" )
fi
docker volume create "${workspace_volume}" >/dev/null
mount_args+=( -v "${workspace_volume}:/workspace" )
docker volume create "${secret_volume}" >/dev/null
printf '%s\n' "${test_password}" \
    | docker run --rm -i \
        --entrypoint sh \
        -v "${secret_volume}:/run/secrets" \
        "${IMAGE}" \
        -c 'umask 077; cat > /run/secrets/dsh_password'
start_test_container() {
    docker run -d \
        --name "${container_name}" \
        -e PUBLIC_URL="${PUBLIC_URL}" \
        -e AUTH_USERNAME="${test_username}" \
        -e AUTH_PASSWORD_FILE=/run/secrets/dsh_password \
        -e AUTH_TOKEN_LIFETIME="${TOKEN_LIFETIME}" \
        "${mount_args[@]}" \
        "${IMAGE}" >/dev/null
}

start_test_container

wait_for_health
pass "container became healthy"
check_runtime_versions
run_process_contract
run_http_contract
check_auth_file_permissions

if [[ "${PROFILE}" == "full" ]]; then
    jwt_before="$(docker exec "${container_name}" sha256sum "${auth_state_dir}/jwt-secret" | awk '{print $1}')"
    if [[ "${VARIANT}" == "workstation" ]]; then
        docker exec -u node "${container_name}" sh -c \
            'printf "%s\n" "#!/bin/sh" "printf user-install-persisted" > "$HOME/.local/bin/dsh-user-install-probe" && chmod 0750 "$HOME/.local/bin/dsh-user-install-probe"'
    fi
    docker exec -u node "${container_name}" sh -c \
        'printf workspace-persisted > /workspace/.dsh-workspace-persistence-probe'
    docker rm -f "${container_name}" >/dev/null
    start_test_container
    wait_for_health
    jwt_after="$(docker exec "${container_name}" sha256sum "${auth_state_dir}/jwt-secret" | awk '{print $1}')"
    [[ "${jwt_before}" == "${jwt_after}" ]] || fail "JWT signing key changed across container recreation"
    pass "JWT signing key persists across container recreation"
    if [[ "${VARIANT}" == "workstation" ]]; then
        [[ "$(docker exec -u node "${container_name}" sh -c 'dsh-user-install-probe')" == "user-install-persisted" ]] \
            || fail "user-installed HOME executable did not persist across container recreation"
        pass "user-installed HOME executables persist across container recreation"
    fi
    [[ "$(docker exec -u node "${container_name}" cat /workspace/.dsh-workspace-persistence-probe)" == "workspace-persisted" ]] \
        || fail "workspace data did not persist across container recreation"
    pass "workspace data persists across container recreation"
    check_auth_file_permissions
    check_idle_resources

    expect_start_failure \
        "future native-auth mode fails closed" \
        "AUTH_MODE=dsh is reserved" \
        -e PUBLIC_URL="${PUBLIC_URL}" \
        -e AUTH_MODE=dsh
    expect_start_failure \
        "missing password fails closed" \
        "AUTH_PASSWORD, AUTH_PASSWORD_FILE, or AUTH_PASSWORD_HASH is required" \
        -e PUBLIC_URL="${PUBLIC_URL}"
    expect_start_failure \
        "invalid public URL fails closed" \
        "PUBLIC_URL must be an http(s) origin" \
        -e PUBLIC_URL="https://dsh.example.test/subpath" \
        -e AUTH_PASSWORD="${test_password}"
    expect_start_failure \
        "invalid password hash fails closed" \
        "AUTH_PASSWORD_HASH must be an exact bcrypt" \
        -e PUBLIC_URL="${PUBLIC_URL}" \
        -e 'AUTH_PASSWORD_HASH=bcrypt:12:not-a-valid-bcrypt-hash'
    expect_start_failure \
        "HTTP origin requires explicit insecure-cookie opt-in" \
        "PUBLIC_URL uses HTTP" \
        -e PUBLIC_URL=http://dsh.example.test \
        -e AUTH_PASSWORD="${test_password}"
    expect_start_failure \
        "login lifetime above 30 days fails closed" \
        "AUTH_TOKEN_LIFETIME must be between 300 and 2592000 seconds" \
        -e PUBLIC_URL="${PUBLIC_URL}" \
        -e AUTH_PASSWORD="${test_password}" \
        -e AUTH_TOKEN_LIFETIME=2592001

    if [[ "${VARIANT}" == "workstation" ]]; then
        docker volume create "${layout_attack_volume}" >/dev/null
        docker run --rm \
            --entrypoint sh \
            -v "${layout_attack_volume}:/home/node" \
            "${IMAGE}" \
            -c 'rm -rf /home/node/.local/share/deepseek-harness/auth && ln -s /home/node/.local/share/deepseek-harness/dsh /home/node/.local/share/deepseek-harness/auth'
        expect_start_failure \
            "workstation rejects redirected authentication state" \
            "/home/node/.local/share/deepseek-harness/auth must be a regular directory, not a symbolic link" \
            -e PUBLIC_URL="${PUBLIC_URL}" \
            -e AUTH_PASSWORD="${test_password}" \
            -v "${layout_attack_volume}:/home/node"
    fi
fi

printf '[smoke] ALL TESTS PASSED\n'
