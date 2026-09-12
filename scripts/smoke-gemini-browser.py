#!/usr/bin/env python3
"""Exercise the desktop, daemon, Puppeteer/stealth, sharp and persisted cookies."""
import argparse
import json
import subprocess
import sys
import time
import uuid


def docker(*args, check=True, timeout=180):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


PROBE = r"""
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import puppeteer from 'puppeteer-core';
import sharp from 'sharp';
const base = 'http://127.0.0.1:' + process.env.DAEMON_PORT;
const acquired = await (await fetch(base + '/browser/acquire')).json();
assert.equal(acquired.ok, true, JSON.stringify(acquired));
const browser = await puppeteer.connect({browserWSEndpoint: acquired.wsEndpoint});
const cdp = await browser.target().createCDPSession();
const browserPid = (await cdp.send('SystemInfo.getProcessInfo')).processInfo.find(p => p.type === 'browser').id;
const fixture = http.createServer((req, res) => res.end('<title>release-factory smoke</title><h1>Browser works</h1>'));
await new Promise(resolve => fixture.listen(47851, '127.0.0.1', resolve));
try {
  const page = await browser.newPage();
  await page.setViewport({width: 640, height: 480});
  await page.goto('http://127.0.0.1:47851');
  assert.equal(await page.title(), 'release-factory smoke');
  if (process.env.SMOKE_PHASE === 'write') {
    await page.evaluate(() => { document.cookie = 'rf_smoke=persisted; Max-Age=86400; SameSite=Lax'; });
  }
  assert.match(await page.evaluate(() => document.cookie), /rf_smoke=persisted/);
  const png = await sharp(await page.screenshot()).resize(32, 24).png().toBuffer();
  assert.equal((await sharp(png).metadata()).width, 32);
  assert.equal((await sharp(png).metadata()).height, 24);
  assert.equal((await (await fetch(base + '/browser/status')).json()).status, 'online');
  const daemon = fs.readdirSync('/proc').filter(x => /^[0-9]+$/.test(x)).find(pid => {
    try { return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0')[1] === '/opt/gemini-skill/src/daemon/server.js'; }
    catch { return false; }
  });
  assert.ok(daemon, 'daemon process missing');
  assert.ok(Number(fs.readFileSync(`/proc/${daemon}/status`, 'utf8').match(/^Uid:\s+(\d+)/m)[1]) > 0, 'daemon must run as a regular user');
  if (acquired.pid) {
    assert.ok(Number(fs.readFileSync(`/proc/${acquired.pid}/status`, 'utf8').match(/^Uid:\s+(\d+)/m)[1]) > 0, 'browser must run as a regular user');
  }
  console.log('PASS: desktop browser, daemon/CDP, DOM, sharp PNG and ' + process.env.SMOKE_PHASE + ' persisted cookie');
  await page.close();
} finally {
  await browser.disconnect();
  await new Promise(resolve => fixture.close(resolve));
  const released = await fetch(base + '/browser/release', {method: 'POST'});
  assert.equal(released.status, 200);
  // A connected Puppeteer client acknowledges Browser.close before Chrome has
  // exited and flushed its profile. Wait for that process before container stop.
  const alive = () => {
    try { return !/^State:\s+Z/m.test(fs.readFileSync(`/proc/${browserPid}/status`, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return false; throw error; }
  };
  for (let n = 0; n < 100 && alive(); n++) await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(alive(), false, 'browser did not finish a graceful shutdown');
}
"""


def main(image, variant):
    owner = "rf-browser-" + uuid.uuid4().hex[:12]
    volume = owner + "-profile"
    containers = []
    docker("volume", "create", "--label", f"io.release-factory.test={owner}", volume)
    try:
        for phase in ("write", "read"):
            name = owner + "-" + phase
            containers.append(name)
            args = ["run", "-d", "--name", name, "--hostname", "gemini-smoke", "--shm-size", "1g",
                    "--label", f"io.release-factory.test={owner}",
                    "-e", "VNC_PW=ci-gemini-password", "-e", "PASSWORD=ci-gemini-password",
                    "-e", "CUSTOM_USER=smoke", "-e", "DAEMON_TTL_MS=600000",
                    "-v", volume + (":/data" if variant == "kasm" else ":/config")]
            docker(*args, image)
            desktop_port = "6901" if variant == "kasm" else "3001"
            for _ in range(90):
                daemon = docker("exec", name, "curl", "-fsS", "--max-time", "2", "http://127.0.0.1:40225/health", check=False)
                desktop_user = "kasm_user" if variant == "kasm" else "smoke"
                desktop = docker("exec", name, "curl", "-kfsS", "--max-time", "2", "-u", desktop_user + ":ci-gemini-password", f"https://127.0.0.1:{desktop_port}/", check=False)
                if daemon.returncode == 0 and desktop.returncode == 0:
                    assert json.loads(daemon.stdout)["service"] == "browser-daemon"
                    break
                state = json.loads(docker("inspect", name).stdout)[0]["State"]
                if not state["Running"]:
                    raise RuntimeError("browser container exited during startup")
                time.sleep(2)
            else:
                raise RuntimeError("desktop/daemon did not become ready")
            if variant == "linuxserver":
                docker("exec", name, "nginx", "-t")
                docker("exec", name, "sh", "-c", "printf '%s' 'release-factory files smoke' > /config/Desktop/rf-smoke.txt")
                files = docker("exec", name, "curl", "-kfsS", "--max-time", "5", "-u",
                               "smoke:ci-gemini-password", "https://127.0.0.1:3001/files/")
                assert "rf-smoke.txt" in files.stdout, "file browser did not list the test file"
            result = docker("exec", "-w", "/opt/gemini-skill", "-e", "SMOKE_PHASE=" + phase,
                            name, "node", "--input-type=module", "-e", PROBE)
            print(result.stdout, end="", flush=True)
            docker("stop", "--time", "30", name)
    except BaseException:
        for name in containers:
            logs = docker("logs", "--tail", "60", name, check=False)
            print('\n'.join(line[:1200] for line in (logs.stdout + logs.stderr).splitlines()), file=sys.stderr)
            if variant == "kasm":
                logs = docker("exec", name, "tail", "-n", "40", "/var/log/gemini-skill-daemon.err.log", check=False)
                print(logs.stdout + logs.stderr, file=sys.stderr)
        raise
    finally:
        for name in containers:
            label = docker("inspect", "--format", '{{index .Config.Labels "io.release-factory.test"}}', name, check=False)
            if label.stdout.strip() == owner:
                docker("rm", "-f", name)
        label = docker("volume", "inspect", "--format", '{{index .Labels "io.release-factory.test"}}', volume, check=False)
        if label.stdout.strip() == owner:
            docker("volume", "rm", volume)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("variant", choices=("kasm", "linuxserver"))
    args = parser.parse_args()
    main(args.image, args.variant)
