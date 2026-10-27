# code-server security dependencies

`package-lock.json` captures the complete production graphs installed with
`npm ci --install-strategy=nested --omit=dev --ignore-scripts`. Registry signatures
and the existing high-severity audit threshold are checked before replacement.

- [body-parser 2.4.0](https://www.npmjs.com/package/body-parser/v/2.4.0): MIT.
  Its nested dependencies travel with the replacement, including compatible
  qs, content-type and iconv-lite versions.
- [follow-redirects 1.16.1](https://www.npmjs.com/package/follow-redirects/v/1.16.1): MIT.
- [Zod 4.6.6](https://www.npmjs.com/package/zod/v/4.6.6): MIT.
  VS Code and Copilot keep the v4 entry point. Sandbox Runtime keeps the v3
  entry point, including CommonJS, ESM and types. The bundled v3 implementation
  receives the early bounded-container rejection from
  [upstream PR 6652](https://github.com/colinhacks/zod/pull/6652).

Upstream license files remain in each installed package. Patched Zod manifests
record the source version, entry API and backport. Behavioral checks cover
oversized and valid containers, both module entry modes, the real Sandbox Runtime
schemas, and Express JSON/form/error handling.
