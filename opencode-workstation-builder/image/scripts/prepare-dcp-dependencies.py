#!/usr/bin/env python3
"""Pin the default plugin's cache and config dependencies before loading them."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile


def merge_overrides(current, expected):
    changed = False
    for name, value in expected.items():
        if isinstance(value, dict):
            target = current.setdefault(name, {})
            if not isinstance(target, dict):
                raise ValueError(f"conflicting dependency override for {name}")
            changed = merge_overrides(target, value) or changed
        elif current.get(name) != value:
            current[name] = value
            changed = True
    return changed


def pin(directory, expected, installed, current_lock, run):
    directory = Path(directory).absolute()
    if directory.resolve() != directory:
        raise ValueError("plugin dependency directory must not traverse a symlink")
    directory.mkdir(parents=True, exist_ok=True)
    manifest = directory / "package.json"
    lockfile = directory / "package-lock.json"
    if manifest.is_symlink() or lockfile.is_symlink():
        raise ValueError("plugin dependency manifests must not be symlinks")
    data = json.loads(manifest.read_text()) if manifest.exists() else {"private": True}
    changed = merge_overrides(data.setdefault("overrides", {}), expected)
    if changed:
        with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as output:
            json.dump(data, output, indent=2)
            output.write("\n")
        os.replace(output.name, manifest)
    if (directory / "node_modules" / installed).exists():
        lock = json.loads(lockfile.read_text()) if lockfile.exists() else {}
        if changed or not current_lock(lock.get("packages", {})):
            print(f"[plugins] refreshing security overrides in {directory}", flush=True)
            run(["npm", "install", "--prefix", str(directory), "--ignore-scripts",
                 "--no-audit", "--no-fund"], check=True)


def resolve_dependency(packages, consumer, name):
    directory = PurePosixPath(consumer)
    for parent in (directory, *directory.parents):
        candidate = str(parent / "node_modules" / name)
        if candidate in packages:
            return candidate
    return None


def prepare(package, baseline, cache, run=subprocess.run, config_dirs=()):
    config = json.loads((Path(baseline) / "package.json").read_text())["config"]
    if package != config["dcpPackage"]:
        return  # Explicitly selected plugins keep their own dependency policy.
    if not re.fullmatch(r"@tarquinen/opencode-dcp@\d+\.\d+\.\d+", package):
        raise ValueError("default DCP must be an exact stable package version")
    version = config["dcpSerovalVersion"]
    if not re.fullmatch(r"1\.\d+\.\d+", version):
        raise ValueError("DCP serializer must be pinned within the reviewed major version")
    toml_version = config["dcpTomlVersion"]
    if not re.fullmatch(r"5\.\d+\.\d+", toml_version):
        raise ValueError("DCP TOML parser must be pinned within the reviewed major version")
    zod_version = config["dcpZodVersion"]
    if not re.fullmatch(r"4\.\d+\.\d+", zod_version):
        raise ValueError("DCP Zod must be pinned within the reviewed major version")
    # OpenCode 1.18.30's Npm.add uses this package-specific cache and honors npm
    # overrides, but skips reification if the plugin is already installed.
    # https://github.com/anomalyco/opencode/blob/5cd8e68fdd72b27818d26d168b9c7a06b359567e/packages/core/src/npm.ts
    expected_overrides = {"seroval": version, "toml": toml_version, "zod": zod_version}

    def cache_current(packages):
        package_versions = {}
        for package_name in expected_overrides:
            package_versions[package_name] = [
                entry.get("version") for name, entry in packages.items()
                if name == f"node_modules/{package_name}" or name.endswith(f"/node_modules/{package_name}")
            ]
        return all(versions and all(value == expected_overrides[name] for value in versions)
                   for name, versions in package_versions.items())

    pin(Path(cache) / "opencode/packages" / package, expected_overrides,
        "@tarquinen/opencode-dcp", cache_current, run)

    # The config loader independently adds @opencode-ai/plugin, whose Zod and
    # Effect/TOML dependencies are not covered by the package-specific cache.
    # Scope these overrides to that consumer so custom plugins keep their majors.
    def config_current(packages):
        plugin = resolve_dependency(packages, "", "@opencode-ai/plugin")
        if plugin is None:
            return False
        zod = resolve_dependency(packages, plugin, "zod")
        effect = resolve_dependency(packages, plugin, "effect")
        toml = resolve_dependency(packages, effect, "toml") if effect else None
        return (packages.get(zod, {}).get("version") == zod_version
                and packages.get(toml, {}).get("version") == toml_version)

    config_overrides = {"@opencode-ai/plugin": {
        "zod": zod_version, "effect": {"toml": toml_version}}}
    for directory in dict.fromkeys(Path(path).absolute() for path in config_dirs):
        pin(directory, config_overrides, "@opencode-ai/plugin", config_current, run)


if __name__ == "__main__":
    config_dirs = [Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "opencode"]
    if os.environ.get("OPENCODE_CONFIG_DIR"):
        config_dirs.append(Path(os.environ["OPENCODE_CONFIG_DIR"]))
    prepare(sys.argv[1], os.environ.get("OPENCODE_BASELINE_DIR", "/opt/opencode"),
            os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")), config_dirs=config_dirs)
