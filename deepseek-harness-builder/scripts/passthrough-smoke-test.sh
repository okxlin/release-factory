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
  Origin: publicOrigin.origin,
  'X-Forwarded-For': '203.0.113.10',
  'X-Forwarded-Host': publicOrigin.host,
  'X-Forwarded-Proto': publicOrigin.protocol.slice(0, -1),
};

function assert(condition, message) {
  if (!condition) throw new Error(message);
  process.stdout.write(`[passthrough-smoke] PASS: ${message}\n`);
}

function request(method, payload) {
  const body = JSON.stringify({
    type: 'client-request',
    rpcId: `passthrough-smoke-${method}`,
    method,
    payload,
  });
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port: 8080,
      path: `/api/${method}`,
      method: 'POST',
      headers: {
        ...proxyHeaders,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
      timeout: 10000,
    }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({
        status: res.statusCode,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });

    req.on('timeout', () => req.destroy(new Error('HTTP request timed out')));
    req.on('error', reject);
    req.end(body);
  });
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
  await assertRpcSuccess('settings.describe', {}, value => {
    assert(Array.isArray(value?.namespaces), 'settings.describe returns the settings namespace catalog');
  });
  await assertRpcSuccess('credentials.describe', {refs: ['DEEPSEEK_API_KEY']}, value => {
    assert(value?.credentials?.DEEPSEEK_API_KEY !== undefined,
      'credentials.describe returns the requested valid credential reference');
  });
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
