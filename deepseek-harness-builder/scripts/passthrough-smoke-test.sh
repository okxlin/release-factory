#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${PASSTHROUGH_SMOKE_IMAGE:-deepseek-harness:ci-test}"
PUBLIC_URL="${PASSTHROUGH_SMOKE_PUBLIC_URL:-https://dsh.example.test}"

usage() {
    cat <<'EOF'
Usage: passthrough-smoke-test.sh [options]

Options:
  --image IMAGE          Image to test (default: deepseek-harness:ci-test)
  --public-url URL       HTTPS origin simulated through proxy headers
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -ge 2 ]] || {
                printf 'ERROR: --image requires a value\n' >&2
                exit 2
            }
            IMAGE="$2"
            shift 2
            ;;
        --public-url)
            [[ $# -ge 2 ]] || {
                printf 'ERROR: --public-url requires a value\n' >&2
                exit 2
            }
            PUBLIC_URL="$2"
            shift 2
            ;;
        -h | --help)
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

if [[ ! "${PUBLIC_URL}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
    printf 'ERROR: smoke public URL must be an HTTPS origin without a path: %s\n' "${PUBLIC_URL}" >&2
    exit 2
fi

command -v docker >/dev/null 2>&1 || {
    printf 'ERROR: docker is required\n' >&2
    exit 1
}
docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
    printf 'ERROR: image does not exist locally: %s\n' "${IMAGE}" >&2
    exit 1
}

run_id="${PASSTHROUGH_SMOKE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
run_id="$(printf '%s' "${run_id}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
run_id="${run_id:0:28}"
[[ -n "${run_id}" ]] || {
    printf 'ERROR: smoke run ID is empty after normalization\n' >&2
    exit 1
}

container_name="deepseek-harness-passthrough-smoke-${run_id}"
home_volume="deepseek-harness-passthrough-smoke-home-${run_id}"
workspace_volume="deepseek-harness-passthrough-smoke-workspace-${run_id}"
data_bind_dir="$(mktemp -d "/tmp/deepseek-harness-passthrough-smoke-data-${run_id}.XXXXXX")"

pass() {
    printf '[passthrough-smoke] PASS: %s\n' "$*"
}

fail() {
    printf '[passthrough-smoke] FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT

    if ((status != 0)) && docker container inspect "${container_name}" >/dev/null 2>&1; then
        printf '[passthrough-smoke] container logs after failure:\n' >&2
        docker logs "${container_name}" >&2 || true
    fi

    docker rm -f "${container_name}" >/dev/null 2>&1 || true
    docker volume rm "${home_volume}" "${workspace_volume}" >/dev/null 2>&1 || true
    if [[ -d "${data_bind_dir}" ]]; then
        docker run --rm \
            --user 0 \
            --entrypoint sh \
            -v "${data_bind_dir}:/cleanup" \
            "${IMAGE}" \
            -c 'find /cleanup -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
        rmdir "${data_bind_dir}" >/dev/null 2>&1 || true
    fi
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

run_api_contract() {
    docker exec \
        -e TEST_PUBLIC_URL="${PUBLIC_URL}" \
        -i "${container_name}" node - <<'NODE'
const http = require('node:http');

const publicOrigin = new URL(process.env.TEST_PUBLIC_URL);
const proxyHeaders = {
  Host: publicOrigin.host,
  'X-Forwarded-For': '203.0.113.10',
  'X-Forwarded-Host': publicOrigin.host,
  'X-Forwarded-Proto': publicOrigin.protocol.slice(0, -1),
};

function assert(condition, message) {
  if (!condition) throw new Error(message);
  process.stdout.write(`[passthrough-smoke] PASS: ${message}\n`);
}

class CookieJar {
  constructor() {
    this.cookies = new Map();
  }

  store(lines = []) {
    for (const line of lines) {
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

const browserJar = new CookieJar();

function rawRequest(path, options = {}, jar = browserJar) {
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

let rpcSeparator;

async function request(method, payload, origin = publicOrigin.origin) {
  const separators = rpcSeparator === void 0 ? ['/', '.'] : [rpcSeparator];
  let response;
  for (const separator of separators) {
    const endpoint = method.replaceAll('.', separator);
    const body = JSON.stringify({
      type: 'client-request',
      rpcId: `passthrough-smoke-${method}`,
      method: endpoint,
      payload: separator === '/' ? {args: payload} : payload,
    });
    response = await rawRequest(`/api/${endpoint}`, {
        method: 'POST',
        headers: {
          Origin: origin,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
        body,
    });
    if (response.status !== 404 || separator === separators[separators.length - 1]) {
      if (response.status !== 404 && response.status !== 401) rpcSeparator = separator;
      return response;
    }
  }
  return response;
}

async function requestAny(methods, payload, origin = publicOrigin.origin) {
  let response;
  for (const method of methods) {
    response = await request(method, payload, origin);
    if (response.status !== 404) return {method, response};
  }
  return {method: methods[methods.length - 1], response};
}

async function establishBrowserSession() {
  let response = await rawRequest('/');
  for (let redirect = 0; redirect < 4 && response.status >= 300 && response.status < 400; redirect += 1) {
    if (!response.headers.location) throw new Error('DSH bootstrap redirect omitted Location');
    const location = new URL(response.headers.location, publicOrigin);
    if (location.origin !== publicOrigin.origin) {
      throw new Error(`DSH bootstrap redirect left the configured public origin: ${location.origin}`);
    }
    response = await rawRequest(location.pathname + location.search);
  }
  assert(response.status === 200,
    'browser bootstrap exchanges the DSH launch token for a native session');
  assert([...browserJar.cookies.keys()].some(name => name.startsWith('dsh-auth-')),
    'browser bootstrap stores the DSH native session cookie');
}

async function assertRpcSuccess(method, payload, assertValue) {
  const response = await request(method, payload);
  if (response.status !== 200) {
    const preview = response.body.length > 512
      ? `${response.body.slice(0, 512)}...`
      : response.body;
    throw new Error(
      `${method} expected HTTP 200 through the AUTH_MODE=none Caddy proxy, `
      + `got ${response.status}: ${preview}`,
    );
  }
  assert(true, `${method} returns HTTP 200 through the AUTH_MODE=none Caddy proxy`);

  let envelope;
  try {
    envelope = JSON.parse(response.body);
  } catch {
    throw new Error(`${method} returned a non-JSON response: ${response.body}`);
  }
  assert(envelope.type === 'server-response', `${method} returns a DSH server-response envelope`);
  assert(envelope.rpcId === `passthrough-smoke-${method}`, `${method} preserves the RPC ID`);
  assert(envelope.result?.ok === true, `${method} returns result.ok=true`);
  assertValue(envelope.result.value);
}

(async () => {
  await establishBrowserSession();

  const deployment = await rawRequest('/dsh-deployment.js');
  assert(deployment.status === 200,
    'AUTH_MODE=none serves the reviewed outer-auth deployment capability');
  assert((deployment.headers['content-type'] || '').includes('javascript'),
    'deployment capability bootstrap uses a JavaScript media type');
  assert(deployment.body.includes('__DSH_AUTHENTICATED_SETTINGS__ = true'),
    'outer-auth deployment capability enables settings');

  await assertRpcSuccess('settings.describe', {}, value => {
    assert(Array.isArray(value?.namespaces), 'settings.describe returns the settings namespace catalog');
  });
  const providersCall = await requestAny(['llm.listProviders', 'llm.providers'], {});
  if (providersCall.response.status !== 200) {
    throw new Error(`provider directory expected HTTP 200, got ${providersCall.response.status}`);
  }
  const providersEnvelope = JSON.parse(providersCall.response.body);
  const providerDirectory = Array.isArray(providersEnvelope.result?.value)
    ? providersEnvelope.result.value
    : providersEnvelope.result?.value?.providers;
  assert(providersEnvelope.result?.ok === true && Array.isArray(providerDirectory),
    'provider directory returns the model settings provider list');
  await assertRpcSuccess('credentials.describe', {refs: ['DEEPSEEK_API_KEY']}, value => {
    const directory = value?.credentials ?? value;
    assert(directory?.DEEPSEEK_API_KEY !== undefined,
      'credentials.describe returns the requested valid credential reference');
  });
  if (providersCall.method === 'llm.providers') {
    await assertRpcSuccess('host.describe', {}, value => {
      assert(typeof value === 'object' && value !== null,
        'host.describe returns the public Host description');
    });
    const nativeOpen = await request('host.openPath', {});
    assert(nativeOpen.status === 403,
      'AUTH_MODE=none public browsers cannot invoke native host path opening');
  }
  const settingsDocumentCall = await requestAny(['settings.openSettingsDocument', 'settings.openDocument'], {});
  const settingsDocument = settingsDocumentCall.response;
  assert(settingsDocument.status === 403,
    'AUTH_MODE=none public browsers cannot open the Host settings document');
  const crossOrigin = await request('settings.describe', {}, 'https://evil.example');
  assert(crossOrigin.status === 403,
    'Caddy rejects a mismatched Origin before loopback normalization without Sec-Fetch-Site');
  const duplicateOrigin = await request(
    'settings.describe',
    {},
    [publicOrigin.origin, 'https://evil.example'],
  );
  assert(duplicateOrigin.status === 403,
    'Caddy rejects mixed duplicate Origin values before loopback normalization');
})().catch(error => {
  process.stderr.write(`[passthrough-smoke] FAIL: ${error.message}\n`);
  process.exit(1);
});
NODE
}

printf '[passthrough-smoke] image=%s public_url=%s\n' "${IMAGE}" "${PUBLIC_URL}"
docker volume create "${home_volume}" >/dev/null
docker volume create "${workspace_volume}" >/dev/null
docker run -d \
    --name "${container_name}" \
    -e AUTH_MODE=none \
    -e PUBLIC_URL="${PUBLIC_URL}" \
    -v "${data_bind_dir}:/data" \
    -v "${home_volume}:/home/node" \
    -v "${workspace_volume}:/workspace" \
    "${IMAGE}" >/dev/null

wait_for_health
pass "AUTH_MODE=none container became healthy"
run_api_contract
printf '[passthrough-smoke] ALL TESTS PASSED\n'
