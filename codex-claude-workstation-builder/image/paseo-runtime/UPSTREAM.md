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

Security overrides pin Zod to 4.6.6 and keep body-parser aligned with its
consumer: Paseo's Express 4 uses 1.20.9, while the MCP SDK's Express 5 uses
2.4.0. The existing fast-uri pin remains in place. The high-severity audit gate
still applies to the complete installed production graph.
