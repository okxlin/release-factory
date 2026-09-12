# Browser runtime dependencies

Both browser variants use this production manifest and npm lock. The application
source is https://github.com/WJZ-P/gemini-skill, initially pinned to
`cde1835067660ad6748393127e56af4e683bfbe7` (gemini-skill 1.1.1, ISC).
Its existing dependencies are updated here without adding another runtime library.

- Puppeteer 25 requires Node >= 22.12 and uses ESM. The application already imports
  `puppeteer-core` as ESM and supplies the browser executable explicitly.
  `puppeteer-compat.mjs` updates its three deprecated `Browser.isConnected()`
  calls to the supported `Browser.connected` property. A changed source layout
  stops the build for review.
  https://github.com/puppeteer/puppeteer/releases/tag/puppeteer-v25.0.0
- Sharp 0.35 requires Node >= 20.9. Its native packages ship prebuilt binaries;
  lifecycle scripts remain disabled, and image build/smoke verify native loading
  and a PNG transformation.
  https://github.com/lovell/sharp/releases/tag/v0.35.0
- Node 24 LTS is selected because Node 20 ended maintenance on 2026-04-30.
  https://github.com/nodejs/Release/blob/main/schedule.json

Update this manifest and regenerate `package-lock.json` with
`npm install --package-lock-only --ignore-scripts`. Both browser builds must pass
the production audit, daemon startup, Puppeteer/CDP, native image-processing, and
profile persistence checks before publication. Build inputs record the resolved
source commit and base image digest for each candidate.

LinuxServer's Nginx fallback is pinned in `configs/components.json`. Nginx
1.30.4 fixes CVE-2026-42533 and CVE-2026-60005; Debian's older ABI-specific
fancyindex module cannot be reused with it. The build compiles fancyindex 0.6.0
from its immutable source against the same Nginx release using `--with-compat`.
Both source archives are checksum-verified, and both BSD-2-Clause license texts
are retained under `/usr/share/doc/nginx-fancyindex`. Desktop and `/files/`
checks exercise the resulting Nginx configuration before publication.

- <https://nginx.org/en/security_advisories.html>
- <https://nginx.org/en/docs/configure.html>
- <https://github.com/aperezdc/ngx-fancyindex/tree/70311f239ec1e88ff79c669d126d08532ddb8554>
