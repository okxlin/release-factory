# Reviewed OpenClaw MCP HTTP fixtures

These unmodified TypeScript files are copied from the official OpenClaw repository:

- [v2026.11.3, commit 847611dcaa3bf0e2783335f961dd1fd0580e4d9f](https://github.com/openclaw/openclaw/tree/847611dcaa3bf0e2783335f961dd1fd0580e4d9f).
- [v2026.11.6, commit 06afb10d3272cc9deaf38ca6a3b7b839d5935638](https://github.com/openclaw/openclaw/tree/06afb10d3272cc9deaf38ca6a3b7b839d5935638).

`sources.json` records every source path and SHA-256. The regression checks the
hash before compiling a temporary copy, then exercises the actual MCP HTTP/SSE
redirect loop and the newer provider guard. CI needs no raw GitHub downloads for
these sources. Test-only transport admission and lifecycle stubs allow loopback;
they do not establish the production SSRF policy or real dispatcher pooling.

The sources are MIT licensed, copyright 2026 OpenClaw Foundation. The unchanged
upstream [LICENSE](LICENSE) permits commercial use and redistribution with the
copyright and license notice retained. It was retrieved from the fixed v2026.11.6
commit and has SHA-256
`9efd316ecf1c4c60f6fd5d26433142fff2b6794d7d328e9bc6179b29bf9c82a4`.
