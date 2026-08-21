# Image Security Scanning

Published image workflows use `scripts/trivy-image-gate.sh` to scan built images
with Trivy before publishing.

The gate counts only HIGH and CRITICAL vulnerabilities. It fails the workflow
when fixable vulnerabilities exceed the configured thresholds:

- `TRIVY_MAX_FIXABLE_CRITICAL`: defaults to `0`
- `TRIVY_MAX_FIXABLE_HIGH`: defaults to a high compatibility value and should be
  set per workflow
- `TRIVY_TIMEOUT`: defaults to `20m` so larger workstation images can complete
  analysis instead of failing on Trivy's shorter default timeout

Current workflow thresholds:

| Workflow | Image | Fixable Critical | Fixable High | Notes |
| --- | --- | ---: | ---: | --- |
| `build-codex-claude-workstation.yml` | local smoke-test image | 0 | 150 | Workstation image keeps development toolchains, so HIGH noise is expected. |
| `build-opencode-workstation.yml` | local smoke-test image | 0 | 100 | Workstation image keeps development toolchains, so HIGH noise is expected. |
| `build-gemini-skill-browser.yml` | local Kasm image | 0 | 30 | Preferred browser variant; should stay relatively clean. |
| `build-gemini-skill-browser-linuxserver.yml` | local LinuxServer image | 30 | 450 | Compatibility threshold for the noisier LinuxServer base. |
| `openclaw-upstream-docker.yml` | local upstream image | 0 | 40 | Scans the upstream checkout before publishing to GHCR. |
| `build-deepseek-harness.yml` | amd64 and arm64 runtime images | 0 | 0 | Authentication image has no runtime toolchain allowance; both architectures must remain free of fixable HIGH/CRITICAL findings. |
| `build-deepseek-harness-workstation.yml` | amd64 and arm64 workstation images | 0 | 0 | Full compiler and language toolchains are retained, but fixable HIGH/CRITICAL findings are still not accepted. |

The Dockerfiles maintained in this repository run `apt-get upgrade -y` during
build to pick up base image security fixes before installing additional tools.
Browser images hold browser and locale packages during that upgrade so rebuilds
do not silently change the browser version advertised by the image tag or spend
minutes regenerating every locale.
The OpenClaw upstream workflow passes `OPENCLAW_IMAGE_APT_PACKAGES=libgnutls30`
so the upstream Dockerfile refreshes the runtime GnuTLS package before the
vulnerability gate runs.
When the host does not provide `trivy`, the gate uses the pinned
`aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969`
container image. Set `TRIVY_DOCKER_IMAGE` when bumping
Trivy intentionally.

## DeepSeek Harness Caddy gate

Both DeepSeek Harness workflows additionally run
`deepseek-harness-builder/scripts/check-caddy-vulnerabilities.sh` with
`govulncheck 1.7.0`. Its custom Caddy build:

- patches go-authcrunch `1.1.41` to remove the unused GPG public-key parser;
- applies Caddy upstream commit `b2693fb`'s two-line CEL compatibility fix to
  checksum-verified Caddy `2.11.4` source, then pins `cel-go` `0.30.0` for
  `GO-2026-6094`;
- retains `golang.org/x/crypto/ssh`;
- records the actual linked package graph in `CADDY_GO_PACKAGES.txt`;
- requires all `golang.org/x/crypto/openpgp` packages to be absent;
- replaces `grpc`, `klauspost/compress`, and `x/text` with fixed releases.

The production Caddy binary is stripped. Go's documented binary-scan limitation
means `govulncheck` can report every vulnerability associated with a required
module when symbols cannot be extracted. Because SSH still requires the
`golang.org/x/crypto` module, the binary scan currently reports
`GO-2026-5932` even though the linked package manifest excludes OpenPGP. The
gate permits that ID only when it is the sole finding and `go tool nm` confirms
that symbols are unavailable. A clean scan is also accepted; every other result
fails. Reference:
<https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck#hdr-Limitations>.

Source-mode govulncheck also exposes a version-range discrepancy in the Go
database for historical caddy-security advisories. The Go records for
`GO-2024-2549` and `GO-2024-2557` through `GO-2024-2565` contain no fixed event,
while the corresponding GitHub advisories limit the vulnerable versions to
`<=1.1.20`, `<=1.1.23`, or `<=1.0.42`. The image pins caddy-security `1.1.64`.
Trivy evaluates the published package ranges and currently reports zero affected
caddy-security findings. Examples:

- <https://github.com/advisories/GHSA-xwmv-cx7p-fqfc>
- <https://github.com/advisories/GHSA-vj36-3ccr-6563>
- <https://github.com/advisories/GHSA-c7vf-m394-m4x4>

The workflow pins its fallback scanner to
`aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969`;
changing that pin or the accepted govulncheck exception requires a reviewed source
update.

## DeepSeek Harness workstation Docker client gate

The workstation image rebuilds Docker CLI `29.7.2`, Compose `5.5.0`, and
Buildx `0.36.1` from checksum-pinned official source archives with Go `1.27.0`.
The upstream prebuilt binaries were compiled with Go `1.26.5`, which is inside
the affected ranges for `CVE-2026-39821` and `CVE-2026-46600`.

Buildx uses `github.com/docker/docker v28.5.2+incompatible` only for the frozen
`pkg/namesgenerator` package. Trivy consequently attributes the daemon-only
AuthZ issue `CVE-2026-34040` to both Buildx and Compose even though neither
client links the vulnerable authorization package. The build copies that exact
vendored name-generator package into Buildx, changes the import to the local
package, removes the legacy daemon module from the Buildx and Compose module
graphs, and verifies all three resulting binaries with `go version -m`.

Buildx `0.36.1` otherwise selects `github.com/moby/go-archive` `0.2.1`.
The build explicitly raises it to `0.3.3` (the current release; `0.3.0` and
later fix `CVE-2026-17106`) and verifies the linked Buildx binary metadata
before the zero-fixable Trivy gate runs.

Buildx `0.36.1` and Compose `5.5.0` also select `golang.org/x/mod` `0.38.0`,
which is affected by Go advisories `GO-2026-6179` and `GO-2026-6180`
([CVE-2026-56865](https://pkg.go.dev/vuln/GO-2026-6179),
[CVE-2026-56864](https://pkg.go.dev/vuln/GO-2026-6180)). The build raises the
module to the fixed `0.40.0` release in both client module graphs and verifies
the selected version in the resulting Buildx and Compose binaries.

This is dependency minimization, not a scanner allowlist: the zero-fixable
HIGH/CRITICAL threshold remains unchanged. Advisory:
<https://github.com/moby/moby/security/advisories/GHSA-x744-4wpc-v9h2>.

The workstation Compose contract keeps the host Docker socket disabled by
default by binding `/dev/null` to `/var/run/docker.sock`. The workflow parses
the Compose model and requires `/var/run/docker.sock` to appear as the source
only when `DOCKER_SOCK_SRC=/var/run/docker.sock` is set explicitly. It also
requires the HTTP port to remain bound to host loopback by default.
