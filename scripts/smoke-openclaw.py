#!/usr/bin/env python3
"""Verify gateway auth and real sandbox operations against a disposable daemon."""
import argparse
import json
from pathlib import Path
import secrets
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def docker(*args, check=True, timeout=180, **kwargs):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout, **kwargs)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


SANDBOX_PROBE = r"""
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {resolveSandboxContext} from '/app/dist/plugin-sdk/agent-harness-runtime.js';
const config = {agents: {defaults: {
  workspace: '/workspace/agent', skipBootstrap: true,
  sandbox: {mode: 'all', scope: 'session', workspaceAccess: 'rw', workspaceRoot: '/workspace/sandboxes',
    docker: {image: process.env.SMOKE_SANDBOX_IMAGE, containerPrefix: 'rf-inner-', network: 'none',
             readOnlyRoot: true, user: '1000:1000', capDrop: ['ALL']},
    browser: {enabled: false}, prune: {idleHours: 0, maxAgeDays: 0}}
}}};
await fs.mkdir('/workspace/agent', {recursive: true});
await fs.writeFile('/home/node/.openclaw/openclaw.json', JSON.stringify(config));
const params = {config, agentId: 'main', sessionKey: 'agent:main:rf-smoke', workspaceDir: '/workspace/agent'};
let sandbox = await resolveSandboxContext(params);
assert.equal(sandbox.backendId, 'docker');
const info = JSON.parse(execFileSync('docker', ['inspect', sandbox.containerName], {encoding: 'utf8'}))[0];
assert.equal(info.HostConfig.NetworkMode, 'none');
assert.equal(info.HostConfig.ReadonlyRootfs, true);
assert.equal(info.HostConfig.Privileged, false);
assert.deepEqual(info.HostConfig.CapDrop, ['ALL']);
assert.ok(info.Mounts.every(m => m.Type === 'tmpfs' ? ['/tmp', '/var/tmp', '/run'].includes(m.Destination)
  : m.Type === 'bind' && !m.Source.includes('docker.sock') && (m.Source.startsWith('/workspace/')
    || !m.RW && m.Source.startsWith('/home/node/.openclaw/sandbox/skills-workspaces/'))), JSON.stringify(info.Mounts));
const run = await sandbox.backend.runShellCommand({script: 'printf "sandbox works" > /workspace/probe.txt; cat /workspace/probe.txt; id -u'});
assert.equal(run.code, 0);
assert.match(run.stdout.toString(), /sandbox works1000/);
assert.equal(await fs.readFile('/workspace/agent/probe.txt', 'utf8'), 'sandbox works');
const denied = await sandbox.backend.runShellCommand({script: 'touch /must-not-write', allowFailure: true});
assert.notEqual(denied.code, 0, 'sandbox root must remain read only');
const list = execFileSync('node', ['/app/openclaw.mjs', 'sandbox', 'list', '--json'], {encoding: 'utf8'});
const listed = JSON.parse(list).containers.find(item => item.containerName === sandbox.containerName);
assert.ok(listed?.sessionKey, 'sandbox CLI did not report the real container');
// Upstream qualifies the CLI scope key with the workspace hash.
execFileSync('node', ['/app/openclaw.mjs', 'sandbox', 'recreate', '--session', listed.sessionKey, '--force']);
assert.throws(() => execFileSync('docker', ['inspect', sandbox.containerName], {stdio: 'pipe'}));
sandbox = await resolveSandboxContext(params);
const after = await sandbox.backend.runShellCommand({script: 'cat /workspace/probe.txt'});
assert.equal(after.stdout.toString(), 'sandbox works');
console.log('PASS: OpenClaw provisions, executes, lists and recreates its sandbox; workspace persists, root is read only, network/capabilities/socket are isolated');
"""


def main(image):
    components = json.loads((ROOT / "openclaw-builder/configs/components.json").read_text())
    daemon_image, sandbox_image = components["test_daemon_image"], components["test_sandbox_image"]
    for dependency in (daemon_image, sandbox_image):
        if docker("image", "inspect", dependency, check=False).returncode:
            docker("pull", "--quiet", dependency, timeout=300)
    owner = "rf-openclaw-" + uuid.uuid4().hex[:12]
    daemon, gateway = owner + "-daemon", owner + "-gateway"
    volumes = [owner + suffix for suffix in ("-socket", "-data", "-workspace", "-state")]
    sandbox_tag = "release-factory-test/sandbox:" + owner
    token = secrets.token_hex(24)
    try:
        for volume in volumes:
            docker("volume", "create", "--label", f"io.release-factory.test={owner}", volume)
        # The gateway never receives the host Docker socket. This daemon has no
        # network or host directory mounts and owns only the four test volumes.
        docker("run", "-d", "--name", daemon, "--network", "none", "--privileged",
               "--label", f"io.release-factory.test={owner}", "--entrypoint", "dockerd",
               "-v", volumes[0] + ":/docker", "-v", volumes[1] + ":/var/lib/docker",
               "-v", volumes[2] + ":/workspace", "-v", volumes[3] + ":/home/node/.openclaw", daemon_image,
               "--host=unix:///docker/docker.sock", "--bridge=none", "--iptables=false",
               "--ip6tables=false", "--ip-forward=false", "--storage-driver=vfs")
        for _ in range(60):
            if docker("exec", daemon, "docker", "-H", "unix:///docker/docker.sock", "info", check=False).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("isolated Docker daemon did not become ready")
        docker("exec", daemon, "sh", "-c", "chown 1000:1000 /docker/docker.sock /workspace /home/node/.openclaw; chmod 660 /docker/docker.sock")
        docker("image", "tag", sandbox_image, sandbox_tag)
        with subprocess.Popen(["docker", "save", sandbox_tag], stdout=subprocess.PIPE) as saved:
            loaded = subprocess.run(["docker", "exec", "-i", daemon, "docker", "-H", "unix:///docker/docker.sock", "load"],
                                    stdin=saved.stdout, capture_output=True, text=True, timeout=120)
            saved.stdout.close()
            if saved.wait(timeout=30) or loaded.returncode:
                raise RuntimeError("could not load the sandbox fixture into the isolated daemon")
        docker("run", "-d", "--name", gateway, "--network", "none", "--label", f"io.release-factory.test={owner}",
               "-e", "OPENCLAW_GATEWAY_TOKEN=" + token, "-e", "DOCKER_HOST=unix:///docker/docker.sock",
               "-e", "SMOKE_SANDBOX_IMAGE=" + sandbox_tag, "-v", volumes[0] + ":/docker",
               "-v", volumes[2] + ":/workspace", "-v", volumes[3] + ":/home/node/.openclaw",
               "--entrypoint", "node", image, "/app/openclaw.mjs",
               "gateway", "run", "--allow-unconfigured", "--auth", "token", "--bind", "loopback")
        for _ in range(90):
            probe = docker("exec", gateway, "node", "-e",
                           "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))", check=False)
            if probe.returncode == 0:
                break
            if not json.loads(docker("inspect", gateway).stdout)[0]["State"]["Running"]:
                raise RuntimeError("OpenClaw gateway exited during startup")
            time.sleep(2)
        else:
            raise RuntimeError("OpenClaw gateway did not become healthy")
        rejected = docker("exec", gateway, "node", "/app/openclaw.mjs", "gateway", "health",
                          "--url", "ws://127.0.0.1:18789", "--token", "invalid-test-token", check=False)
        assert rejected.returncode and any(s in (rejected.stdout + rejected.stderr).lower()
                                           for s in ("unauthorized", "token mismatch", "token_mismatch")), "gateway must reject invalid auth"
        healthy = docker("exec", gateway, "node", "/app/openclaw.mjs", "gateway", "health", "--json")
        assert '"ok": true' in healthy.stdout, "authenticated deep health did not succeed"
        print("PASS: gateway liveness, invalid-token rejection and authenticated deep health", flush=True)
        result = docker("exec", gateway, "node", "--input-type=module", "-e", SANDBOX_PROBE, timeout=300)
        print(result.stdout, end="", flush=True)
        version = docker("exec", gateway, "docker", "compose", "version", "--short")
        assert version.stdout.strip(), "bundled Compose must execute"
    except BaseException:
        for name in (gateway, daemon):
            logs = docker("logs", "--tail", "40", name, check=False)
            print((logs.stdout + logs.stderr).replace(token, "[test token]")[-12000:], file=sys.stderr)
        raise
    finally:
        for name in (gateway, daemon):
            label = docker("inspect", "--format", '{{index .Config.Labels "io.release-factory.test"}}', name, check=False)
            if label.stdout.strip() == owner:
                docker("rm", "-f", "-v", name)
        for volume in volumes:
            label = docker("volume", "inspect", "--format", '{{index .Labels "io.release-factory.test"}}', volume, check=False)
            if label.stdout.strip() == owner:
                docker("volume", "rm", volume)
        original = docker("image", "inspect", "--format", "{{.Id}}", sandbox_image, check=False)
        tagged = docker("image", "inspect", "--format", "{{.Id}}", sandbox_tag, check=False)
        if tagged.returncode == 0 and tagged.stdout == original.stdout:
            docker("image", "rm", sandbox_tag)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    main(parser.parse_args().image)
