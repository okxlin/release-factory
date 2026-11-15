# Image Security Scanning

Published image workflows use `scripts/trivy-image-gate.sh` to scan built images
with Trivy before publishing.

Release and PR checks evaluate raw HIGH/CRITICAL findings against each builder's
`configs/trivy-policy.json`. Protected paths and service packages block both
severities, including findings without a published fix. Outside that protected
scope, the selected profile controls fixable finding thresholds:

| Builder | Profile | Fixable Critical | Ordinary Fixable High | Protected scope |
| --- | --- | ---: | ---: | --- |
| Codex Claude | `workstation` | 0 | Report | code-server, Paseo, proxy binaries and distro Node |
| OpenCode | `workstation` | 0 | Report | Node, baseline and installed userland |
| Gemini browser, both variants | `browser` | 0 | Report | Application, Node, browser, KasmVNC and Nginx |
| OpenClaw | `sandbox` | 0 | Report | Application and Node |
| DeepSeek Harness | `runtime` | 0 | 0 | DSH and Caddy |
| DeepSeek Harness | `workstation` | 0 | Report | DSH and Caddy |

The policy files are authoritative. `Report` means ordinary toolchain HIGH
findings remain visible without a count limit; it does not exempt protected
services. `TRIVY_TIMEOUT` defaults to `20m` for larger images. The script also
retains explicit threshold arguments for callers that do not select a policy;
those legacy defaults are not the release profiles above.

DeepSeek release and PR workflows select the `runtime` or `workstation` profile
from `deepseek-harness-builder/configs/trivy-policy.json`. Both profiles block
HIGH/CRITICAL findings in `/opt/dsh/` and `/usr/bin/caddy`, including findings
without a fix. The production dependency audit and Caddy govulncheck gate also
remain required. Workstation toolchain HIGH findings are reported for periodic
maintenance; fixable CRITICAL findings block both profiles. Unfixed findings
outside the protected paths remain visible and require review.

The policy supports reviewed exceptions only for an exact vulnerability ID,
package, installed version, scanner type, file path, and image profile. Each
entry must include a reason, an advisory reference, and an exclusive UTC expiry
date. Expired entries cannot suppress findings. Exceptions stay in the scan log
and the original JSON report; there is no global CVE ignore list. A policy or
report that cannot be interpreted fails the gate. Reproduce a policy decision
without another image scan with:

```bash
python3 scripts/evaluate-trivy-policy.py \
  --report image.trivy.json \
  --policy deepseek-harness-builder/configs/trivy-policy.json \
  --profile workstation
```

The Dockerfiles maintained in this repository run `apt-get upgrade -y` during
build to pick up base image security fixes before installing additional tools.
Browser images hold browser and locale packages during that upgrade so rebuilds
do not silently change the browser version advertised by the image tag or spend
minutes regenerating every locale.
The OpenClaw upstream workflow passes `OPENCLAW_IMAGE_APT_PACKAGES=libgnutls30`
so the upstream Dockerfile refreshes the runtime GnuTLS package before the
vulnerability gate runs.
When the host does not provide `trivy`, the gate uses the pinned
`aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb`
container image. Set `TRIVY_DOCKER_IMAGE` when bumping
Trivy intentionally.

## Workstation, browser and OpenClaw policies

Codex Claude, OpenCode, both Gemini browser variants and OpenClaw use the same
policy evaluator, with per-builder `configs/trivy-policy.json` files. All block
fixable CRITICAL findings. Ordinary toolchain HIGH findings remain in reports;
protected service paths and exact OS service package names block HIGH/CRITICAL
even without a published fix. OS package protection matches only `os-pkgs`
results, not an unrelated language package with the same name.

Codex protects code-server, Paseo and the three proxy binaries. Browser policy
protects the application, browser packages and Nginx. OpenCode protects the
bundled baseline and installed userland; OpenClaw protects its application.
There are no broad count allowances for fixable browser CRITICAL findings.

OpenCode CI additionally scans a snapshot of the default installed DCP plugin
and userland with `--filesystem`. This does not cover later user upgrades or
fully enumerate libraries compiled into its executable. The baseline notice
records the upstream advisory review and absence of a release SBOM. A zero
userland finding count is not a complete binary dependency audit.

All five release flows build once, test/scan the recorded image ID, verify that
the staged registry manifest has the same config digest, and publish only the
validated platform receipts. PR jobs do not publish. Workstations use native
amd64 and arm64 runners; browsers and OpenClaw remain amd64. Weekly package
cache refreshes and OpenClaw's seven-day maximum build age keep unchanged
application releases eligible for base-image security maintenance.

OpenClaw's existing `http-cache-semantics` 4.2.0 backport checks the original
source digest and tests normal cache reuse plus rejection of unsafe stale
responses. Its two policy exceptions cover only the reviewed npm bundle paths
and advisory; the expiry in `openclaw-builder/configs/trivy-policy.json` remains
binding when no upstream fix is available.

The rebuilt OpenClaw Docker CLI still declares
`github.com/docker/distribution v2.8.3+incompatible`, so
[CVE-2026-85747](https://github.com/advisories/GHSA-685w-q87j-wqw3) remains visible
as MEDIUM. At the pinned CLI source, its outer
[manifest client](https://github.com/docker/cli/blob/5457199aa57c45e990c59c89cab5f02b817238d7/internal/registryclient/fetcher.go)
compares the exact received payload digest with the requested digest for
Schema2, OCI, manifest lists and their children. This is scoped source evidence
of an existing mitigation, not a fix to the generic distribution client or a
binary attack test. No new scanner exception covers this finding; reassess it
when updating that source or dependency.

## DeepSeek Harness Caddy gate

Both DeepSeek Harness workflows additionally run
`deepseek-harness-builder/scripts/check-caddy-vulnerabilities.sh` with
`govulncheck 1.7.0`. Its custom Caddy build:

- patches go-authcrunch `1.5.0` to remove the unused GPG public-key parser;
- uses checksum-verified Caddy `2.11.9`, caddy-security `1.6.2` and
  `cel.dev/cel-go` `0.33.2`; the build applies the reviewed CEL compatibility
  and module-relocation patches where needed, or verifies they are already
  present in newer source;
- retains `golang.org/x/crypto/ssh`;
- records the actual linked package graph in `CADDY_GO_PACKAGES.txt`;
- requires all `golang.org/x/crypto/openpgp` packages to be absent;
- replaces `grpc` with `1.85.0` and pins fixed `klauspost/compress` and `x/text`
  releases from `image/components.lock.json`.

The production Caddy binary is stripped. Go's documented binary-scan limitation
means `govulncheck` can report every vulnerability associated with a required
module when symbols cannot be extracted. Because SSH still requires the
`golang.org/x/crypto` module, the binary scan currently reports
`GO-2026-5932` even though the linked package manifest excludes OpenPGP. The
gate permits `GO-2026-5932` only when OpenPGP packages are absent. It retains a
compatibility rule for the historical gRPC `v1.84.0` database discrepancy:
`GO-2026-6443` is accepted only at that exact version when the linked package
manifest excludes `google.golang.org/grpc/internal/xds/server`. The current
gRPC pin is `v1.85.0`. Both fallbacks require stripped-binary module-level
findings after `go tool nm` confirms symbols are unavailable. A clean scan is
also accepted; unknown findings and unexpected scan results fail. References:

- <https://pkg.go.dev/vuln/GO-2026-6443>
- <https://github.com/grpc/grpc-go/security/advisories/GHSA-2v4p-qf9q-27wj>
- <https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck#hdr-Limitations>

SAML is fixed to reviewed `v0.5.2` for `GO-2026-6909`. The upstream release
rejects missing Subject, SubjectConfirmationData and Conditions, and binds
NameID to the SAML assertion namespace. The build runs regression tests against
the module selected by Caddy, retains its BSD license, and records the version
and test-file hash in `SAML_SECURITY_CHECK.txt`. The image gate requires that
exact version in the binary and the matching receipt before accepting this
finding: the Go advisory currently omits the fixed version and reports all
releases as affected. Other SAML versions, changed receipts and unknown findings
fail. This override remains a manual security pin pending advisory correction.

- <https://github.com/crewjam/saml/compare/v0.5.1...v0.5.2>
- <https://github.com/golang/vulndb/issues/6909>

Source-mode govulncheck also exposes a version-range discrepancy in the Go
database for historical caddy-security advisories. The Go records for
`GO-2024-2549` and `GO-2024-2557` through `GO-2024-2565` contain no fixed event,
while the corresponding GitHub advisories limit the vulnerable versions to
`<=1.1.20`, `<=1.1.23`, or `<=1.0.42`. The image pins caddy-security `1.6.2`.
Trivy evaluates the published package ranges; source-mode module findings alone
do not establish reachability. Examples:

- <https://github.com/advisories/GHSA-xwmv-cx7p-fqfc>
- <https://github.com/advisories/GHSA-vj36-3ccr-6563>
- <https://github.com/advisories/GHSA-c7vf-m394-m4x4>

Changing the fallback scanner pin above or an accepted govulncheck exception
requires a reviewed source update.

## DeepSeek Harness workstation Docker client gate

The workstation image rebuilds Docker CLI, Compose, and Buildx from
checksum-pinned official source archives with the pinned Go release. The build
still raises `go-archive` and `x/mod` to their fixed releases where used.

Buildx retains the upstream `pkg/namesgenerator` import from
`github.com/docker/docker v28.5.2+incompatible`. It no longer copies and patches
that source just to remove the module name from scanner metadata. The build
records a Go package manifest for each binary, with the same `CGO_ENABLED=0`
setting as compilation. Build and workstation smoke checks require the real
main package, reject daemon/authorization packages, and allow the legacy Docker
module to contribute only `pkg/namesgenerator`. Current Compose does not link
any package from that legacy module.

The Workstation policy has two expiring exceptions for this exact Buildx binary
and module version: [CVE-2026-41567](https://github.com/advisories/GHSA-x86f-5xw2-fm2r)
and [CVE-2026-42306](https://github.com/advisories/GHSA-rg2x-37c3-w2rh). Both affect
the daemon's archive handling, which is absent from the linked package graph.
These exceptions do not cover Compose, another module version, other CVEs, or
any host Docker daemon. Updating the component requires checking the new graph
and reviewing any remaining finding.

The workstation Compose contract keeps the host Docker socket disabled by
default by binding `/dev/null` to `/var/run/docker.sock`. The workflow parses
the Compose model and requires `/var/run/docker.sock` to appear as the source
only when `DOCKER_SOCK_SRC=/var/run/docker.sock` is set explicitly. It also
requires the HTTP port to remain bound to host loopback by default.
