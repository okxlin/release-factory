# DeepSeek Harness image builder

**English** | [简体中文](README.zh-CN.md)

This builder packages [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) with a custom [Caddy](https://github.com/caddyserver/caddy) build, [caddy-security](https://github.com/greenpau/caddy-security), and [caddy-ratelimit](https://github.com/mholt/caddy-ratelimit). It provides a browser login form and origin-side brute-force protection in front of DSH while keeping the application itself bound to container loopback.

One Dockerfile produces two independently tested variants under one image repository:

| Floating tag | Fixed tag pattern | Docker target | Intended use |
| --- | --- | --- | --- |
| `latest` | `<DSH_VERSION>` | `runtime` | Lightweight 1Panel service with essential shell and repository tools. This remains the default final target. |
| `workstation` | `<DSH_VERSION>-workstation` | `workstation` | Full interactive development environment with compiler and language toolchains. |

Both workflows publish the same tags to `ghcr.io/okxlin/deepseek-harness` and to `docker.io/$DOCKERHUB_USERNAME/deepseek-harness`. Configure `DOCKERHUB_USERNAME` as a GitHub Actions repository variable or secret and configure `DOCKERHUB_TOKEN` as a repository secret. The Docker Hub token is used only by the registry login action and is never passed to the image build.

Scheduled runs resolve the current npm `@deepseek-ai/dsh` version, update the image build context, and publish matching `<DSH_VERSION>` and `<DSH_VERSION>-workstation` tags. Manual workflow runs can still override the DSH version or the published tag. Use a floating tag for an AppStore `latest` channel and the matching version tag for a numbered AppStore version.

Exact component pins are defined in [the Dockerfile](image/Dockerfile), [package.json](image/package.json), [pnpm-lock.yaml](image/pnpm-lock.yaml), and the [runtime](../.github/workflows/build-deepseek-harness.yml) and [workstation](../.github/workflows/build-deepseek-harness-workstation.yml) workflows. Those build inputs are the source of truth; this README intentionally describes capabilities and update policy without duplicating version numbers.

Go is aligned with the official stable version endpoint at <https://go.dev/VERSION?m=text>. Rust is aligned with the official stable channel manifest at <https://static.rust-lang.org/dist/channel-rust-stable.toml>. Their Docker Official Image indexes are digest-pinned for reproducible `amd64` and `arm64` selection.

The three workstation Docker client binaries are rebuilt with the pinned Go release from checksum-pinned official source archives. The Buildx source closure imports the legacy `github.com/docker/docker` module only for its frozen random-name generator; the build retains that exact vendored package locally and removes the unrelated daemon module before compiling Buildx and Compose. This keeps the daemon-only AuthZ issue [CVE-2026-34040](https://github.com/moby/moby/security/advisories/GHSA-x744-4wpc-v9h2) out of the client dependency graph instead of weakening the image scan threshold.

The image is built and tested for `linux/amd64` and `linux/arm64`.

## Runtime layout

```text
browser
  -> HTTPS reverse proxy (1Panel/OpenResty)
  -> host loopback port, for example 127.0.0.1:56789
  -> Caddy + authentication rate limiting + caddy-security on container port 8080
  -> DeepSeek Harness on 127.0.0.1:3080 inside the container
```

Only Caddy listens on the container interface. The DSH port is not exposed to sibling containers or the host network. The lightweight image persists Caddy, authentication, JWT, and DSH state in `/data` and user work in `/workspace`. The workstation keeps authentication, Caddy, and DSH state in `/data`, keeps user-installed tools in one named HOME volume at `/home/node`, and uses a separate direct `/workspace` mount for projects. Neither workstation path is a symbolic link.

## Build

```bash
# Default/lightweight image. Resolves npm @deepseek-ai/dsh@latest by default.
deepseek-harness-builder/scripts/build-local.sh \
  --target runtime \
  --tag deepseek-harness:local

# Full development workstation.
deepseek-harness-builder/scripts/build-local.sh \
  --target workstation \
  --tag deepseek-harness-workstation:local
```

The local build helper resolves the requested `@deepseek-ai/dsh` npm version, updates `package.json` and `pnpm-lock.yaml` in a temporary build context, and passes the resolved version as Docker `DSH_VERSION`. Use `--version <release>` or an npm dist-tag to select a DSH release. Direct `docker build` remains supported for the checked-in baseline context, and derives `DSH_VERSION` from `package.json` when no build argument is supplied.

The production dependency closure is pinned by `pnpm-lock.yaml` in the active build context. pnpm lifecycle scripts are fail-closed and limited to the reviewed packages in `pnpm-workspace.yaml`.

The image build applies a narrowly scoped, source-shape-checked compatibility patch to the DSH browse directory picker so the web **Add workspace** dialog starts at `DSH_WORKSPACE` instead of the process `HOME`. If the upstream implementation changes, the build fails closed until the patch and smoke contract are reviewed. This does not change the workstation `HOME` value or its tool persistence path.

The custom Caddy build verifies the go-authcrunch source archive checksum, removes its unused GPG public-key parser, and runs the upstream identity-package tests before linking. SSH public-key support remains available to caddy-security, while the generated `CADDY_GO_PACKAGES.txt` manifest must contain no `golang.org/x/crypto/openpgp` package. The rate-limit module and its license are pinned and verified during the same build. The build also raises `grpc`, `klauspost/compress`, and `x/text` to their fixed versions.

Both images include a checksum-pinned standalone pnpm bundle and remove npm and Corepack. This keeps one audited Node.js package-manager surface and prevents the selected pnpm version from silently following a package-manager channel.

## Development environments

The lightweight image adds these low-overhead basics to the existing Bash, Git, and curl runtime:

- OpenSSH client, jq, ripgrep, less, procps, file, and unzip
- standalone pnpm

It intentionally omits npm, Python, Go, Rust, GCC/G++, and Make.

The workstation image inherits the same DSH/authentication runtime and adds:

- Node.js and pnpm
- Python 3.12.14 with pip, venv, pipx, pytest, and development headers
- Go, Rust, and Cargo
- Docker CLI, Compose, and Buildx (client tools only)
- GCC/G++, Clang, GDB, CMake, Ninja, Autoconf/Automake, libtool, pkg-config, and common native-library headers
- Git LFS, GitHub CLI, ShellCheck, shfmt, yamllint, pre-commit, fd, bat, fzf, tmux, Vim, SQLite, and common network/debug/archive tools

It does not add code-server, Codex/Claude CLIs, proxy daemons, `sudo`, or a Docker daemon. Docker client tools are present, but no daemon socket is mounted by the image, so the default workstation has no host-container control path. User installs under `/home/node` persist in the workstation HOME volume, while projects persist through the direct `/workspace` mount.

## Run behind 1Panel/OpenResty

Copy `image/.env.example` to a private environment file and change at least `PUBLIC_URL` and `AUTH_PASSWORD`. Do not commit that file.

**Important for upgrades:** the persistence path has changed. Current images
store application state under `/data`, and `/data` must be a bind mount or named
volume. Mounting only the legacy
`/home/node/.local/share/deepseek-harness` path does not persist the new layout.
To prevent silent state loss, the entrypoint exits with a bilingual error when
`/data` is not mounted; recreate the container with a persistent `/data` mount.

```bash
sudo install -d -m 0750 /opt/deepseek-harness/data /opt/deepseek-harness/workspace

docker run -d \
  --name deepseek-harness \
  --restart unless-stopped \
  -p 127.0.0.1:56789:8080 \
  --env-file /opt/deepseek-harness/runtime.env \
  -v /opt/deepseek-harness/data:/data \
  -v /opt/deepseek-harness/workspace:/workspace \
  ghcr.io/okxlin/deepseek-harness:latest
```

The lightweight runtime is recommended with a host bind at `/data`. It keeps
authentication, Caddy, JWT, and DSH state in
`/opt/deepseek-harness/data`, where host backup and migration tools can access
it directly. The entrypoint normalizes the bind root and creates the required
subdirectories and files for the `node` user (UID/GID `1000:1000`); keep the
bind source a regular directory and preserve its ownership and permissions when
copying or restoring data.

The workstation uses the same ports and authentication variables. It persists application state through `/data`, HOME through one named volume, and mounts the project directory directly:

```bash
docker run -d \
  --name deepseek-harness-workstation \
  --restart unless-stopped \
  -p 127.0.0.1:56789:8080 \
  --env-file /opt/deepseek-harness/runtime.env \
  -v /opt/deepseek-harness/data:/data \
  -v dsh-home:/home/node \
  -v /opt/deepseek-harness/workspace:/workspace \
  ghcr.io/okxlin/deepseek-harness:workstation
```

The HOME volume contains user-installed pnpm, pipx, Cargo, and Go tools. Application state lives under `/data`. The image working directory and `DSH_WORKSPACE` both default to `/workspace`; the web **Add workspace** dialog also opens there, and its `Home` shortcut resolves to `/workspace`. `/home/node` is the user HOME and persistent tool volume, not the default project directory. The workspace bind is intended for project files and host-side backup or file access.

Docker CLI, Compose, and Buildx work against a remote `DOCKER_HOST` without additional mounts. To control the host Docker daemon, explicitly add:

```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

The entrypoint maps the socket's numeric group to the unprivileged `node` user when possible. Mounting this socket grants tools and model-driven terminals effective control over the host Docker daemon; leave it disabled unless that authority is required.

Both Compose files apply the same opt-in Docker socket contract. Copy `image/.env.example` to `image/.env` and set at least `PUBLIC_URL` and `AUTH_PASSWORD` before starting either variant with Docker access disabled.

The checked-in Compose files use package-local binds for application state and
workspace data. The manual `docker run` example above uses the recommended
`/opt/deepseek-harness/data:/data` bind instead. If you deploy through Compose,
apply the same bind in a local Compose override or local copy; do not commit an
environment-specific host path to the repository:

```bash
docker compose -f deepseek-harness-builder/compose.yml up -d
```

The workstation persists application state under `./data/data`, HOME in the named `dsh-home` volume, and binds the project directory to `./data/workspace`:

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
CADDY_TRUSTED_PROXIES=private_ranges
```

Subpath deployments such as `https://example.com/dsh` are intentionally rejected. Use a dedicated domain or subdomain.

The image limits username-stage POSTs to 10 per minute and password-stage POSTs to 10 per 10 minutes for each resolved client IP. Rejected requests return HTTP 429 with `Retry-After`. Keep a matching limit in the 1Panel WAF or outer OpenResty layer as defense in depth.

These budgets are image defaults defined in [`image/Caddyfile`](image/Caddyfile); they are intentionally not read from the runtime environment. Changing them requires editing that file, rebuilding the image, and rerunning the smoke tests. `CADDY_TRUSTED_PROXIES` is independently configurable at runtime.

`CADDY_TRUSTED_PROXIES` defines the proxy hops Caddy may trust while parsing `X-Forwarded-For`. Caddy uses strict right-to-left parsing, as recommended for append-style proxy chains. The default `private_ranges` matches the documented loopback/private reverse-proxy deployment; set it to `none` if clients connect directly to Caddy. If Cloudflare or another CDN sits before OpenResty, either normalize the real client IP in that outer proxy or add every trusted CDN and immediate-proxy CIDR to this value. The entrypoint rejects unrestricted `/0` ranges because they would let arbitrary peers spoof the rate-limit key. See Caddy's [`trusted_proxies`](https://caddyserver.com/docs/caddyfile/options#trusted-proxies) and [`trusted_proxies_strict`](https://caddyserver.com/docs/caddyfile/options#trusted-proxies-strict) documentation.

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
| `HOME_VOLUME_NAME` | `dsh-home` | Name of the Compose persistent HOME volume used by the workstation. |

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
| `CADDY_TRUSTED_PROXIES` | `private_ranges` | Space-separated trusted proxy CIDRs, `private_ranges`, or `none` for direct client connections. |
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

Let's Encrypt made public IPv4/IPv6 certificates generally available in 2026, but they are 160-hour certificates and require the ACME `shortlived` profile: <https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability/>. The pinned Caddy release supports that profile, but successful issuance still requires public `http-01` or `tls-alpn-01` validation on the IP. This image does not enable direct ACME in its default mode because 1Panel/OpenResty already owns ports 80/443 and public TLS. A future direct-TLS mode should be a separate explicit deployment profile, not an automatic fallback.

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

Current Caddy and caddy-security dependencies are evaluated by the repository [security scan policy](../SECURITY_SCAN.md) and CI vulnerability gates. Consult the latest workflow run for advisory-specific results instead of relying on a static README snapshot.

Other modes:

- `AUTH_MODE=none` disables the login layer and should be used only behind another reviewed authentication boundary.
- `AUTH_MODE=dsh` is reserved for a future DSH native-password release and currently fails closed. This prevents two authentication systems from silently stacking when native auth is added later.

The generated JWT signing key is stored at `/data/auth/jwt-secret` in both images. Persist the corresponding bind path or volume; otherwise existing sessions are invalidated whenever the container is replaced.

## Backup and restore

The recommended lightweight deployment stores its state in the host bind
`/opt/deepseek-harness/data`, while the workstation stores application state in
the same bind and user-installed tools in the named `dsh-home` volume. These
paths are outside a 1Panel application's installation directory, so a normal
1Panel application backup does not include them. Stop the container before
creating a consistent archive, and back up the `/opt/deepseek-harness/workspace`
bind through 1Panel or the host filesystem separately.

The checked-in Compose files use the same layout with package-local
`./data/data`, `./data/workspace`, and `dsh-home` paths. Copy those directories
directly if you run the repository Compose files locally.

### Lightweight

The recommended host bind holds Caddy, authentication, JWT, and DSH state. Back
it up while the container is stopped:

```bash
docker stop deepseek-harness

sudo tar -C /opt/deepseek-harness/data \
  -czf /opt/deepseek-harness/deepseek-harness-data.tar.gz .

docker start deepseek-harness
```

Restore only into a stopped container, preferably into an empty data directory,
and preserve the existing `node` ownership and file modes:

```bash
docker stop deepseek-harness

sudo tar -C /opt/deepseek-harness/data \
  -xzf /opt/deepseek-harness/deepseek-harness-data.tar.gz

docker start deepseek-harness
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

Removing the container or running ordinary `docker compose down` preserves a
named volume. `docker compose down --volumes`, `docker volume rm`, and
`docker volume prune` can remove a named volume. A bind-mounted
`/opt/deepseek-harness/data` is not a Docker volume and remains after these
commands; remove or replace that host directory separately only when its data
is no longer needed.

## Resource use

The authenticated amd64 smoke tests currently settle around `167-180 MiB` and about `20-21` PIDs. The workstation toolchains are dormant, so they do not materially raise idle memory, but they do raise disk use: the current local amd64 Docker sizes are about `700 MB` for the lightweight image and `2.59 GB` for the workstation image before registry compression. Debian rebuilds can move those figures.

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

The test uses a temporary host bind for `/data` and named test volumes for HOME and workspace. Both variants mount the test workspace directly at `/workspace`; the workstation also mounts HOME directly at `/home/node`. It simulates the 1Panel/OpenResty headers and checks login redirects, browser autofill attributes, wrong-password rejection, protected cookies, forged identity headers, both DSH WebSockets, logout, loopback binding, secret isolation, persistent JWT state, container-recreation persistence, the `/workspace` directory-picker default, resource use, fail-closed configuration errors, pnpm, and the selected image variant.

Run the lightweight Compose contract:

```bash
deepseek-harness-builder/scripts/check-compose.sh
```

It proves that the package-local state bind is mounted at `/data`, the package-local workspace is mounted at `/workspace`, the default socket source is `/dev/null`, the enabled source is `/var/run/docker.sock`, and the HTTP port remains loopback-bound.

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

The Compose contract check parses both socket-switch states and proves that the package-local state bind is mounted directly at `/data`, that one named volume is mounted directly at `/home/node`, that the package-local workspace is mounted directly at `/workspace`, the default socket source is `/dev/null`, the enabled source is `/var/run/docker.sock`, and the HTTP port remains loopback-bound. The workstation-specific image test compiles and runs C, C++, Go, and Rust probes, creates a Python virtual environment, checks normal and login-shell PATH behavior, verifies the CLI set, confirms all Docker client binaries use the pinned Go toolchain without the legacy daemon module, confirms Docker has no daemon access by default, characterizes optional socket-group mapping with an isolated Unix socket, verifies that the image declares only `/home/node`, and confirms that HOME, application state, and workspace are real writable directories rather than symbolic links. It also runs the installed DSH sandbox executor under `no-new-privileges`: `workspace-write` must permit a project write and deny a writable path outside the workspace, while an explicit `danger-full-access` retry must permit that outside write without adding container privileges.

Run the Caddy vulnerability gate after building the image:

```bash
deepseek-harness-builder/scripts/check-caddy-vulnerabilities.sh \
  --image deepseek-harness:local
```

Caddy's production binary is stripped. Go documents that binary scans without extractable symbols can fall back to all vulnerabilities in a required module: <https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck#hdr-Limitations>. The gate therefore accepts `GO-2026-5932` only when it is the sole finding, symbols are unavailable, and the build-produced package manifest proves that no OpenPGP package is linked. Any additional finding fails the gate.

Both arm64 CI lanes use QEMU to prove the native `node-pty` build, Caddy plugin modules, authentication flow, architecture, and loopback boundary before a multi-platform image can be published. The workstation lane also runs its compiler probes on arm64. Because Landlock enforcement depends on the host kernel and is not reliably available under QEMU user-mode emulation, that lane explicitly skips only the DSH sandbox enforcement probe; the amd64 workstation lane still runs the full probe.

## Upgrade behavior

The `/data` mount is required for both image variants. When upgrading an older
workstation deployment, keep its legacy `/home/node` volume or direct
`/home/node/.local/share/deepseek-harness` mount attached for the first start and
add the new `/data` mount. If the new authentication state is empty, the
entrypoint copies the legacy workstation application state into `/data`. After
verifying the migrated data, subsequent containers still require `/data`; the
legacy path alone is not a replacement for it.

Caddy and caddy-security are compiled together and pinned. Updating Caddy alone is not assumed safe. Scheduled workflows resolve npm `@deepseek-ai/dsh@latest`, temporarily update `package.json` and `pnpm-lock.yaml` in the build workspace, pass the resolved version as the Docker `DSH_VERSION` build argument, and publish the `runtime` target as `latest` plus `<DSH_VERSION>` and the `workstation` target as `workstation` plus `<DSH_VERSION>-workstation`. Manual runs may override either the DSH package version or the final image tag while retaining the same validation and optional floating tag behavior. Each workflow pushes its verified multi-platform manifest to both GHCR and Docker Hub only after auditing the frozen pnpm production tree, rebuilding and validating the plugin, running the Caddy dependency-graph/govulncheck gate, executing its amd64 and arm64 smoke contracts, and applying zero-fixable HIGH/CRITICAL Trivy gates to both architectures. If either registry login or publication fails, the workflow fails instead of reporting a complete release.
