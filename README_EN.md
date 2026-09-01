# Release Factory

[简体中文](README.md) | **English**

Release Factory maintains build and publication pipelines for 1Panel offline packages, AI development workstations, browser environments, and sandbox images. Each project has an isolated builder or patch entry point, while GitHub Actions handles input validation, testing, security gates, and publication.

> This repository produces community-maintained builds, not official upstream releases. Check the project documentation, image tag, persistent paths, runtime permissions, and network exposure before use.

## Project Index

| Project | Artifact | Architectures | Documentation and workflow |
| --- | --- | --- | --- |
| 1Panel offline package | `.tar.gz` and `.sha256` files in a GitHub Release | `amd64`, `arm64`, `armv7`, `ppc64le`, `s390x` | [Builder](1panel-builder/) · [Workflow](.github/workflows/build-1panel.yml) |
| Codex Claude Workstation | `ghcr.io/okxlin/codex-claude-workstation` | `linux/amd64`, `linux/arm64` | [Documentation](codex-claude-workstation-builder/README.md) · [Workflow](.github/workflows/build-codex-claude-workstation.yml) |
| DeepSeek Harness Runtime | `ghcr.io/okxlin/deepseek-harness`; Docker Hub when configured | `linux/amd64`, `linux/arm64` | [Documentation](deepseek-harness-builder/README.md) · [Workflow](.github/workflows/build-deepseek-harness.yml) |
| DeepSeek Harness Workstation | Shares the Runtime repository and uses `-workstation` tags | `linux/amd64`, `linux/arm64` | [Documentation](deepseek-harness-builder/README.md) · [Compose](deepseek-harness-builder/compose.workstation.yml) · [Workflow](.github/workflows/build-deepseek-harness-workstation.yml) |
| Gemini Skill Browser (Kasm) | `ghcr.io/okxlin/gemini-skill-browser` | `linux/amd64` | [Documentation](gemini-skill-browser-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser.yml) |
| Gemini Skill Browser (LinuxServer) | Shares the Kasm repository and uses `-linuxserver` tags | `linux/amd64` | [Documentation](gemini-skill-browser-linuxserver-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser-linuxserver.yml) |
| OpenCode Workstation | `ghcr.io/okxlin/opencode-workstation` | `linux/amd64`, `linux/arm64` | [Documentation](opencode-workstation-builder/README.md) · [Workflow](.github/workflows/build-opencode-workstation.yml) |
| OpenClaw Sandbox | `ghcr.io/okxlin/openclaw-sandbox` | GitHub Actions runner default | [Workflow](.github/workflows/openclaw-upstream-docker.yml) · [Hardening script](scripts/apply-openclaw-runtime-hardening.sh) |

The root README is a navigation map. Project READMEs, Compose files, and workflows are authoritative for image startup, authentication, persistence, toolchains, upgrades, and permission boundaries.

## Quick Start

### Use published images

```bash
docker pull ghcr.io/okxlin/codex-claude-workstation:latest
docker pull ghcr.io/okxlin/deepseek-harness:latest
docker pull ghcr.io/okxlin/deepseek-harness:workstation
docker pull ghcr.io/okxlin/opencode-workstation:latest
docker pull ghcr.io/okxlin/openclaw-sandbox:latest

# Gemini aliases are published only when explicitly enabled:
# docker pull ghcr.io/okxlin/gemini-skill-browser:latest-kasm
# docker pull ghcr.io/okxlin/gemini-skill-browser:latest-linuxserver
```

DeepSeek Harness is also published to the Docker Hub namespace configured through the GitHub Actions repository Variable or Secret `DOCKERHUB_USERNAME`. Ports, authentication, persistent paths, and optional Docker Socket permissions differ between images. Read the corresponding project documentation before starting a container, and do not expose example passwords or privileged mounts to the public Internet.

### Trigger a build manually

Choose a workflow on the [Actions](https://github.com/okxlin/release-factory/actions) page and select **Run workflow**, or use GitHub CLI:

```bash
gh workflow run build-deepseek-harness.yml \
  --repo okxlin/release-factory \
  --ref main \
  -f platforms=linux/amd64,linux/arm64 \
  -f push_latest=true
```

The example omits DeepSeek Harness `dsh_version` and `image_tag`, so the workflow resolves the current npm version and uses the corresponding version tag. Check each workflow for its input schema and defaults before publishing; required repository Variables, Secrets, and registry access must already be configured.

## Tags and Publication

| Project | Version tag | Floating tag |
| --- | --- | --- |
| 1Panel | `1panel-<actor>-<version>`; file: `1panel-<actor>-<version>-<arch>.tar.gz` | Not applicable |
| Codex Claude Workstation | UTC date `YYYYMMDD` | `latest` |
| DeepSeek Harness Runtime | Resolved `@deepseek-ai/dsh` version `<DSH_VERSION>` | `latest` |
| DeepSeek Harness Workstation | `<DSH_VERSION>-workstation` | `workstation` |
| Gemini Skill Browser (Kasm) | `<browser_base_tag>-kasm` | `latest-kasm`, published only when explicitly enabled |
| Gemini Skill Browser (LinuxServer) | `<browser_base_tag>-linuxserver` | `latest-linuxserver`, published only when explicitly enabled |
| OpenCode Workstation | A manually supplied tag or `latest` | Can explicitly add `latest` |
| OpenClaw Sandbox | `<upstream_release>-sandbox` | `latest` |

Except for DeepSeek Harness, container workflows publish only to the current repository owner's GHCR namespace by default. DeepSeek Harness requires Docker Hub credentials as well; the 1Panel workflow does not publish a container image and instead adds each architecture's installer and SHA-256 checksum to a GitHub Release.

## Verification and Security

Publication pipelines apply the following gates as appropriate for each project:

- Validate image repository names, tags, target platforms, and manual inputs, rejecting unsupported architectures.
- Build a local test image before publication and run project-specific container, authentication, WebSocket, toolchain, or runtime smoke tests.
- Use the [Trivy gate](SECURITY_SCAN.md) to count fixable HIGH/CRITICAL vulnerabilities. Thresholds are configured per image type and are not uniformly zero.
- Run additional pnpm audit, Caddy dependency-graph checks, `govulncheck`, dual-architecture smoke tests, and the Workstation Compose permission contract for DeepSeek Harness.
- Validate the Paseo supply-chain record and runtime contract for Codex Workstation. OpenClaw validates the upstream Release tag, applies the repository hardening patch, and pins critical base-image digests.

A passing security scan does not mean that an image has no vulnerabilities. The gates primarily constrain HIGH/CRITICAL issues with an available fix; users must still assess image provenance, runtime privileges, network exposure, and deployment-specific risk.

## Sources of Truth

| Information | Authoritative source |
| --- | --- |
| Build inputs, platforms, and publication tags | [`.github/workflows/`](.github/workflows/) and [`scripts/`](scripts/) |
| Image dependencies and upstream pins | Each project's Dockerfile, package manifest, and lockfile |
| Runtime, persistence, and permission behavior | The corresponding project README, Compose files, and image entrypoint |
| Vulnerability thresholds and security exceptions | [`SECURITY_SCAN.md`](SECURITY_SCAN.md) and [`scripts/trivy-image-gate.sh`](scripts/trivy-image-gate.sh) |

When the root README differs from a project README or workflow, follow the source closest to the build or runtime boundary. The root README intentionally does not duplicate current component versions or dynamic vulnerability conclusions.

## Repository Layout

| Path | Purpose |
| --- | --- |
| [`.github/workflows/`](.github/workflows/) | Build, test, and publication workflows |
| [`1panel-builder/`](1panel-builder/) | Preparation, build, and packaging scripts for multi-architecture 1Panel offline installers |
| [`codex-claude-workstation-builder/`](codex-claude-workstation-builder/) | Codex, Claude Code, code-server, and Paseo workstation image |
| [`deepseek-harness-builder/`](deepseek-harness-builder/) | DeepSeek Harness Runtime/Workstation, Caddy authentication, and Compose configuration |
| [`gemini-skill-browser-builder/`](gemini-skill-browser-builder/) | Kasm Edge based Gemini Skill Browser |
| [`gemini-skill-browser-linuxserver-builder/`](gemini-skill-browser-linuxserver-builder/) | LinuxServer Chrome based Gemini Skill Browser |
| [`opencode-workstation-builder/`](opencode-workstation-builder/) | Persistent OpenCode development workstation |
| [`scripts/`](scripts/) | Shared CI gate scripts |
| [`SECURITY_SCAN.md`](SECURITY_SCAN.md) | Vulnerability thresholds, security exceptions, and client dependency notes |

## Contributing

- Branch from the latest `main` and keep each pull request focused on one build target or one documentation concern.
- When changing platforms, tags, or publication policy, update the corresponding workflow, parameter resolver, test contract, and project README together.
- New or updated images should include a reproducible local build, project-level smoke tests, and a pre-publication security gate.
- Pin important upstream versions, source archives, or base-image digests, and preserve provenance, license, and required patch records.
- Never commit tokens, passwords, private keys, or real `.env` files. Keep registry credentials in GitHub Actions Variables/Secrets.

Before opening a pull request, review the change scope, Markdown or script formatting, relevant test results, and whether workflow permissions remain minimal.
