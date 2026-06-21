# codex-claude-workstation-builder

Docker image builder for the Codex Claude Workstation — a browser-accessible Linux development environment with Codex CLI and code-server (VS Code).

## Directory Conventions

```
codex-claude-workstation-builder/
├── README.md                       # This file
├── configs/
│   └── architectures.sh            # Supported build platforms
├── scripts/
│   └── resolve-build-params.sh     # CI build parameter resolver
└── image/
    ├── .dockerignore
    ├── .env.example                # Build-time args reference
    └── image/
    ├── .dockerignore
    ├── .env.example                # Build-time args reference
    ├── Dockerfile                  # Ubuntu 24.04 + mainstream AI/dev toolchain
    ├── config/
    │   ├── codex/                  # config.toml + providers.toml examples
    │   ├── code-server/            # config.yaml example
    │   └── supervisord/            # supervisor + clash/sing-box/xray confs
    └── scripts/
        ├── entrypoint.sh           # Container entrypoint (7 steps)
        ├── healthcheck.sh          # Docker HEALTHCHECK script
        ├── doctor.sh               # Full diagnostic
        └── smoke-test.sh           # Quick smoke test

Build-time code (`configs/`, `scripts/`) stays outside the image. Runtime code (`image/scripts/`) gets baked into the container.

## Build

```bash
docker build -t codex-claude-workstation image/
```

The Docker context is `image/`. The Dockerfile expects all COPY paths relative to this directory.

Build-time versions can be overridden with `--build-arg`:

```bash
docker build \
  --build-arg NODE_MAJOR=24 \
  --build-arg NPM_VERSION=latest \
  --build-arg GO_VERSION=latest \
  --build-arg RUST_VERSION=stable \
  --build-arg BUN_VERSION=latest \
  --build-arg DENO_VERSION=latest \
  --build-arg PNPM_VERSION=latest \
  --build-arg YARN_VERSION=stable \
  --build-arg RUFF_VERSION=latest \
  --build-arg BLACK_VERSION=latest \
  --build-arg MYPY_VERSION=latest \
  --build-arg CODE_SERVER_EXTENSIONS="anthropic.claude-code openai.chatgpt ms-python.python charliermarsh.ruff redhat.vscode-yaml tamasfe.even-better-toml editorconfig.editorconfig esbenp.prettier-vscode dbaeumer.vscode-eslint ms-azuretools.vscode-docker ms-ceintl.vscode-language-pack-zh-hans" \
  -t codex-claude-workstation image/
```

## Preinstalled Environment

- AI coding: Codex CLI, Claude Code, oh-my-codex
- Web IDE: code-server with Codex/Claude, Python/Ruff, YAML/TOML, Docker, EditorConfig, Prettier, ESLint, and Chinese language extensions
- JavaScript/TypeScript: Node.js 24, npm latest, pnpm latest and Yarn stable via Corepack, TypeScript 5, Bun latest, Deno latest
- Python: Python 3, venv, pip, pipx, pytest, uv/uvx, ruff, black, mypy, Python build headers
- Systems: Go latest stable, Rust stable, Java 21 LTS, Maven, Docker CLI, Buildx, Compose plugin
- Tooling: git, gh, ripgrep, fd, jq, yq, shellcheck, shfmt, actionlint, pre-commit, yamllint, direnv
- Debugging: curl, httpie, dig, nc, lsof, strace, htop, iotop, nethogs, ncdu
- Proxy cores: mihomo/clash-meta, sing-box, Xray managed by supervisord

## Runtime Environment

Copy `image/.env.example` to `.env` and fill in real values:

```bash
# At minimum set PASSWORD
# Pass runtime env vars via docker run -e or your deploy system
```

Start with `docker run`:

```bash
docker run -d -p 8080:8080 \
  --hostname workstation \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  -e PASSWORD=change-me \
  -e ROOT_PASSWORD=codex2024 \
  -v "$PWD/workspace:/workspace" \
  -v codex-home:/home/dev \
  ghcr.io/okxlin/codex-claude-workstation:latest
```

Run as `dev` user by default. Use `su - root` + `ROOT_PASSWORD` for root.
When `/var/run/docker.sock` is mounted, startup adds `dev` to the socket GID so `docker` works without switching users.
Mount the Docker socket only when needed:

```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

This gives tools inside the container host Docker control. Keep it disabled when using third-party LLM providers unless that access is explicitly required.
The 1Panel app packaging may mount `/var/run/docker.sock` by default for convenience; leave its `DOCKER_SOCK_SRC` field empty to disable it.

Access at `http://host:8080`.

The `/home/dev` volume is intended for user state and user-installed tools. Runtime defaults keep these paths persistent:

- npm global installs: `npm install -g <pkg>` -> `/home/dev/.local`
- pipx/uv tools and user binaries: `/home/dev/.local`
- Go user installs: `go install ...` -> `/home/dev/go/bin`
- Rust user installs: `cargo install ...` -> `/home/dev/.cargo/bin`
- Bun/Deno user installs: `/home/dev/.bun` and `/home/dev/.deno`
- Codex/Claude/code-server state: `/home/dev/.codex`, `/home/dev/.claude`, `/home/dev/.config`, `/home/dev/.local/share/code-server`

Codex sandbox requires unprivileged user namespaces on the host:

```bash
sudo sysctl -w kernel.unprivileged_userns_clone=1
sudo sysctl -w user.max_user_namespaces=15000
```

Some Docker hosts still block the runtime user namespace probe even when those sysctls look correct. `doctor.sh` reports that as a warning by default because it is a host/container runtime restriction rather than a missing image dependency. Set `CODEX_SANDBOX_STRICT=true` when you want `doctor.sh` to fail on that condition.

## Diagnostics

```bash
# Full diagnostic report
docker exec <container> doctor.sh

# Quick smoke test
docker exec <container> smoke-test.sh
```

## CI Integration

The GitHub workflow `.github/workflows/build-codex-claude-workstation.yml` can be run manually and also refreshes the image weekly on Sunday at 03:17 UTC.

Default release policy:

- Scheduled builds publish only `YYYYMMDD` and `latest`.
- Manual builds use the provided tag, or `YYYYMMDD` when the tag is left empty.
- `sha-*` tags are intentionally not published by default to avoid long-lived tag sprawl.
- The workflow builds a local `linux/amd64` test image first, runs `healthcheck.sh`, `doctor.sh`, and `smoke-test.sh`, then builds and pushes the requested platforms after tests pass.
- The CI test container intentionally does not mount `/var/run/docker.sock`, and GHCR login happens only after tests pass.
- Manual workflow inputs are validated before they are written to GitHub Actions outputs.
- BuildKit cache uses GitHub Actions cache with `mode=min` to reduce cache storage pressure.

```bash
bash scripts/resolve-build-params.sh \
  --image-repo ghcr.io/org/codex-claude-workstation \
  --platforms linux/amd64,linux/arm64 \
  --image-tag v1.0.0 \
  --github-output "$GITHUB_OUTPUT"
```

Outputs `image_repo`, `platforms`, `image_tag` for downstream workflow steps.

For GHCR storage, tags themselves are small; the real cost is retained image versions and changed layers. Public GHCR packages are generally less constrained, while private packages count against GitHub Packages storage. For private or quota-sensitive deployments, keep a small retention window such as 12-26 weekly date tags and prune older package versions outside the build workflow.

## What PR Reviewers Should Check

- **Supported platforms** in `configs/architectures.sh` match the PR scope
- **Dockerfile** installs no experimental or unreleased packages
- **entrypoint.sh** does not auto-login, does not print secrets
- **healthcheck.sh** covers code-server (8080)
- **.env.example** documents all build-time environment variables

## Key Design Decisions

- **No Codex App Server** — not started by default; WebSocket transport is experimental
- **Single-layer auth** — code-server password
- **Chat Completions-only APIs** — not supported; provider must implement OpenAI Responses API
- **Multi-arch** — `linux/amd64` and `linux/arm64` are supported; CI smoke tests `linux/amd64` before publishing the multi-platform image
