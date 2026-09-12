#!/usr/bin/env python3
"""Verify credential rejection, authenticated startup, and persisted HOME."""
import json
import subprocess
import sys
import time
import uuid


def docker(*args, check=True):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=180)
    if check and result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result


def main(image):
    owner = "rf-codex-" + uuid.uuid4().hex[:12]
    containers, volumes = [], []

    def start(suffix, password=None, paseo=None, mounts=(), network="none"):
        name = owner + "-" + suffix
        args = ["run", "-d", "--name", name, "--label", f"io.release-factory.test={owner}",
                "--network", network, "--hostname", "workstation", "-e", "CODEX_SANDBOX_STRICT=false"]
        if password is not None:
            args += ["-e", "PASSWORD=" + password]
        if paseo is not None:
            args += ["-e", "PASEO_PASSWORD=" + paseo]
        for volume, path in mounts:
            args += ["-v", volume + ":" + path]
        containers.append(name)
        docker(*args, image)
        return name

    def ready(name):
        for _ in range(45):
            if docker("exec", name, "healthcheck.sh", check=False).returncode == 0:
                return
            state = json.loads(docker("inspect", name).stdout)[0]["State"]
            if not state["Running"]:
                break
            time.sleep(2)
        raise RuntimeError("workstation did not become healthy")

    def login(name):
        docker("exec", name, "node", "--input-type=module", "-e", """
import assert from 'node:assert/strict';
import fs from 'node:fs';
const result = await fetch('http://127.0.0.1:8080/login', {
  method: 'POST', body: new URLSearchParams({password: process.env.PASSWORD}), redirect: 'manual',
});
assert.equal(result.status, 302);
assert.ok(result.headers.get('set-cookie'));
assert.ok(!/^password\\s*:/m.test(fs.readFileSync(process.env.HOME + '/.config/code-server/config.yaml', 'utf8')));
""")

    try:
        for suffix, password in [("missing", None), ("blank", "   "), ("example", "change-me")]:
            name = start(suffix, password)
            for _ in range(20):
                state = json.loads(docker("inspect", name).stdout)[0]["State"]
                if not state["Running"]:
                    break
                time.sleep(1)
            assert not state["Running"] and state["ExitCode"] == 1, "unsafe credentials did not stop startup"
            assert "ERROR: set a unique non-empty PASSWORD" in docker("logs", name).stderr
            print(f"PASS: {suffix} password rejected before startup", flush=True)

        for suffix in ("home", "workspace"):
            volume = owner + "-" + suffix
            docker("volume", "create", "--label", f"io.release-factory.test={owner}", volume)
            volumes.append(volume)
        mounts = list(zip(volumes, ("/home/dev", "/workspace")))
        # Development tools may fetch platform binaries on first use.
        name = start("legacy", "ci-legacy-password-20260912", mounts=mounts, network="bridge")
        ready(name)
        login(name)
        print(docker("exec", name, "doctor.sh").stdout, end="", flush=True)
        print(docker("exec", name, "smoke-test.sh").stdout, end="", flush=True)
        docker("exec", name, "sh", "-c", 'printf preserved > "$HOME/.config/smoke-marker"')
        docker("stop", name)

        name = start("separate", "ci-password: # with spaces", "ci-paseo-token-20260912", mounts, network="bridge")
        ready(name)
        login(name)
        assert docker("exec", name, "cat", "/home/dev/.config/smoke-marker").stdout == "preserved"
        print("PASS: legacy fallback, explicit Paseo password, YAML-safe login, and HOME persistence", flush=True)
    except BaseException:
        for name in containers:
            result = docker("logs", "--tail", "60", name, check=False)
            print(result.stdout + result.stderr, file=sys.stderr)
        raise
    finally:
        for name in containers:
            label = docker("inspect", "--format", '{{index .Config.Labels "io.release-factory.test"}}', name, check=False)
            if label.stdout.strip() == owner:
                docker("rm", "-f", name, check=False)
        for name in volumes:
            label = docker("volume", "inspect", "--format", '{{index .Labels "io.release-factory.test"}}', name, check=False)
            if label.stdout.strip() == owner:
                docker("volume", "rm", name)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: smoke-codex-workstation.py IMAGE")
    main(sys.argv[1])
