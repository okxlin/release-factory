# Release Factory

[简体中文](README.md) | **English**

Release Factory maintains build and publication pipelines for 1Panel offline packages, AI development workstations, browser environments, and sandbox images. Each project has an isolated builder or patch entry point, while GitHub Actions handles input validation, testing, security gates, and publication.

> Artifacts from this repository are community-maintained builds. Check the upstream version, image tag, runtime permissions, and project-specific documentation before use.

## Build Matrix

| Project | Published artifact | Supported architectures | Trigger | Entry points |
| --- | --- | --- | --- | --- |
| 1Panel offline package | `.tar.gz` and `.sha256` files in a GitHub Release | `amd64`, `arm64`, `armv7`, `ppc64le`, `s390x` | Manual | [Builder](1panel-builder/) · [Workflow](.github/workflows/build-1panel.yml) · [Run](https://github.com/okxlin/release-factory/actions/workflows/build-1panel.yml) |
| Codex Claude Workstation | `ghcr.io/okxlin/codex-claude-workstation` | `linux/amd64`, `linux/arm64` | Manual, Sundays at 03:17 UTC | [Documentation](codex-claude-workstation-builder/README.md) · [Workflow](.github/workflows/build-codex-claude-workstation.yml) · [Run](https://github.com/okxlin/release-factory/actions/workflows/build-codex-claude-workstation.yml) |
| DeepSeek Harness Runtime | `ghcr.io/okxlin/deepseek-harness`, `moelin/deepseek-harness` | `linux/amd64`, `linux/arm64` | Manual, Sundays at 03:43 UTC | [Documentation](deepseek-harness-builder/README.md) · [Workflow](.github/workflows/build-deepseek-harness.yml) · [Run](https://github.com/okxlin/release-factory/actions/workflows/build-deepseek-harness.yml) |
| DeepSeek Harness Workstation | Shares the Runtime repositories and uses `-workstation` tags | `linux/amd64`, `linux/arm64` | Manual, Sundays at 04:13 UTC | [Documentation](deepseek-harness-builder/README.md) · [Compose](deepseek-harness-builder/compose.workstation.yml) · [Workflow](.github/workflows/build-deepseek-harness-workstation.yml) · [Run](https://github.com/okxlin/release-factory/actions/workflows/build-deepseek-harness-workstation.yml) |
| Gemini Skill Browser (Kasm) | `ghcr.io/okxlin/gemini-skill-browser` | `linux/amd64` | Manual | [Documentation](gemini-skill-browser-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser.yml) · [Run](https://github.com/okxlin/release-factory/actions/workflows/build-gemini-skill-browser.yml) |
| Gemini Skill Browser (LinuxServer) | Shares the Kasm repository and uses `-linuxserver` tags | `linux/amd64` | Manual | [Documentation](gemini-skill-browser-linuxserver-builder/README.md) · [Workflow](.github/workflows/build-gemini-skill-browser-linuxserver.yml) · [Run](https://github.com/okxlin/release-factory/actions/workflows/build-gemini-skill-browser-linuxserver.yml) |
| OpenCode Workstation | `ghcr.io/okxlin/opencode-workstation` | `linux/amd64`, `linux/arm64` | Manual | [Documentation](opencode-workstation-builder/README.md) · [Workflow](.github/workflows/build-opencode-workstation.yml) · [Run](https://github.com/okxlin/release-factory/actions/workflows/build-opencode-workstation.yml) |
| OpenClaw Sandbox | `ghcr.io/okxlin/openclaw-sandbox` | Workflow runner default, currently `linux/amd64` | Manual, daily at 02:00 UTC | [Workflow](.github/workflows/openclaw-upstream-docker.yml) · [Hardening patch](patches/openclaw-runtime-hardening.patch) · [Run](https://github.com/okxlin/release-factory/actions/workflows/openclaw-upstream-docker.yml) |

## Quick Start

### Pull an image

```bash
docker pull ghcr.io/okxlin/codex-claude-workstation:latest
docker pull ghcr.io/okxlin/deepseek-harness:latest
docker pull ghcr.io/okxlin/deepseek-harness:workstation
docker pull moelin/deepseek-harness:workstation
docker pull ghcr.io/okxlin/opencode-workstation:latest
docker pull ghcr.io/okxlin/openclaw-sandbox:latest
```

Ports, authentication, persistent paths, and optional Docker Socket permissions differ between images. Read the corresponding project documentation in the matrix before starting a container, and do not expose example passwords or privileged mounts to the public Internet.

### Run a workflow manually

Choose a workflow on the [Actions](https://github.com/okxlin/release-factory/actions) page and select **Run workflow**, or use GitHub CLI:

```bash
gh workflow run build-deepseek-harness.yml \
  --repo okxlin/release-factory \
  --ref main \
  -f dsh_version=0.1.0-rc.6 \
  -f platforms=linux/amd64,linux/arm64 \
  -f push_latest=true

gh workflow run build-1panel.yml \
  --repo okxlin/release-factory \
  --ref main \
  -f version=v2.1.3
```

DeepSeek Harness `image_tag` follows `dsh_version` by default; leave it empty to use the currently resolved npm version.

DeepSeek Harness publishes to both GHCR and Docker Hub. Before running either DeepSeek workflow, configure `DOCKERHUB_USERNAME` as a repository variable or secret and `DOCKERHUB_TOKEN` as a repository secret. The token is used only for registry login and is not passed to the image build context.

## Tags and Publication Policy

| Project | Primary version tag | Optional floating tag |
| --- | --- | --- |
| 1Panel | Release: `1panel-<actor>-<version>`; file: `1panel-<actor>-<version>-<arch>.tar.gz` | Not applicable |
| Codex Claude Workstation | UTC date `YYYYMMDD` | `latest`; enabled by default for manual runs and always updated by scheduled runs |
| DeepSeek Harness Runtime | Resolved `@deepseek-ai/dsh` version (`<DSH_VERSION>`) | `latest`; enabled by default for manual runs and always updated by scheduled runs |
| DeepSeek Harness Workstation | `<DSH_VERSION>-workstation`; the suffix is appended when a manual tag omits it | `workstation`; enabled by default for manual runs and always updated by scheduled runs |
| Gemini Skill Browser (Kasm) | `<browser_base_tag>-kasm` | `latest-kasm`, published only when explicitly enabled |
| Gemini Skill Browser (LinuxServer) | `<browser_base_tag>-linuxserver` | `latest-linuxserver`, published only when explicitly enabled |
| OpenCode Workstation | `latest` or a manually supplied tag | Can explicitly add the `latest` alias |
| OpenClaw Sandbox | `<upstream_release>-sandbox` | `latest` |

Except for DeepSeek Harness, container workflows publish only to the current repository owner's GHCR namespace by default. The 1Panel workflow does not publish a container image; it adds each architecture's installer and SHA-256 checksum to one GitHub Release.

## Quality and Security Gates

Depending on the project, publication pipelines use the following checks:

- Validate image repository names, tags, target platforms, and manual inputs, rejecting unsupported architectures.
- Build a local test image before publication and run project-specific container, authentication, WebSocket, toolchain, or runtime smoke tests.
- Use the [Trivy gate](SECURITY_SCAN.md) to count fixable HIGH/CRITICAL vulnerabilities. Thresholds are configured per image type and are not uniformly zero.
- Run additional pnpm audit, Caddy dependency-graph checks, `govulncheck`, dual-architecture smoke tests, and the Workstation Compose permission contract for DeepSeek Harness.
- Validate the Paseo supply-chain record and runtime contract for Codex Workstation. OpenClaw validates the upstream release tag, applies the repository hardening patch, and pins critical base-image digests.

A passing security scan does not mean that an image has no vulnerabilities. The current Trivy gate counts only HIGH/CRITICAL vulnerabilities with a fixed version; users must still assess image provenance, privileges, network exposure, and deployment-specific risk.

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
| [`patches/`](patches/) | Reviewed upstream build or runtime patches |
| [`scripts/`](scripts/) | Shared CI gate scripts |
| [`SECURITY_SCAN.md`](SECURITY_SCAN.md) | Vulnerability thresholds, the DeepSeek Caddy exception, and Docker client dependency notes |

## Contributing

- Branch from the latest `main` and keep each pull request focused on one build target or one documentation concern.
- When changing platforms, tags, or publication policy, update the architecture configuration, parameter resolver, workflow, and project README together.
- New or updated images should include a reproducible local build, project-level smoke tests, and a pre-publication security gate.
- Pin important upstream versions, source archives, or base-image digests, and preserve provenance, license, and required patch records.
- Never commit tokens, passwords, private keys, or real `.env` files. Keep registry credentials in GitHub Actions Variables/Secrets.

Before opening a pull request, review the change scope, Markdown or script formatting, relevant test results, and whether workflow permissions remain minimal.
