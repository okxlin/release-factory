# OpenCode baseline

This image bundles the Linux runtime artifacts of OpenCode 1.19.5, released at
https://github.com/anomalyco/opencode/releases/tag/v1.19.5 from source commit
`810c0eba1a7348036f8bdf61e6632d0c36c6876c`.

The package lock pins the platform packages and their npm integrity values.
Only the current Linux architecture is installed, with lifecycle scripts disabled.
amd64 uses the baseline binary so first startup also works on CPUs without AVX2.
The included MIT license is from the integrity-verified `opencode-ai@1.19.5` npm
distribution, which selects these same platform artifacts in its postinstall.

`config.dcpPackage` pins the optional DCP bootstrap to 3.2.0, source commit
`d637981555a18c3992472268a0657a948925d5fa`. This release retains OpenCode V1
support with a minimum version of 1.18.29, as documented at
https://github.com/Tarquinen/opencode-dynamic-context-pruning/releases/tag/v3.2.0.
DCP is installed in the user's configuration/cache when enabled; its AGPL-3.0-or-later
license and source are available at
https://github.com/Tarquinen/opencode-dynamic-context-pruning.

The default DCP cache pins `seroval` to 1.6.11, `toml` to 5.0.1,
`zod` to 4.6.7 and Babel core to 7.29.13 (all MIT) through npm overrides.
These retain the reviewed serializer, TOML parser and Zod security policy for
the updated DCP release, and keep its TUI compiler on Babel 7.
Seroval 1.6.11 also fixes typed-array constructor injection and RegExp-source
script injection while retaining the existing serializer API:
https://github.com/advisories/GHSA-f86p-h4j2-7qgj
https://github.com/advisories/GHSA-9wx9-5pv9-3349
Babel's sourceMappingURL arbitrary-file-read advisory is fixed without changing
the compiler major:
https://github.com/advisories/GHSA-4x5r-pxfx-6jf8
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
https://github.com/anomalyco/opencode/blob/810c0eba1a7348036f8bdf61e6632d0c36c6876c/packages/core/src/npm.ts.
CI scans the installed userland tree in addition to the image.

The default DCP installed tree was audited on 2026-11-15. Its seven moderate
dependency nodes propagate three remaining advisories; there are no high or
critical findings in this native npm audit. Paths below are relative to
`${XDG_CACHE_HOME:-$HOME/.cache}/opencode/packages/@tarquinen/opencode-dcp@3.2.0`:

- `node_modules/effect` 4.0.0-beta.83 has cookie attribute injection
  <https://github.com/advisories/GHSA-chp3-j5qr-2vfr>, first fixed in
  4.0.0-beta.103. `@opencode-ai/plugin` 1.19.5 pins beta.83 exactly. The default
  config tree also installs this version at
  `${XDG_CONFIG_HOME:-$HOME/.config}/opencode/node_modules/effect`; its audit has
  two moderate nodes from the same advisory. The reviewed
  distributed DCP/plugin JavaScript has no cookie or `makeCookie` references;
  this does not establish the behavior of libraries inside OpenCode's executable.
- `node_modules/glob` 9.3.5 has AbortSignal cancellation bypass
  <https://github.com/advisories/GHSA-3g3m-2fjr-6pw4>, first fixed in 14.0.2.
  `babel-plugin-module-resolver` 5.0.2 requires Glob `^9.3.3`.
- `node_modules/minimatch` 8.0.7 has glob-parts amplification
  <https://github.com/advisories/GHSA-g3hv-75wg-m249>, first fixed in 11.0.1.
  Glob 9.3.5 requires Minimatch `^8.0.2`.

The reviewed `@opentui/solid` 0.4.5 `scripts/solid-transform.js` only enables
module-resolver with a custom resolve callback, supplies no root glob patterns
or AbortSignal, and disables Babel config files. Module-resolver returns an
empty root list when `root` is absent, avoiding its `glob.sync` traversal on
this path. All five distributed DCP TSX files compile with Babel 7.29.13;
rendered TUI behavior and arbitrary custom compiler/plugin usage are outside
this evidence. Patched Effect beta and Glob/Minimatch majors need upstream
compatibility evidence before replacing the current consumer pins. Recheck
these advisories when updating OpenCode, DCP or OpenTUI.

Update the version and both optional dependencies together, then regenerate the
lock with `npm install --package-lock-only --ignore-scripts`. Verify both native
architectures, the default plugin path, and the image/userland vulnerability scans.

Security evidence reviewed on 2026-11-14: the release has no standalone SBOM
asset. Trivy can inspect package metadata and installed DCP files, but cannot
enumerate the JavaScript dependencies compiled into OpenCode's Bun executable.
The published repository advisories are fixed before the selected baseline:

- <https://github.com/anomalyco/opencode/security/advisories/GHSA-c83v-7274-4vgp>
  affects versions before 1.1.10 (web UI XSS).
- <https://github.com/anomalyco/opencode/security/advisories/GHSA-vxw4-wv6m-9hhh>
  affects versions before 1.0.216 (unauthenticated HTTP server).
- <https://github.com/anomalyco/opencode/security/advisories/GHSA-632h-h47v-g4x4>
  is fixed in 1.18.22. The upgrade endpoint requires a JSON body and a semantic
  version target, preventing cross-site forms and alternate npm package sources.

The smoke test also verifies that `/config` rejects unauthenticated requests
when the documented server password is set. This evidence does not establish
that every embedded library is vulnerability-free; recheck upstream advisories
when updating the baseline.
