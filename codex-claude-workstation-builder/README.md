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
    ├── Dockerfile                  # Ubuntu 24.04 + Node 20 + toolchain
    └── scripts/
        ├── entrypoint.sh           # Container entrypoint (9 steps)
        ├── configure-provider.sh   # Custom provider config generator
        ├── healthcheck.sh          # Docker HEALTHCHECK script
        ├── doctor.sh               # Full diagnostic
        └── smoke-test.sh           # Quick smoke test
```

Build-time code (`configs/`, `scripts/`) stays outside the image. Runtime code (`image/scripts/`) gets baked into the container.

## Build

```bash
docker build -t codex-claude-workstation image/
```

The Docker context is `image/`. The Dockerfile expects all COPY paths relative to this directory.

## Runtime Environment

Copy `image/.env.example` to `.env` and fill in real values:

```bash
# At minimum set PASSWORD
# Pass runtime env vars via docker run -e or your deploy system
```

Start with `docker run`:

```bash
docker run -d -p 8080:8080 \
  -e PASSWORD=change-me \
  -v codex-home:/home/dev \
  codex-claude-workstation
```

Access at `http://host:8080`.

## Diagnostics

```bash
# Full diagnostic report
docker exec <container> doctor.sh

# Quick smoke test
docker exec <container> smoke-test.sh
```

## CI Integration

```bash
source scripts/resolve-build-params.sh \
  --image-repo ghcr.io/org/codex-claude-workstation \
  --platforms linux/amd64 \
  --image-tag v1.0.0 \
  --github-output "$GITHUB_OUTPUT"
```

Outputs `image_repo`, `platforms`, `image_tag` for downstream workflow steps.

## What PR Reviewers Should Check

- **Supported platforms** in `configs/architectures.sh` match the PR scope
- **Dockerfile** installs no experimental or unreleased packages
- **entrypoint.sh** does not auto-login, does not print secrets
- **healthcheck.sh** covers code-server (8080)
- **.env.example** documents all build-time environment variables

## Key Design Decisions

- **No Codex App Server** — not started by default; WebSocket transport is experimental
- **No CodexPlusPlus** — targets Codex Desktop App, CDP injection doesn't work in headless Docker
- **Custom provider** — non-interactive `configure-provider.sh`, requires Responses API support
- **Single-layer auth** — code-server password
- **Custom provider** — non-interactive `configure-provider.sh`, requires Responses API support
- **Chat Completions-only APIs** — not supported; provider must implement OpenAI Responses API
- **Multi-arch** — MVP `linux/amd64` only; `arm64` planned for later release
