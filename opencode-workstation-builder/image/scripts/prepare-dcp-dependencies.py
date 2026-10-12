#!/usr/bin/env python3
"""Pin the default DCP cache's vulnerable transitive serializer before loading it."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def prepare(package, baseline, cache, run=subprocess.run):
    config = json.loads((Path(baseline) / "package.json").read_text())["config"]
    if package != config["dcpPackage"]:
        return  # Explicitly selected plugins keep their own dependency policy.
    if not re.fullmatch(r"@tarquinen/opencode-dcp@\d+\.\d+\.\d+", package):
        raise ValueError("default DCP must be an exact stable package version")
    version = config["dcpSerovalVersion"]
    if not re.fullmatch(r"1\.\d+\.\d+", version):
        raise ValueError("DCP serializer must be pinned within the reviewed major version")
    # OpenCode 1.18.30's Npm.add uses this package-specific cache and honors npm
    # overrides, but skips reification if the plugin is already installed.
    # https://github.com/anomalyco/opencode/blob/5cd8e68fdd72b27818d26d168b9c7a06b359567e/packages/core/src/npm.ts
    directory = Path(cache).absolute() / "opencode/packages" / package
    if directory.resolve() != directory:
        raise ValueError("DCP cache must not traverse a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    manifest = directory / "package.json"
    lockfile = directory / "package-lock.json"
    if manifest.is_symlink() or lockfile.is_symlink():
        raise ValueError("DCP dependency manifests must not be symlinks")
    data = json.loads(manifest.read_text()) if manifest.exists() else {"private": True}
    overrides = data.setdefault("overrides", {})
    changed = overrides.get("seroval") != version
    if changed:
        overrides["seroval"] = version
        with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as output:
            json.dump(data, output, indent=2)
            output.write("\n")
        os.replace(output.name, manifest)
    installed = directory / "node_modules/@tarquinen/opencode-dcp"
    if installed.exists():
        lock = json.loads(lockfile.read_text()) if lockfile.exists() else {}
        serializers = [entry.get("version") for name, entry in lock.get("packages", {}).items()
                       if name.endswith("node_modules/seroval")]
        if changed or not serializers or any(value != version for value in serializers):
            print(f"[plugins] refreshing default DCP serializer to {version}", flush=True)
            run(["npm", "install", "--prefix", str(directory), "--ignore-scripts",
                 "--no-audit", "--no-fund"], check=True)


if __name__ == "__main__":
    prepare(sys.argv[1], os.environ.get("OPENCODE_BASELINE_DIR", "/opt/opencode"),
            os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
