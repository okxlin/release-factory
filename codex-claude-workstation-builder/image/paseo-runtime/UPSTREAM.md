# Paseo upstream source

This image redistributes the unmodified Paseo npm runtime pinned below.

- npm package: `@getpaseo/cli@0.3.1`
- npm package page: <https://www.npmjs.com/package/@getpaseo/cli/v/0.3.1>
- upstream repository: <https://github.com/getpaseo/paseo>
- upstream tag: `v0.3.1`
- tag commit: `bfec7ac3adc5e8835e873ee75c7b325af6c7a8c3`
- exact source: <https://github.com/getpaseo/paseo/tree/bfec7ac3adc5e8835e873ee75c7b325af6c7a8c3>
- license: AGPL-3.0-or-later
- bundled license SHA-256: `2d29a730f15470509f7a36e63a024c2f121958471474dfcd6b272c99586fc337`

The dependency graph is captured in `package-lock.json`. The image installs it with npm lifecycle scripts disabled and verifies registry signatures during the build.

Security overrides pin Zod to 4.6.7 and keep body-parser aligned with its
consumer: Paseo's Express 4 uses 1.20.9, while the MCP SDK's Express 5 uses
2.4.0. fast-uri 3.1.9 fixes URI normalization and scheme/host-confusion advisories.
The 2026-11-14 lock refresh updates compatible Hono, node-server, fast-copy,
ip-address, Express and qs dependencies. The high-severity audit gate
still applies to the complete installed production graph.

The remaining UUID buffer-boundary advisory
<https://github.com/advisories/GHSA-w5hq-g745-h8pq> affects v3/v5/v6 calls with an
output buffer. The locked package is `node_modules/uuid` (9.0.1); the first fixed
release is 11.1.1, outside Paseo's declared `^9.0.1` range. The integrity-verified
Paseo 0.3.1 server imports only UUID v4 and
calls it without a buffer. The AI SDK provider-utils resource-consumption advisory
<https://github.com/advisories/GHSA-866g-f22w-33x8> remains at
`node_modules/@ai-sdk/provider-utils` (3.0.12) in the pinned production dependency graph.
The first fixed provider-utils release is 3.0.28; AI SDK 5.0.78 and its gateway
pin 3.0.12 exactly, so npm has no automatic fix in the declared graph. The
distributed server JavaScript has no AI SDK import.
These observations cover the reviewed server artifact, not its precompiled web
bundle or future source changes. Recheck both findings by 2026-12-14 or at the
next Paseo update, and retain the audit gate.

- <https://registry.npmjs.org/fast-uri/3.1.9>
- <https://registry.npmjs.org/zod/4.6.7>
