#!/usr/bin/env python3
"""Verify the default plugin, authenticated serve mode, persistence and userland scan."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def docker(*args, check=True, timeout=180):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def main(image, report):
    owner = "rf-opencode-" + uuid.uuid4().hex[:12]
    volume = owner + "-home"
    containers = []
    password = "ci-" + uuid.uuid4().hex
    docker("volume", "create", "--label", f"io.release-factory.test={owner}", volume)
    try:
        for phase in ("first", "persisted"):
            name = owner + "-" + phase
            containers.append(name)
            docker("run", "-d", "--name", name, "--label", f"io.release-factory.test={owner}",
                   "-e", "OPENCODE_RUNTIME_MODE=serve", "-e", "SERVE_HOST=127.0.0.1",
                   "-e", "OPENCODE_SERVER_PASSWORD=" + password, "-v", volume + ":/home/opencode",
                   image, "runtime")
            for _ in range(120):
                health = docker("exec", name, "curl", "-fsS", "--max-time", "2", "-u", "opencode:" + password,
                                "http://127.0.0.1:4096/global/health", check=False)
                if health.returncode == 0:
                    assert json.loads(health.stdout)["healthy"] is True
                    break
                state = json.loads(docker("inspect", name).stdout)[0]["State"]
                if not state["Running"]:
                    raise RuntimeError("OpenCode exited during bootstrap")
                time.sleep(2)
            else:
                raise RuntimeError("OpenCode serve did not become healthy")
            denied = docker("exec", name, "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                            "http://127.0.0.1:4096/config").stdout
            assert denied == "401", "OpenCode accepted an unauthenticated config request"
            config = json.loads(docker("exec", name, "curl", "-fsS", "--max-time", "60", "-u", "opencode:" + password,
                                       "http://127.0.0.1:4096/config").stdout)
            expected = json.loads(docker("exec", name, "cat", "/opt/opencode/package.json").stdout)
            assert expected["config"]["dcpPackage"] in config["plugin"], "default DCP plugin not loaded"
            if phase == "first":
                assert docker("exec", name, "test", "-e", "/usr/bin/node", check=False).returncode != 0, "unexpected second distro Node runtime"
                docker("exec", name, "tsc", "--version")
                print(docker("exec", name, "/app/scripts/smoke-test.sh", timeout=600).stdout, end="", flush=True)
                docker("exec", name, "sh", "-c", 'printf preserved > "$HOME/.config/smoke-marker"')
                with tempfile.TemporaryDirectory(prefix=owner + "-scan-") as directory:
                    snapshot = Path(directory).resolve()
                    for path in (".config/opencode", ".cache/opencode", ".local/share/opencode"):
                        source = "/home/opencode/" + path
                        if docker("exec", name, "test", "-d", source, check=False).returncode:
                            continue
                        size = docker("exec", name, "du", "-sb", source).stdout.strip()
                        target = snapshot / "home/opencode" / path
                        target.parent.mkdir(parents=True, exist_ok=True)
                        print(f"Userland snapshot: {name}:{source} -> {target}; {size}", flush=True)
                        docker("cp", name + ":" + source, str(target))
                    packages = list(snapshot.rglob("package.json"))
                    assert any(json.loads(path.read_text()).get("name") == "@tarquinen/opencode-dcp"
                               for path in packages), "DCP artifacts missing from userland snapshot"
                    subprocess.run(["bash", str(ROOT / "scripts/trivy-image-gate.sh"), "--filesystem", str(snapshot),
                                    "--policy", str(ROOT / "opencode-workstation-builder/configs/trivy-policy.json"),
                                    "--profile", "workstation", "--output", str(report)], check=True)
            else:
                assert docker("exec", name, "cat", "/home/opencode/.config/smoke-marker").stdout == "preserved"
            print("PASS: default DCP, authenticated OpenCode serve and " + phase + " HOME", flush=True)
            docker("stop", name)
    except BaseException:
        for name in containers:
            logs = docker("logs", "--tail", "60", name, check=False)
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
    parser.add_argument("--userland-report", required=True, type=Path)
    args = parser.parse_args()
    main(args.image, args.userland_report.resolve())
