# OpenCode baseline

This image bundles the Linux runtime artifacts of OpenCode 1.18.30, released at
https://github.com/anomalyco/opencode/releases/tag/v1.18.30 from source commit
`5cd8e68fdd72b27818d26d168b9c7a06b359567e`.

The package lock pins the platform packages and their npm integrity values.
Only the current Linux architecture is installed, with lifecycle scripts disabled.
amd64 uses the baseline binary so first startup also works on CPUs without AVX2.
The included MIT license is from the integrity-verified `opencode-ai@1.18.30` npm
distribution, which selects these same platform artifacts in its postinstall.

`config.dcpPackage` pins the existing optional DCP bootstrap to a specific release.
DCP is installed in the user's configuration/cache when enabled; its AGPL-3.0-or-later
license and source are available at
https://github.com/Opencode-DCP/opencode-dynamic-context-pruning.

The default DCP cache pins `seroval` to 1.6.9, `toml` to 5.0.1, and
`zod` to 4.6.6 (all MIT) through npm overrides. This fixes the reviewed serializer,
TOML parser, and Zod advisories without changing the DCP release.
`prepare-dcp-dependencies.py` seeds the override before OpenCode installs the
plugin and refreshes existing default caches with lifecycle scripts disabled.
OpenCode also installs `@opencode-ai/plugin` in its configuration directories;
the script pins that consumer's Zod and Effect/TOML dependencies separately,
preserving unrelated plugin overrides and dependency majors.
TOML 5 retains `parse(content)` and rejects unsafe integer values rather than
rounding them, as documented in
https://github.com/BinaryMuse/toml-node/blob/v5.0.1/CHANGELOG.md.
Explicit custom DCP package selections retain their own dependency policy.
OpenCode's package cache and Arborist install behavior are verified against
https://github.com/anomalyco/opencode/blob/5cd8e68fdd72b27818d26d168b9c7a06b359567e/packages/core/src/npm.ts.
CI scans the installed userland tree in addition to the image.

Update the version and both optional dependencies together, then regenerate the
lock with `npm install --package-lock-only --ignore-scripts`. Verify both native
architectures, the default plugin path, and the image/userland vulnerability scans.

Security evidence reviewed on 2026-09-13: the release has no standalone SBOM
asset. Trivy can inspect package metadata and installed DCP files, but cannot
enumerate the JavaScript dependencies compiled into OpenCode's Bun executable.
The published repository advisories are fixed before the selected baseline:

- <https://github.com/anomalyco/opencode/security/advisories/GHSA-c83v-7274-4vgp>
  affects versions before 1.1.10 (web UI XSS).
- <https://github.com/anomalyco/opencode/security/advisories/GHSA-vxw4-wv6m-9hhh>
  affects versions before 1.0.216 (unauthenticated HTTP server).

The smoke test also verifies that `/config` rejects unauthenticated requests
when the documented server password is set. This evidence does not establish
that every embedded library is vulnerability-free; recheck upstream advisories
when updating the baseline.
