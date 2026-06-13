#!/usr/bin/env bash
# smoke-test.sh — 冒烟测试：快速验证核心服务可用性
set -euo pipefail

status=0

pass() { printf '[smoke] PASS: %s\n' "$*"; }
fail() { printf '[smoke] FAIL: %s\n' "$*" >&2; status=1; }

echo "[smoke] codex-web-workstation smoke test"
echo "[smoke] $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ""
echo "[smoke] === Required Commands ==="
REQUIRED_CMDS=(node npm code-server ttyd codex git curl jq rg fd python3 make gcc g++)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$cmd available"
  else
    fail "$cmd missing"
  fi
done

echo ""
echo "[smoke] === Command Versions ==="
command -v node >/dev/null && node --version && pass "node" || fail "node"
command -v codex >/dev/null && codex --version && pass "codex" || fail "codex"

echo ""
echo "[smoke] === Core Services (HTTP probes) ==="

CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
TTYD_PORT="${TTYD_PORT:-7681}"

# Accept any HTTP response (2xx/3xx/4xx) as proof of listening
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${CODE_SERVER_PORT}/" | grep -qE '^[2345][0-9]{2}$'; then
  pass "code-server responding on port ${CODE_SERVER_PORT}"
else
  fail "code-server not responding on port ${CODE_SERVER_PORT}"
fi

# Accept any HTTP response (2xx/3xx/4xx) as proof of listening
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${TTYD_PORT}/" | grep -qE '^[2345][0-9]{2}$'; then
  pass "ttyd responding on port ${TTYD_PORT}"
else
  fail "ttyd not responding on port ${TTYD_PORT}"
fi

echo ""
echo "[smoke] === Workspace Directory ==="
WORKSPACE="${CONTAINER_WORKSPACE:-/workspace}"
if [ -d "$WORKSPACE" ] && [ -w "$WORKSPACE" ]; then
  pass "${WORKSPACE} exists and writable"
else
  fail "${WORKSPACE} missing or not writable"
fi

echo ""
echo "[smoke] === Persistence Check ==="
for dir in /home/dev/.codex /home/dev/.config/code-server; do
  if [ -d "$dir" ]; then
    pass "${dir} present"
  else
    fail "${dir} missing"
  fi
done

echo ""
echo "[smoke] === Scripts Installed ==="
for script in entrypoint.sh healthcheck.sh configure-provider.sh doctor.sh smoke-test.sh; do
  if [ -x "/usr/local/bin/${script}" ]; then
    pass "${script} installed and executable"
  else
    fail "${script} missing or not executable"
  fi
done

echo ""
if [ "$status" -eq 0 ]; then
  echo "[smoke] ALL TESTS PASSED"
else
  echo "[smoke] ${status} TEST(S) FAILED" >&2
fi

exit "$status"
