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

The Dockerfiles maintained in this repository run `apt-get upgrade -y` during
build to pick up base image security fixes before installing additional tools.
Browser images hold browser and locale packages during that upgrade so rebuilds
do not silently change the browser version advertised by the image tag or spend
minutes regenerating every locale.
The OpenClaw upstream workflow passes `OPENCLAW_IMAGE_APT_PACKAGES=libgnutls30`
so the upstream Dockerfile refreshes the runtime GnuTLS package before the
vulnerability gate runs.
When the host does not provide `trivy`, the gate uses the pinned
`aquasec/trivy:0.63.0` container image. Set `TRIVY_DOCKER_IMAGE` when bumping
Trivy intentionally.
