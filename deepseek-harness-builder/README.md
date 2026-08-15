# DeepSeek Harness image builder

This builder packages [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) with a custom Caddy build and `caddy-security`. It provides a browser login form in front of DSH while keeping the application itself bound to container loopback.

One Dockerfile produces two independently tested variants under one image repository:

| Floating tag | Fixed tag pattern | Docker target | Intended use |
| --- | --- | --- | --- |
| `latest` | `YYYYMMDD` or `<DSH_VERSION>` | `runtime` | Lightweight 1Panel service with essential shell and repository tools. This remains the default final target. |
| `workstation` | `YYYYMMDD-workstation` or `<DSH_VERSION>-workstation` | `workstation` | Full interactive development environment with compiler and language toolchains. |

Both workflows publish the same tags to `ghcr.io/okxlin/deepseek-harness` and to `docker.io/$DOCKERHUB_USERNAME/deepseek-harness`. Configure `DOCKERHUB_USERNAME` as a GitHub Actions repository variable or secret and configure `DOCKERHUB_TOKEN` as a repository secret. The Docker Hub token is used only by the registry login action and is never passed to the image build.

Scheduled runs publish UTC date tags. Manual workflow runs can publish the pinned DeepSeek Harness version instead, for example `0.1.0-rc.6-workstation`. Use a floating tag for an AppStore `latest` channel and the matching version tag for a numbered AppStore version.

Pinned runtime versions:

- DeepSeek Harness `0.1.0-rc.6`
- Node.js `24.18.0`
- pnpm `11.21.0`
- Caddy `2.11.4`
- caddy-security `1.1.64`
- go-authcrunch `1.1.41` with the image-local OpenPGP removal patch

Workstation-only pins:

- Docker CLI `29.7.2`, Docker Compose `5.4.0`, and Docker Buildx `0.36.1`
- Go `1.26.6`
- Rust and Cargo `1.97.1`

Go is aligned with the official stable version endpoint at <https://go.dev/VERSION?m=text>. Rust is aligned with the official stable channel manifest at <https://static.rust-lang.org/dist/channel-rust-stable.toml>. Their Docker Official Image indexes are digest-pinned for reproducible `amd64` and `arm64` selection.

The three workstation Docker client binaries are rebuilt with Go `1.26.6` from checksum-pinned official source archives. Buildx `0.36.1` imports the legacy `github.com/docker/docker` module only for its frozen random-name generator; the build retains that exact vendored package locally and removes the unrelated daemon module before compiling Buildx and Compose. This keeps the daemon-only AuthZ issue [CVE-2026-34040](https://github.com/moby/moby/security/advisories/GHSA-x744-4wpc-v9h2) out of the client dependency graph instead of weakening the image scan threshold.

The image is built and tested for `linux/amd64` and `linux/arm64`.

## Runtime layout

```text
browser
  -> HTTPS reverse proxy (1Panel/OpenResty)
  -> host loopback port, for example 127.0.0.1:56789
  -> Caddy + caddy-security on container port 8080
  -> DeepSeek Harness on 127.0.0.1:3080 inside the container
```

Only Caddy listens on the container interface. The DSH port is not exposed to sibling containers or the host network. The lightweight image persists Caddy, authentication, JWT, and DSH state in `/data` and user work in `/workspace`. The workstation mounts one named volume directly at `/home/node`, stores authentication, Caddy, and DSH state below `/home/node/.local/share/deepseek-harness`, and uses a separate direct `/workspace` mount for projects. Neither workstation path is a symbolic link.

## Build

```bash
# Default/lightweight image. --target runtime is explicit for release parity.
docker build --target runtime \
  -t deepseek-harness:local \
  deepseek-harness-builder/image

# Full development workstation.
docker build --target workstation \
  -t deepseek-harness-workstation:local \
  deepseek-harness-builder/image
```

The production dependency closure is pinned by `pnpm-lock.yaml`. pnpm lifecycle scripts are fail-closed and limited to the reviewed packages in `pnpm-workspace.yaml`.

The custom Caddy build verifies the go-authcrunch source archive checksum, removes its unused GPG public-key parser, and runs the upstream identity-package tests before linking. SSH public-key support remains available to caddy-security, while the generated `CADDY_GO_PACKAGES.txt` manifest must contain no `golang.org/x/crypto/openpgp` package. The build also raises `grpc`, `klauspost/compress`, and `x/text` to their fixed versions.

Both images include a checksum-pinned standalone pnpm `11.21.0` bundle and remove npm and Corepack. This keeps one audited Node.js package-manager surface and prevents the selected pnpm version from silently following a package-manager channel.

## Development environments

The lightweight image adds these low-overhead basics to the existing Bash, Git, and curl runtime:

- OpenSSH client, jq, ripgrep, less, procps, file, and unzip
- standalone pnpm `11.21.0`

It intentionally omits npm, Python, Go, Rust, GCC/G++, and Make.

The workstation image inherits the same DSH/authentication runtime and adds:

- Node.js `24.18.0` and pnpm `11.21.0`
- Python 3 with pip, venv, pipx, pytest, and development headers
- Go `1.26.6`; Rust and Cargo `1.97.1`
- Docker CLI `29.7.2`, Compose `5.4.0`, and Buildx `0.36.1` (client tools only)
- GCC/G++, Clang, GDB, CMake, Ninja, Autoconf/Automake, libtool, pkg-config, and common native-library headers
- Git LFS, GitHub CLI, ShellCheck, shfmt, yamllint, pre-commit, fd, bat, fzf, tmux, Vim, SQLite, and common network/debug/archive tools

It does not add code-server, Codex/Claude CLIs, proxy daemons, `sudo`, or a Docker daemon. Docker client tools are present, but no daemon socket is mounted by the image, so the default workstation has no host-container control path. User installs under `/home/node` persist in the workstation HOME volume, while projects persist through the direct `/workspace` mount.

## Run behind 1Panel/OpenResty

Copy `image/.env.example` to a private environment file and change at least `PUBLIC_URL` and `AUTH_PASSWORD`. Do not commit that file.

```bash
docker run -d \
  --name deepseek-harness \
  --restart unless-stopped \
  -p 127.0.0.1:56789:8080 \
  --env-file /opt/deepseek-harness/runtime.env \
  -v dsh-data:/data \
  -v /opt/deepseek-harness/workspace:/workspace \
  ghcr.io/okxlin/deepseek-harness:latest
```

The workstation uses the same ports and authentication variables. It persists HOME through one named volume and mounts the project directory directly:

```bash
docker run -d \
  --name deepseek-harness-workstation \
  --restart unless-stopped \
  -p 127.0.0.1:56789:8080 \
  --env-file /opt/deepseek-harness/runtime.env \
  -v dsh-home:/home/node \
  -v /opt/deepseek-harness/workspace:/workspace \
  ghcr.io/okxlin/deepseek-harness:workstation
```

The HOME volume contains user-installed pnpm, pipx, Cargo, and Go tools plus authentication, Caddy, and DSH state. The workspace bind is intended for project files and host-side backup or file access.

Docker CLI, Compose, and Buildx work against a remote `DOCKER_HOST` without additional mounts. To control the host Docker daemon, explicitly add:

```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

The entrypoint maps the socket's numeric group to the unprivileged `node` user when possible. Mounting this socket grants tools and model-driven terminals effective control over the host Docker daemon; leave it disabled unless that authority is required.

Both Compose files apply the same opt-in Docker socket contract. Copy `image/.env.example` to `image/.env` and set at least `PUBLIC_URL` and `AUTH_PASSWORD` before starting either variant with Docker access disabled.

The lightweight image persists Caddy, authentication, JWT, and DSH state in the named `dsh-data` volume and binds the project directory to the package-local `data/workspace`:

```bash
docker compose -f deepseek-harness-builder/compose.yml up -d
```

The workstation persists HOME, user-installed toolchains, and application state in the named `dsh-home` volume and binds the project directory to the package-local `data/workspace`:

```bash
docker compose -f deepseek-harness-builder/compose.workstation.yml up -d
```

The shared socket mount is:

```yaml
volumes:
  - ${DOCKER_SOCK_SRC:-/dev/null}:/var/run/docker.sock
```

An unset or empty field mounts `/dev/null`, which is not a Unix socket and therefore leaves daemon access disabled. Enable the high-risk host-control path only for a deployment that needs it:

```bash
DOCKER_SOCK_SRC=/var/run/docker.sock \
  docker compose -f deepseek-harness-builder/compose.yml up -d
```

Either variant accepts the same `DOCKER_SOCK_SRC`; substitute `compose.workstation.yml` for the workstation.

Both Compose files publish container port `8080` as `127.0.0.1:56789` by default. The 1Panel package exposes the same opt-in socket contract through `DOCKER_SOCK_PATH`, with `/dev/null` as the disabled default and `/var/run/docker.sock` as the explicit high-risk choice.

Create an HTTPS website in 1Panel and proxy it to `http://127.0.0.1:56789`. Keep the container port bound to host loopback; do not publish it as `0.0.0.0:56789`.

The proxy must preserve the public authority and scheme and must allow WebSocket upgrades:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

location / {
    proxy_pass http://127.0.0.1:56789;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
}
```

1Panel's normal reverse-proxy template can already provide most of these directives; verify WebSocket support and the three Host/scheme headers instead of creating duplicate locations. If a CDN terminates TLS before OpenResty, make sure `X-Forwarded-Proto` still represents the browser-facing HTTPS scheme. A wrong value causes login redirects and cookie handling to use the wrong scheme.

Set `PUBLIC_URL` to the exact browser origin, for example:

```dotenv
PUBLIC_URL=https://dsh.example.com
AUTH_COOKIE_INSECURE=false
```

Subpath deployments such as `https://example.com/dsh` are intentionally rejected. Use a dedicated domain or subdomain.

Rate-limit `/auth/login` and `/auth/sandbox/*` in the 1Panel WAF or the outer OpenResty layer. The image does not add another rate-limit plugin to Caddy. When the site is behind Cloudflare or another CDN, configure the trusted real-client-IP chain before applying an IP-based limit; otherwise all users may share an edge IP quota.

`/healthz` is intentionally unauthenticated and returns only `ok`, so 1Panel and Docker can probe readiness without a session.

## Configuration reference

### Compose variables

Set these in the shell or a `.env` file next to the Compose file to customize a deployment without editing it.

| Variable | Default (lightweight / workstation) | Description |
| --- | --- | --- |
| `DSH_IMAGE` | `ghcr.io/okxlin/deepseek-harness:latest` / `:workstation` | Override the image tag, for example a pinned date or version tag. |
| `CONTAINER_NAME` | `deepseek-harness` / `deepseek-harness-workstation` | Container name. |
| `RUNTIME_ENV_FILE` | `./image/.env` | Path to the runtime environment file; copy `image/.env.example` here and edit it. |
| `BIND_ADDRESS` | `127.0.0.1` | Host interface to publish the HTTP port on. Keep loopback behind 1Panel/OpenResty. |
| `HOST_PORT` | `56789` | Host port mapped to container port `8080`. |
| `DOCKER_SOCK_SRC` | `/dev/null` | Docker socket source. `/dev/null` or empty disables daemon access; `/var/run/docker.sock` enables it. |
| `DATA_VOLUME_NAME` / `HOME_VOLUME_NAME` | `dsh-data` / `dsh-home` | Name of the persistent state volume. |

### Runtime environment variables

Copy `image/.env.example` to `RUNTIME_ENV_FILE` (default `image/.env`) and set at least `PUBLIC_URL` and `AUTH_PASSWORD`. Set exactly one of `AUTH_PASSWORD`, `AUTH_PASSWORD_FILE`, or `AUTH_PASSWORD_HASH`.

| Variable | Default | Description |
| --- | --- | --- |
| `PUBLIC_URL` | *(required)* | Browser origin, e.g. `https://dsh.example.com`. Subpaths are rejected. |
| `AUTH_MODE` | `caddy-security` | Login layer; `none` disables it, `dsh` is reserved and fails closed. |
| `AUTH_USERNAME` | `admin` | Single DSH user. |
| `AUTH_PASSWORD` | *(required)* | Plaintext password, at least 12 characters. |
| `AUTH_PASSWORD_FILE` | *(unset)* | Path to a readable secret file, e.g. a Docker secret. |
| `AUTH_PASSWORD_HASH` | *(unset)* | `bcrypt:<cost>:<hash>` with cost `12-31`. |
| `AUTH_TOKEN_LIFETIME` | `3600` | Access token and cookie lifetime, `300`-`2592000` seconds. |
| `AUTH_COOKIE_INSECURE` | `false` | `true` only for isolated HTTP tests; drops `Secure` and `HttpOnly`. |
| `DSH_TRUSTED_HOSTS` | *(empty)* | Comma-separated additional DSH Host authorities. |
| `PORT` | `8080` | Container port Caddy listens on; publish via loopback. |
| `DSH_INTERNAL_PORT` | `3080` | DSH loopback port inside the container. |
| `GOMEMLIMIT` | `128MiB` | Caddy Go runtime soft memory limit; does not cap DSH workload memory. |
| `GOMAXPROCS` | `2` | Caddy Go runtime CPU limit. |
| `DSH_TELEMETRY_DISABLED` | `1` | Disables DSH telemetry. |

## Access by IP address

An IP authority is accepted by `PUBLIC_URL`; the smoke suite verifies the HTTPS proxy contract with an IPv4 address and port. The transport still determines whether that deployment is safe:

- An HTTPS IP origin works when an outer proxy or another TLS endpoint presents a certificate valid for that IP and `PUBLIC_URL` uses the same origin.
- A plain HTTP IP origin requires `AUTH_COOKIE_INSECURE=true`. This has no transport confidentiality and, with the current caddy-security behavior, removes both `Secure` and `HttpOnly` from its cookies. Restrict it to an isolated test network.
- Caddy's `tls internal` can create a private certificate for an IP, but every browser must first trust the container's private CA; otherwise users receive a certificate warning. Caddy documents this local-CA behavior at <https://caddyserver.com/docs/automatic-https#local-https>.

Let's Encrypt made public IPv4/IPv6 certificates generally available in 2026, but they are 160-hour certificates and require the ACME `shortlived` profile: <https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability/>. Caddy `2.11.4` supports that profile, but successful issuance still requires public `http-01` or `tls-alpn-01` validation on the IP. This image does not enable direct ACME in its default mode because 1Panel/OpenResty already owns ports 80/443 and public TLS. A future direct-TLS mode should be a separate explicit deployment profile, not an automatic fallback.

## Authentication

The default `AUTH_MODE=caddy-security` creates one DSH user from `AUTH_USERNAME` and one of these mutually exclusive credential inputs:

- `AUTH_PASSWORD`: plaintext supplied by the deployment secret mechanism; at least 12 characters.
- `AUTH_PASSWORD_FILE`: readable file such as a Docker secret.
- `AUTH_PASSWORD_HASH`: exact `bcrypt:<cost>:<hash>` value with matching cost `12-31`.

Generate an accepted hash without installing Caddy on the host:

```bash
password_hash="$({ printf '%s\n' 'replace-this-password'; } | \
  docker run --rm -i --entrypoint caddy \
  ghcr.io/okxlin/deepseek-harness:latest \
  hash-password --algorithm bcrypt --bcrypt-cost 12)"
docker run ... -e "AUTH_PASSWORD_HASH=bcrypt:12:${password_hash}" ...
```

Avoid placing a bcrypt hash directly in a Compose `.env` file unless its dollar signs are escaped according to the Compose version in use. A secret file is less error-prone.

The login form marks the fields with `autocomplete="username"` and `autocomplete="current-password"`, so browser password managers can fill them. Access cookies use `Secure`, `HttpOnly`, and `SameSite=Strict` for normal HTTPS deployments.

`AUTH_TOKEN_LIFETIME` accepts `300` through `2592000` seconds (five minutes through 30 days). It controls both the signed access-token lifetime and the browser Cookie lifetime. In the pinned caddy-security implementation, the refresh Cookie does not automatically issue a replacement access token, so expiry requires the user to sign in again. Keep the default one-hour lifetime for short-lived sessions, or select a longer bounded lifetime for a personal workstation.

`AUTH_COOKIE_INSECURE=true` is only for explicitly trusted, isolated HTTP testing. With the current caddy-security behavior it removes both `Secure` and `HttpOnly`, not only `Secure`.

caddy-security also creates an internal `webadmin` record with a random password when the local identity database is initialized. The DSH authorization policy allows only `authp/user`; that internal admin role cannot access DSH.

The Go vulnerability database currently has a range discrepancy for the historical caddy-security findings `GO-2024-2549` and `GO-2024-2557` through `GO-2024-2565`: its records have no fixed event, while the corresponding GitHub advisories limit affected releases to `<=1.1.20`, `<=1.1.23`, or `<=1.0.42`. This image pins `1.1.64`, and Trivy evaluates the published version ranges and reports no affected caddy-security finding. The discrepancy is documented in the repository security scan policy instead of being silently ignored.

Other modes:

- `AUTH_MODE=none` disables the login layer and should be used only behind another reviewed authentication boundary.
- `AUTH_MODE=dsh` is reserved for a future DSH native-password release and currently fails closed. This prevents two authentication systems from silently stacking when native auth is added later.

The generated JWT signing key is stored at `/data/auth/jwt-secret` in the lightweight image and at `/home/node/.local/share/deepseek-harness/auth/jwt-secret` in the workstation. Persist the corresponding volume; otherwise existing sessions are invalidated whenever the container is replaced.

## Backup and restore

The lightweight `dsh-data` volume and the workstation `dsh-home` volume are both outside a 1Panel application's installation directory, so a normal 1Panel application backup does not include either. Stop the container before creating a consistent archive, and back up the package-local `data/workspace` bind through 1Panel or the host filesystem separately.

### Lightweight

The named `dsh-data` volume holds Caddy, authentication, JWT, and DSH state. Back it up while the container is stopped:

```bash
docker stop deepseek-harness

docker run --rm --entrypoint tar \
  -v dsh-data:/source:ro \
  -v "$PWD":/backup \
  ghcr.io/okxlin/deepseek-harness:latest \
  -C /source -czf /backup/dsh-data.tar.gz .

docker start deepseek-harness
```

Restore only into a stopped container and preferably into an empty volume:

```bash
docker run --rm --entrypoint tar \
  -v dsh-data:/target \
  -v "$PWD":/backup:ro \
  ghcr.io/okxlin/deepseek-harness:latest \
  -C /target -xzf /backup/dsh-data.tar.gz
```

### Workstation

```bash
docker stop deepseek-harness-workstation

docker run --rm --entrypoint tar \
  -v dsh-home:/source:ro \
  -v "$PWD":/backup \
  ghcr.io/okxlin/deepseek-harness:workstation \
  -C /source -czf /backup/dsh-home.tar.gz .

docker start deepseek-harness-workstation
```

Restore only into a stopped workstation and preferably into an empty HOME volume:

```bash
docker run --rm --entrypoint tar \
  -v dsh-home:/target \
  -v "$PWD":/backup:ro \
  ghcr.io/okxlin/deepseek-harness:workstation \
  -C /target -xzf /backup/dsh-home.tar.gz
```

Removing the container or running ordinary `docker compose down` preserves the named volume. `docker compose down --volumes`, `docker volume rm`, and `docker volume prune` can remove it.

## Resource use

The authenticated amd64 smoke tests currently settle around `167-180 MiB` and about `20-21` PIDs with DSH `0.1.0-rc.6`. The workstation toolchains are dormant, so they do not materially raise idle memory, but they do raise disk use: the current local amd64 Docker sizes are about `700 MB` for the lightweight image and `2.59 GB` for the workstation image before registry compression. Debian rebuilds can move those figures.

The CI ceiling remains `256 MiB` for the idle flow. This is not a workload limit: terminals, repositories, language servers, compilers, and model tools can require substantially more memory.

`GOMEMLIMIT=128MiB` and `GOMAXPROCS=2` constrain Caddy's Go runtime only. If 1Panel requires a container memory limit, start at `512 MiB` for the lightweight image and at least `1 GiB` for the workstation, then adjust from observed workloads rather than treating the Caddy limit as the whole-container budget.

## Verification

Run the full amd64 contract:

```bash
deepseek-harness-builder/scripts/smoke-test.sh \
  --image deepseek-harness:local \
  --profile full \
  --variant runtime
```

The test uses named test volumes and no host port. The workstation mounts HOME directly at `/home/node` and the test workspace directly at `/workspace`; the lightweight runtime retains its `/data` and `/workspace` volumes. It simulates the 1Panel/OpenResty headers and checks login redirects, browser autofill attributes, wrong-password rejection, protected cookies, forged identity headers, both DSH WebSockets, logout, loopback binding, secret isolation, persistent JWT state, container-recreation persistence, resource use, fail-closed configuration errors, pnpm, and the selected image variant.

Run the lightweight Compose contract:

```bash
deepseek-harness-builder/scripts/check-compose.sh
```

It proves that one named volume is mounted at `/data`, the package-local workspace is mounted at `/workspace`, the default socket source is `/dev/null`, the enabled source is `/var/run/docker.sock`, no workstation HOME volume is present, and the HTTP port remains loopback-bound.

Run both workstation contracts:

```bash
deepseek-harness-builder/scripts/check-workstation-compose.sh

deepseek-harness-builder/scripts/smoke-test.sh \
  --image deepseek-harness-workstation:local \
  --profile full \
  --variant workstation

deepseek-harness-builder/scripts/workstation-smoke-test.sh \
  --image deepseek-harness-workstation:local
```

The Compose contract check parses both socket-switch states and proves that one named volume is mounted directly at `/home/node`, the package-local workspace is mounted directly at `/workspace`, the default socket source is `/dev/null`, the enabled source is `/var/run/docker.sock`, and the HTTP port remains loopback-bound. The workstation-specific image test compiles and runs C, C++, Go, and Rust probes, creates a Python virtual environment, checks normal and login-shell PATH behavior, verifies the CLI set, confirms all Docker client binaries use Go `1.26.6` without the legacy daemon module, confirms Docker has no daemon access by default, characterizes optional socket-group mapping with an isolated Unix socket, verifies that the image declares only `/home/node`, and confirms that HOME, application state, and workspace are real writable directories rather than symbolic links. It also runs the installed DSH sandbox executor under `no-new-privileges`: `workspace-write` must permit a project write and deny a writable path outside the workspace, while an explicit `danger-full-access` retry must permit that outside write without adding container privileges.

Run the Caddy vulnerability gate after building the image:

```bash
deepseek-harness-builder/scripts/check-caddy-vulnerabilities.sh \
  --image deepseek-harness:local
```

Caddy's production binary is stripped. Go documents that binary scans without extractable symbols can fall back to all vulnerabilities in a required module: <https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck#hdr-Limitations>. The gate therefore accepts `GO-2026-5932` only when it is the sole finding, symbols are unavailable, and the build-produced package manifest proves that no OpenPGP package is linked. Any additional finding fails the gate.

Both arm64 CI lanes use QEMU to prove the native `node-pty` build, Caddy plugin modules, authentication flow, architecture, and loopback boundary before a multi-platform image can be published. The workstation lane also runs its compiler probes on arm64. Because Landlock enforcement depends on the host kernel and is not reliably available under QEMU user-mode emulation, that lane explicitly skips only the DSH sandbox enforcement probe; the amd64 workstation lane still runs the full probe.

## Upgrade behavior

Caddy and caddy-security are compiled together and pinned. Updating Caddy alone is not assumed safe. Scheduled workflows publish the `runtime` target as `latest` plus a UTC date tag and the `workstation` target as `workstation` plus a `YYYYMMDD-workstation` tag. Manual runs may replace the date component with the pinned DSH version, yielding fixed tags such as `<DSH_VERSION>` and `<DSH_VERSION>-workstation`. Each workflow pushes its verified multi-platform manifest to both GHCR and Docker Hub only after auditing the frozen pnpm production tree, rebuilding and validating the plugin, running the Caddy dependency-graph/govulncheck gate, executing its amd64 and arm64 smoke contracts, and applying zero-fixable HIGH/CRITICAL Trivy gates to both architectures. If either registry login or publication fails, the workflow fails instead of reporting a complete release.
