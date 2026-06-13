# codex-web-workstation-builder

Docker image builder for the Codex Web Workstation — a browser-accessible Linux development environment with Codex CLI, code-server (VS Code), and ttyd (web terminal).

## Directory Conventions

```
codex-web-workstation-builder/
├── README.md                       # This file
├── configs/
│   └── architectures.sh            # Supported build platforms
├── scripts/
│   └── resolve-build-params.sh     # CI build parameter resolver
└── image/
    ├── .dockerignore
    ├── .env.example                # Runtime env vars reference
    ├── Dockerfile                  # Ubuntu 24.04 + Node 20 + toolchain
    ├── docker-compose.yml          # workstation + caddy services
    ├── Caddyfile                   # HTTPS + Basic Auth + reverse proxy
    ├── scripts/
    │   ├── entrypoint.sh           # Container entrypoint (9 steps)
    │   ├── configure-provider.sh   # Custom provider config generator
    │   ├── healthcheck.sh          # Docker HEALTHCHECK script
    │   ├── doctor.sh               # Full diagnostic
    │   └── smoke-test.sh           # Quick smoke test
    └── config/
        ├── codex/                  # Codex CLI config examples
        └── code-server/            # code-server config example
```

Build-time code (`configs/`, `scripts/`) stays outside the image. Runtime code (`image/scripts/`, `image/config/`) gets baked into the container.

## Build

```bash
cd image
docker compose build
```

The Docker context is `image/`. The Dockerfile expects all COPY paths relative to this directory.

## Runtime Environment

Copy `image/.env.example` to `image/.env` and fill in real values:

```bash
cp image/.env.example image/.env
# Edit .env — at minimum set DOMAIN, CODE_SERVER_PASSWORD, and BASIC_AUTH_HASH
```

Generate Caddy password hash:

```bash
docker run --rm caddy:2 caddy hash-password --plaintext 'your-password'
```

Start:

```bash
cd image
docker compose up -d
```

Services are accessible at:
- `https://DOMAIN/ide/` — code-server (VS Code)
- `https://DOMAIN/terminal/` — ttyd web terminal

## Diagnostics

```bash
# Full diagnostic report
docker compose exec workstation doctor.sh

# Quick smoke test
docker compose exec workstation smoke-test.sh
```

## CI Integration

```bash
source scripts/resolve-build-params.sh \
  --image-repo ghcr.io/org/codex-web-workstation \
  --platforms linux/amd64 \
  --image-tag v1.0.0 \
  --github-output "$GITHUB_OUTPUT"
```

Outputs `image-repo`, `platforms`, `image-tag` for downstream workflow steps.

## What PR Reviewers Should Check

- **Supported platforms** in `configs/architectures.sh` match the PR scope
- **Dockerfile** installs no experimental or unreleased packages
- **entrypoint.sh** does not auto-login, does not print secrets
- **Caddyfile** correctly handles `/ide/*` and `/terminal/*` path stripping
- **healthcheck.sh** covers both code-server (8080) and ttyd (7681)
- **.env.example** documents all runtime environment variables

## Key Design Decisions

- **No Codex App Server** — not started by default; WebSocket transport is experimental
- **No CodexPlusPlus** — targets Codex Desktop App, CDP injection doesn't work in headless Docker
- **No Happy CLI by default** — `ENABLE_HAPPY_REMOTE=false`, docs-only
- **Three-layer auth** — Caddy Basic Auth → code-server password → ttyd credentials
- **Custom provider** — non-interactive `configure-provider.sh`, requires Responses API support
- **Chat Completions-only APIs** — not supported; provider must implement OpenAI Responses API
- **Multi-arch** — MVP `linux/amd64` only; `arm64` planned for later release