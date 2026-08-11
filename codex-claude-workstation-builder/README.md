# codex-claude-workstation-builder

Docker image builder for the Codex Claude Workstation — a browser-accessible Linux development environment with Codex CLI, code-server (VS Code), and a hardened Paseo endpoint for mobile sessions.

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
    ├── Dockerfile                  # Ubuntu 24.04 + mainstream AI/dev toolchain
    ├── config/
    │   ├── codex/                  # config.toml + providers.toml examples
    │   ├── code-server/            # config.yaml example
    │   └── supervisord/            # supervisor + clash/sing-box/xray confs
    ├── paseo-runtime/              # audited npm lock, license, and source notice
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
  --build-arg NPM_VERSION=12.0.1 \
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

- AI coding: Codex CLI, Claude Code, oh-my-codex, Paseo 0.3.1 mobile/web control
- Web IDE: code-server with Codex/Claude, Python/Ruff, YAML/TOML, Docker, EditorConfig, Prettier, ESLint, and Chinese language extensions
- JavaScript/TypeScript: Node.js 24, npm 12.0.1, pnpm latest and Yarn stable via Corepack, TypeScript 5, Bun latest, Deno latest
- Python: Python 3, venv, pip, pipx, pytest, uv/uvx, ruff, black, mypy, Python build headers
- Systems: Go latest stable, Rust stable, Java 21 LTS, Maven, Docker CLI, Buildx, Compose plugin
- Tooling: git, gh, ripgrep, fd, jq, yq, shellcheck, shfmt, actionlint, pre-commit, yamllint, direnv
- Debugging: curl, httpie, dig, nc, lsof, strace, htop, iotop, nethogs, ncdu
- Proxy cores: mihomo/clash-meta, sing-box, Xray managed by supervisord

## Runtime Environment

Copy `image/.env.example` to `.env` and fill in real values:

```bash
# At minimum set PASSWORD and PASEO_PASSWORD
# Pass runtime env vars via docker run -e or your deploy system
```

Start with `docker run`:

```bash
docker run -d \
  -p 8080:8080 \
  -p 127.0.0.1:6767:6767 \
  --hostname workstation \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  -e PASSWORD=change-me \
  -e PASEO_PASSWORD="$(openssl rand -hex 24)" \
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

Access code-server at `http://host:8080`.

## Paseo Mobile Access

Paseo listens directly on container port `6767`; the image does not bundle a web proxy. Relay, voice mode, dictation, and automatic local speech-model downloads are disabled.

Publish `6767` on the host loopback address by default, then terminate public TLS in the host OpenResty/Nginx instance. Because Paseo retains localhost Service Proxy routing, the public proxy should fix the upstream Host and Origin instead of forwarding arbitrary client values. The HTML injection keeps the browser WebSocket pointed at the public HTTPS domain:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 443 ssl http2;
    server_name paseo.example.com;

    location / {
        proxy_pass http://127.0.0.1:6767;
        proxy_http_version 1.1;
        proxy_set_header Host paseo.internal;
        proxy_set_header X-Forwarded-Host paseo.internal;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Origin http://paseo.internal;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Accept-Encoding "";
        proxy_hide_header X-Powered-By;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        sub_filter_once on;
        sub_filter '</head>' '<script>window.__PASEO_INITIAL_DAEMON_CONNECTION__={listen:window.location.host,useTls:window.location.protocol==="https:",label:"Codex Workstation"};</script></head>';
    }
}
```

Open `https://paseo.example.com` on the phone and enter `PASEO_PASSWORD`. [Paseo inserts this value directly into the browser WebSocket subprotocol](https://github.com/getpaseo/paseo/blob/bfec7ac3adc5e8835e873ee75c7b325af6c7a8c3/packages/client/src/daemon-client.ts#L1255), so it cannot be an arbitrary password string. The simplest safe format is a unique 40-128 character hexadecimal value; generate one with `openssl rand -hex 24`. Spaces and HTTP separator characters such as `@`, `:`, `/`, `=`, and commas are not browser-compatible here. This follows the WebSocket subprotocol and HTTP token grammars in [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html#section-11.3.4) and [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.2).

For an existing deployment that does not yet define `PASEO_PASSWORD`, the entrypoint falls back to the existing code-server `PASSWORD` without rewriting it. If that legacy password is not WebSocket-token-safe, code-server remains available but the Paseo health check reports unhealthy and mobile sessions cannot connect until a separate compatible `PASEO_PASSWORD` is set.

Paseo password authentication has no MFA, RBAC, or per-device token isolation, so HTTPS and a strong unique password remain mandatory. Binding the host port to `0.0.0.0` is supported for operators who explicitly need it, but it exposes a path that bypasses the fixed-Host/TLS reverse proxy; keep the default `127.0.0.1` on public servers. If the 1Panel/OpenResty reverse proxy shares `1panel-network`, it may instead target the actual workstation container name shown by 1Panel on port `6767`; do not assume a fixed container DNS name.

The `/home/dev` volume is intended for user state and user-installed tools. Runtime defaults keep these paths persistent:

- npm global installs: `npm install -g <pkg>` -> `/home/dev/.local`
- pipx/uv tools and user binaries: `/home/dev/.local`
- Go user installs: `go install ...` -> `/home/dev/go/bin`
- Rust user installs: `cargo install ...` -> `/home/dev/.cargo/bin`
- Bun/Deno user installs: `/home/dev/.bun` and `/home/dev/.deno`
- Codex/Claude/code-server state: `/home/dev/.codex`, `/home/dev/.claude`, `/home/dev/.config`, `/home/dev/.local/share/code-server`
- Paseo agents, workspaces, and daemon state: `/home/dev/.paseo`

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
- Before building, it validates the pinned Paseo dependency graph, reviewed lifecycle-script allowlist, direct 6767 listener, disabled relay/voice defaults, and exact upstream source notice.
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
- **healthcheck.sh** covers code-server (8080), the direct Paseo listener (6767), and authenticated API access
- **.env.example** documents all build-time environment variables
- **Paseo lockfile** still resolves only registry HTTPS artifacts with integrity fields and only the reviewed `node-pty` and `@parcel/watcher` lifecycle-script markers

## Key Design Decisions

- **No Codex App Server** — not started by default; WebSocket transport is experimental
- **Separate web entry points** — code-server uses `PASSWORD`; Paseo uses `PASEO_PASSWORD` with an unset/empty compatibility fallback to `PASSWORD`
- **Browser-token password contract** — runtime health checks flag passwords that cannot be represented in `Sec-WebSocket-Protocol`; use a CSPRNG-generated hexadecimal value rather than an arbitrary password-manager symbol set
- **No third-party Paseo relay** — the daemon runs with `--no-relay`; phones connect directly through the operator's HTTPS reverse proxy
- **Paseo Service Proxy containment** — `PASEO_SERVICE_PROXY_ENABLED=false` does not remove Paseo's built-in localhost routing classification; the host reverse proxy fixes Host/Origin, while loopback host-port binding prevents public clients from bypassing that edge by default
- **Chat Completions-only APIs** — not supported; provider must implement OpenAI Responses API
- **Multi-arch** — `linux/amd64` and `linux/arm64` are supported; CI smoke tests `linux/amd64` before publishing the multi-platform image

## Paseo Supply-chain Record

The bundled runtime is pinned to `@getpaseo/cli@0.3.1` and the exact audited lock graph. Installation uses `npm ci --omit=dev --ignore-scripts`; the build then verifies npm registry signatures, fails on high/critical advisories, probes the shipped native modules, and verifies the CLI version. The exact upstream source and AGPL license are shipped under `/usr/share/doc/paseo`.

The 2026-08-11 audit found no indicators of malicious package content or unexpected lifecycle behavior in the pinned graph; this is not proof against a future registry, maintainer-account, or signing-key compromise. Residual risk remains: Paseo has a single npm maintainer, its package lacks provenance attestation, and the runtime includes prebuilt native modules. At that review, the pinned graph reported three moderate and three low advisories with no high or critical finding. The UUID advisory affects the v3/v5/v6 buffer APIs, while Paseo's server-side references use `v4()`. The low-severity [`@ai-sdk/provider-utils` resource-consumption advisory](https://github.com/advisories/GHSA-866g-f22w-33x8) covers unbounded JSON response handling, but the shipped Paseo CLI, server, and client JavaScript trees contain no import or call site for `ai` or `@ai-sdk`; it remains a transitive, not observed-reachable dependency in this image profile.
