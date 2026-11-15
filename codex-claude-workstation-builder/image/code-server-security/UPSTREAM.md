# code-server security dependencies

`package-lock.json` captures the complete production graphs installed with
`npm ci --install-strategy=nested --omit=dev --ignore-scripts`. Registry signatures
and the existing high-severity audit threshold are checked before replacement.

- [body-parser 2.4.0](https://www.npmjs.com/package/body-parser/v/2.4.0): MIT.
  Its nested dependencies travel with the replacement, including compatible
  qs, content-type and iconv-lite versions.
- [follow-redirects 1.16.3](https://www.npmjs.com/package/follow-redirects/v/1.16.3): MIT.
  Fixes [GHSA-mrwp-f3q8-3g9p](https://github.com/advisories/GHSA-mrwp-f3q8-3g9p).
- [brace-expansion 5.0.13](https://www.npmjs.com/package/brace-expansion/v/5.0.13): MIT.
  Replaces EditorConfig's 5.0.5 with its complete nested balanced-match 4.0.4
  dependency. It fixes CVE-2026-13149, CVE-2026-14257, CVE-2026-69152,
  CVE-2026-102276 and CVE-2026-102278 within minimatch's declared `^5.0.5` range.
- [Zod 4.6.7](https://www.npmjs.com/package/zod/v/4.6.7): MIT.
  VS Code and Copilot keep the v4 entry point. Sandbox Runtime keeps the v3
  entry point, including CommonJS, ESM and types. The bundled v3 implementation
  receives the early bounded-container rejection from
  [upstream PR 6652](https://github.com/colinhacks/zod/pull/6652).

Upstream license files remain in each installed package. Patched Zod manifests
record the source version, entry API and backport. Behavioral checks cover
oversized and valid containers, both module entry modes, the real Sandbox Runtime
schemas, and Express JSON/form/error handling.

The integrity-verified code-server 4.145.2 distribution bundles follow-redirects
1.16.2. The replacement accepts this reviewed source and the earlier 1.16.0
layout, then verifies 1.16.3 at the installed path. Unknown versions still stop
the build before any dependency tree is replaced.

Replacement runs after extension installation. The reviewed
[EditorConfig 0.18.2 VSIX](https://open-vsx.org/api/EditorConfig/EditorConfig/0.18.2/file/EditorConfig.EditorConfig-0.18.2.vsix)
has SHA-256 `cbc0370ff204bc16d84a3ee6830536fc04355856fa0e895ab064e1a03cfcb84a`.
Its actual chain is editorconfig 3.0.2 → minimatch 10.2.5 → brace-expansion 5.0.5.
The replacement preserves the named `expand` API and CommonJS/ESM entries.
Tests extract this exact VSIX and exercise real synchronous/asynchronous
EditorConfig parsing, brace sets and numeric ranges, nested config precedence,
unmatched files, and bounded expansion. Both the dependency tree and repeated
replacement are checked by content hashes. Unknown extension, consumer and
dependency versions or paths fail before replacement; a requested but missing
EditorConfig extension also fails. Custom extension lists that omit EditorConfig
may leave it absent.
