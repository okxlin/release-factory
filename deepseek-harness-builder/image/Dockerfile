# syntax=docker/dockerfile:1.26.0@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32

FROM caddy:2.11.4-builder-alpine@sha256:7bac9be4072f7c4db2ccc7350750e0705004bf02da2ac7d96b1469ca4f28bb7c AS caddy-builder

ARG CADDY_VERSION=2.11.4
ARG CADDY_SOURCE_ARCHIVE_SHA256=2c3d02078286a6282cdb4d1d8744077788d556659dac0b64d8ed5886a7e5aeb9
ARG CADDY_SECURITY_VERSION=1.1.64
ARG CEL_GO_VERSION=0.31.0
ARG GO_AUTHCRUNCH_VERSION=1.1.41
ARG GRPC_VERSION=1.83.1
ARG KLAUSPOST_COMPRESS_VERSION=1.19.2
ARG X_TEXT_VERSION=0.41.0
ARG CADDY_RATELIMIT_REF=5625512f24f6f59d6f64fb3aafe5eecff0b286db

COPY patches/caddy-cel-go-v0.30.patch /tmp/caddy-cel-go-v0.30.patch
COPY patches/go-authcrunch-disable-openpgp.patch /tmp/go-authcrunch-disable-openpgp.patch

# Caddy v2.11.4 predates CEL's InterpretableV2 API. Apply the exact source
# compatibility change from Caddy upstream commit b2693fb before pinning CEL
# to the advisory's fixed release.
RUN wget -qO /tmp/caddy.tar.gz \
        "https://github.com/caddyserver/caddy/archive/refs/tags/v${CADDY_VERSION}.tar.gz" \
    && printf '%s  %s\n' \
        "${CADDY_SOURCE_ARCHIVE_SHA256}" \
        /tmp/caddy.tar.gz | sha256sum -c - \
    && mkdir -p /usr/src \
    && tar -xzf /tmp/caddy.tar.gz -C /usr/src \
    && cd "/usr/src/caddy-${CADDY_VERSION}" \
    && git apply --check /tmp/caddy-cel-go-v0.30.patch \
    && git apply /tmp/caddy-cel-go-v0.30.patch

# caddy-security's local password flow does not use go-authcrunch's GPG public
# key parser. Remove that parser because x/crypto/openpgp is unmaintained and
# has no fixed release, then test the patched identity package before linking.
RUN wget -qO /tmp/go-authcrunch.tar.gz \
        "https://github.com/greenpau/go-authcrunch/archive/refs/tags/v${GO_AUTHCRUNCH_VERSION}.tar.gz" \
    && printf '%s  %s\n' \
        'ccc415eb76c2e0d9f1a3136ee62ded80ca824a49182ac6c62ac25963ad6d1e2b' \
        /tmp/go-authcrunch.tar.gz | sha256sum -c - \
    && mkdir -p /usr/src \
    && tar -xzf /tmp/go-authcrunch.tar.gz -C /usr/src \
    && cd "/usr/src/go-authcrunch-${GO_AUTHCRUNCH_VERSION}" \
    && git apply --check --unidiff-zero /tmp/go-authcrunch-disable-openpgp.patch \
    && git apply --unidiff-zero /tmp/go-authcrunch-disable-openpgp.patch \
    && ! grep -R -F 'golang.org/x/crypto/openpgp' pkg/identity \
    && PATH="/usr/local/go/bin:${PATH}" go test ./pkg/identity

RUN xcaddy build "v${CADDY_VERSION}" \
        --with "github.com/greenpau/caddy-security@v${CADDY_SECURITY_VERSION}" \
        --with "github.com/mholt/caddy-ratelimit@${CADDY_RATELIMIT_REF}" \
        --replace "github.com/caddyserver/caddy/v2=/usr/src/caddy-${CADDY_VERSION}" \
        --replace "github.com/greenpau/go-authcrunch@v${GO_AUTHCRUNCH_VERSION}=/usr/src/go-authcrunch-${GO_AUTHCRUNCH_VERSION}" \
        --replace "github.com/google/cel-go=github.com/google/cel-go@v${CEL_GO_VERSION}" \
        --replace "google.golang.org/grpc=google.golang.org/grpc@v${GRPC_VERSION}" \
        --replace "github.com/klauspost/compress=github.com/klauspost/compress@v${KLAUSPOST_COMPRESS_VERSION}" \
        --replace "golang.org/x/text=golang.org/x/text@v${X_TEXT_VERSION}" \
    && ./caddy version \
    && ./caddy list-modules | grep -Fx 'security' \
    && ./caddy list-modules | grep -Fx 'http.handlers.authenticator' \
    && ./caddy list-modules | grep -Fx 'http.authentication.providers.authorizer' \
    && ./caddy list-modules | grep -Fx 'http.handlers.rate_limit'

RUN PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq 'google\.golang\.org/grpc[[:space:]]+v1\.83\.1' \
    && PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq 'github\.com/klauspost/compress[[:space:]]+v1\.19\.2' \
    && PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq 'github\.com/google/cel-go[[:space:]]+v0\.31\.0' \
    && PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq 'golang\.org/x/text[[:space:]]+v0\.41\.0' \
    && set -- /tmp/buildenv_* \
    && test "$#" -eq 1 \
    && test -d "$1" \
    && mkdir -p /licenses \
    && PATH="/usr/local/go/bin:${PATH}" go list -C "$1" -deps . \
        | LC_ALL=C sort -u > /licenses/CADDY_GO_PACKAGES.txt \
    && grep -Fx 'golang.org/x/crypto/ssh' /licenses/CADDY_GO_PACKAGES.txt \
    && ! grep -Eq '^golang\.org/x/crypto/openpgp(/|$)' /licenses/CADDY_GO_PACKAGES.txt

RUN mkdir -p /licenses \
    && wget -qO /licenses/CADDY_LICENSE \
        "https://raw.githubusercontent.com/caddyserver/caddy/v${CADDY_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30' \
        /licenses/CADDY_LICENSE | sha256sum -c - \
    && wget -qO /licenses/CADDY_SECURITY_LICENSE \
        "https://raw.githubusercontent.com/greenpau/caddy-security/v${CADDY_SECURITY_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4' \
        /licenses/CADDY_SECURITY_LICENSE | sha256sum -c - \
    && wget -qO /licenses/CEL_GO_LICENSE \
        "https://raw.githubusercontent.com/google/cel-go/v${CEL_GO_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        '4cdb9af102dfbb0ca03d87d6f650a505df098646a4080f4665b389ad9c6caa02' \
        /licenses/CEL_GO_LICENSE | sha256sum -c - \
    && wget -qO /licenses/GO_AUTHCRUNCH_LICENSE \
        "https://raw.githubusercontent.com/greenpau/go-authcrunch/v${GO_AUTHCRUNCH_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4' \
        /licenses/GO_AUTHCRUNCH_LICENSE | sha256sum -c - \
    && wget -qO /licenses/CADDY_RATELIMIT_LICENSE \
        "https://raw.githubusercontent.com/mholt/caddy-ratelimit/${CADDY_RATELIMIT_REF}/LICENSE" \
    && printf '%s  %s\n' \
        '094bedda295c0702807d1027a00e1134f4cb71d523dc49f6d4b3caf589053068' \
        /licenses/CADDY_RATELIMIT_LICENSE | sha256sum -c -

FROM python:3.12.14-slim-trixie@sha256:2c941e860699f878900b0edc2403613c234d4b32eda3cc9fa7036991a2a63c4a AS python-toolchain

ARG PYTHON_VERSION=3.12.14
ARG PYTEST_VERSION=9.1.1

RUN python3 --version | grep -Fx "Python ${PYTHON_VERSION}" \
    && test "$(python3 -c 'import platform; print(platform.python_version())')" = "${PYTHON_VERSION}" \
    && python3 -m pip --version | grep -F '(python 3.12)' \
    && python3 -m venv /tmp/python-venv \
    && /tmp/python-venv/bin/python --version | grep -Fx "Python ${PYTHON_VERSION}" \
    && printf '%s\n' \
        "pytest==${PYTEST_VERSION} --hash=sha256:37a86b45efb9a47a61a36449063e8e18d0cab3161329fc099eb21783169c4f0c" \
        'iniconfig==2.3.0 --hash=sha256:f631c04d2c48c52b84d0d0549c99ff3859c98df65b3101406327ecc7d53fbf12' \
        'packaging==26.3 --hash=sha256:d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c' \
        'pluggy==1.6.0 --hash=sha256:e920276dd6813095e9377c0bc5566d94c932c33b27a3e3945d8389c374dd4746' \
        'Pygments==2.21.0 --hash=sha256:2363c69b61c4a97c838da3b130dcd6468f4848992b21a82f2a63ec34377137d9' \
        > /tmp/python-requirements.txt \
    && python3 -m pip install \
        --no-cache-dir \
        --disable-pip-version-check \
        --only-binary=:all: \
        --require-hashes \
        --requirement /tmp/python-requirements.txt \
    && python3 -m pytest --version | grep -Fx "pytest ${PYTEST_VERSION}" \
    && rm -f /tmp/python-requirements.txt

FROM node:24.19.0-trixie-slim@sha256:0711b541c1c33a8a530ac4f0d391baa9a15b3d804695b1b24a47daa5fb60e74d AS dsh-deps

ARG DSH_VERSION=
ARG PYTHON_VERSION=3.12.14
ARG PYTEST_VERSION=9.1.1
ARG PNPM_VERSION=11.22.0

ENV PYTHON=/usr/local/bin/python3

COPY --from=python-toolchain /usr/local /usr/local

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        g++ \
        make \
    && rm -rf /var/lib/apt/lists/*

RUN python3 --version | grep -Fx "Python ${PYTHON_VERSION}" \
    && test "$(python3 -c 'import platform; print(platform.python_version())')" = "${PYTHON_VERSION}" \
    && python3 -m pip --version | grep -F '(python 3.12)' \
    && python3 -m pytest --version | grep -Fx "pytest ${PYTEST_VERSION}"

WORKDIR /opt/dsh
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY scripts/patch-dsh-directory-picker.mjs /tmp/patch-dsh-directory-picker.mjs

RUN corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && resolved_dsh_version="${DSH_VERSION:-$(node -p "require('./package.json').dependencies['@deepseek-ai/dsh']")}" \
    && test "$(node -p "require('./package.json').dependencies['@deepseek-ai/dsh']")" = "${resolved_dsh_version}" \
    && pnpm install --prod --frozen-lockfile --trust-lockfile \
    && node /tmp/patch-dsh-directory-picker.mjs \
    && rm -f /tmp/patch-dsh-directory-picker.mjs \
    && pnpm exec dsh --version | grep -Fx "${resolved_dsh_version}" \
    && node_pty_arch="$(node -p "process.arch")" \
    && case "${node_pty_arch}" in x64|arm64) ;; *) exit 1 ;; esac \
    && find node_modules/.pnpm \
        \( \
            -path '*/node_modules/node-pty/build/Release/pty.node' \
            -o -path "*/node_modules/node-pty/prebuilds/linux-${node_pty_arch}/pty.node" \
        \) \
        -type f -print -quit | grep -q .

FROM node:24.19.0-trixie-slim@sha256:0711b541c1c33a8a530ac4f0d391baa9a15b3d804695b1b24a47daa5fb60e74d AS pnpm-bundle

ARG PNPM_VERSION=11.22.0

# The registry tarball is checksum-pinned so the runtime can provide pnpm
# without retaining npm or Corepack.
ADD --checksum=sha256:57a97e6f23a3faffc03153a4ef8c770a0552612b8640aebe39bfdd5754d0ebdc \
    https://registry.npmjs.org/pnpm/-/pnpm-11.22.0.tgz /tmp/pnpm.tgz

RUN mkdir -p /opt/pnpm \
    && tar -xzf /tmp/pnpm.tgz -C /opt/pnpm --strip-components=1 \
    && test "$(node -p "require('/opt/pnpm/package.json').version")" = "${PNPM_VERSION}" \
    && test "$(node /opt/pnpm/bin/pnpm.mjs --version)" = "${PNPM_VERSION}" \
    && rm -f /tmp/pnpm.tgz

FROM node:24.19.0-trixie-slim@sha256:0711b541c1c33a8a530ac4f0d391baa9a15b3d804695b1b24a47daa5fb60e74d AS npm-bundle

ARG NPM_VERSION=11.19.0

# Node.js 24 currently bundles an older npm release. Keep workstation npm
# independently checksum-pinned so security fixes do not wait for a new Node
# base-image release, while the runtime target can continue omitting npm.
ADD --checksum=sha256:31e9770f7dc71119a58509353b27917557aaf0ac9b5ef1a0465ee7d8ec67ae75 \
    https://registry.npmjs.org/npm/-/npm-11.19.0.tgz /tmp/npm.tgz

RUN mkdir -p /opt/npm \
    && tar -xzf /tmp/npm.tgz -C /opt/npm --strip-components=1 \
    && test "$(node -p "require('/opt/npm/package.json').version")" = "${NPM_VERSION}" \
    && test "$(node /opt/npm/bin/npm-cli.js --version)" = "${NPM_VERSION}" \
    && test "$(node /opt/npm/bin/npx-cli.js --version)" = "${NPM_VERSION}" \
    && rm -f /tmp/npm.tgz

FROM golang:1.27.0-trixie@sha256:6212da3924947f4b6a939df02ea627c13f338f1a41d6c3fcb0dd9d076eef46c4 AS docker-tools-builder

ARG DOCKER_BUILDX_VERSION=0.36.1
ARG DOCKER_COMPOSE_VERSION=5.5.0
ARG DOCKER_VERSION=29.7.2
ARG MOBY_GO_ARCHIVE_VERSION=0.3.3
ARG X_MOD_VERSION=0.40.0

COPY patches/docker-buildx-local-namesgenerator.patch /tmp/docker-buildx-local-namesgenerator.patch

ADD --checksum=sha256:225b7ab2a15f5230b482df8461069cd4bce38891266fb9898d4188d0a3cbf54a \
    https://codeload.github.com/docker/cli/tar.gz/refs/tags/v29.7.2 /tmp/docker-cli.tar.gz
ADD --checksum=sha256:504ed1541f4bc5c301dc9cf7b86ae8e2d26b57a558a248d9b832af188b298bba \
    https://codeload.github.com/docker/compose/tar.gz/refs/tags/v5.5.0 /tmp/docker-compose.tar.gz
ADD --checksum=sha256:8959987919445ab61564f50decde4dae810137063d84e2d3c969c9a4a68ecdeb \
    https://codeload.github.com/docker/buildx/tar.gz/refs/tags/v0.36.1 /tmp/docker-buildx.tar.gz

RUN mkdir -p \
        /usr/src/docker-buildx \
        /usr/src/docker-cli \
        /usr/src/docker-compose \
        /out \
        /licenses \
    && tar -xzf /tmp/docker-cli.tar.gz -C /usr/src/docker-cli --strip-components=1 \
    && tar -xzf /tmp/docker-compose.tar.gz -C /usr/src/docker-compose --strip-components=1 \
    && tar -xzf /tmp/docker-buildx.tar.gz -C /usr/src/docker-buildx --strip-components=1 \
    && cp /usr/src/docker-cli/LICENSE /licenses/DOCKER_CLI_LICENSE \
    && cp /usr/src/docker-compose/LICENSE /licenses/DOCKER_COMPOSE_LICENSE \
    && cp /usr/src/docker-buildx/LICENSE /licenses/DOCKER_BUILDX_LICENSE

WORKDIR /usr/src/docker-cli

RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 ./scripts/with-go-mod.sh go build -mod=vendor -trimpath \
        -ldflags="-s -w \
            -X github.com/docker/cli/cli/version.Version=${DOCKER_VERSION} \
            -X github.com/docker/cli/cli/version.GitCommit=v${DOCKER_VERSION} \
            -X github.com/docker/cli/cli/version.BuildTime=unknown" \
        -o /out/docker ./cmd/docker \
    && /out/docker --version | grep -F "Docker version ${DOCKER_VERSION}," \
    && go version -m /out/docker | grep -F 'go1.27.0'

WORKDIR /usr/src/docker-buildx

# Buildx uses the old github.com/docker/docker module only for its frozen random
# name generator. Keep that exact vendored package locally and remove the broad
# daemon module from the client dependency graph before compiling. Its v0.36.1
# module graph also selects vulnerable go-archive and x/mod releases, so raise
# both dependencies to their advisory-fixed releases before compiling.
RUN mkdir -p store/namesgenerator \
    && cp \
        vendor/github.com/docker/docker/pkg/namesgenerator/names-generator.go \
        store/namesgenerator/ \
    && git apply --check --unidiff-zero /tmp/docker-buildx-local-namesgenerator.patch \
    && git apply --unidiff-zero /tmp/docker-buildx-local-namesgenerator.patch \
    && go mod edit -droprequire=github.com/docker/docker \
    && go mod edit -require="github.com/moby/go-archive@v${MOBY_GO_ARCHIVE_VERSION}" \
    && go mod edit -require="golang.org/x/mod@v${X_MOD_VERSION}" \
    && go mod tidy \
    && ! grep -Eq '^[[:space:]]*github.com/docker/docker[[:space:]]' go.mod go.sum

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -mod=mod -trimpath \
        -ldflags="-s -w \
            -X github.com/docker/buildx/version.Version=v${DOCKER_BUILDX_VERSION} \
            -X github.com/docker/buildx/version.Revision=v${DOCKER_BUILDX_VERSION} \
            -X github.com/docker/buildx/version.Package=github.com/docker/buildx" \
        -o /out/docker-buildx ./cmd/buildx \
    && /out/docker-buildx version \
        | grep -F "github.com/docker/buildx v${DOCKER_BUILDX_VERSION} " \
    && go version -m /out/docker-buildx | grep -F 'go1.27.0' \
    && go version -m /out/docker-buildx | grep -Eq \
        "github\\.com/moby/go-archive[[:space:]]+v${MOBY_GO_ARCHIVE_VERSION}([[:space:]]|$)" \
    && go version -m /out/docker-buildx | grep -Eq \
        "golang\\.org/x/mod[[:space:]]+v${X_MOD_VERSION}([[:space:]]|$)" \
    && ! go version -m /out/docker-buildx \
        | grep -Eq '^[[:space:]]*dep[[:space:]]+github.com/docker/docker[[:space:]]'

WORKDIR /usr/src/docker-compose

RUN go mod edit -require="github.com/docker/buildx@v${DOCKER_BUILDX_VERSION}" \
    && go mod edit -require="golang.org/x/mod@v${X_MOD_VERSION}" \
    && go mod edit -replace=github.com/docker/buildx=/usr/src/docker-buildx \
    && go mod tidy \
    && ! grep -Eq '^[[:space:]]*github.com/docker/docker[[:space:]]' go.mod go.sum

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -mod=mod -trimpath \
        -ldflags="-s -w \
            -X github.com/docker/compose/v5/internal.Version=v${DOCKER_COMPOSE_VERSION}" \
        -o /out/docker-compose ./cmd \
    && /out/docker-compose version \
        | grep -F "Docker Compose version v${DOCKER_COMPOSE_VERSION}" \
    && go version -m /out/docker-compose | grep -F 'go1.27.0' \
    && go version -m /out/docker-compose | grep -Eq \
        "golang\\.org/x/mod[[:space:]]+v${X_MOD_VERSION}([[:space:]]|$)" \
    && ! go version -m /out/docker-compose \
        | grep -Eq '^[[:space:]]*dep[[:space:]]+github.com/docker/docker[[:space:]]'

RUN printf '%s  %s\n' \
        '2d81ea060825006fc8f3fe28aa5dc0ffeb80faf325b612c955229157b8c10dc0' \
        /licenses/DOCKER_CLI_LICENSE | sha256sum -c - \
    && printf '%s  %s\n' \
        '58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd' \
        /licenses/DOCKER_COMPOSE_LICENSE | sha256sum -c - \
    && printf '%s  %s\n' \
        'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30' \
        /licenses/DOCKER_BUILDX_LICENSE | sha256sum -c -

FROM golang:1.27.0-trixie@sha256:6212da3924947f4b6a939df02ea627c13f338f1a41d6c3fcb0dd9d076eef46c4 AS go-toolchain

RUN go version | grep -F 'go1.27.0'

FROM node:24.19.0-trixie-slim@sha256:0711b541c1c33a8a530ac4f0d391baa9a15b3d804695b1b24a47daa5fb60e74d AS runtime-base

ARG CADDY_VERSION=2.11.4
ARG CADDY_SECURITY_VERSION=1.1.64
ARG DSH_VERSION=
ARG PYTHON_VERSION=3.12.14
ARG PNPM_VERSION=11.22.0

ENV AUTH_MODE=caddy-security \
    AUTH_STATE_DIR=/data/auth \
    AUTH_COOKIE_INSECURE=false \
    AUTH_TOKEN_LIFETIME=3600 \
    CADDY_TRUSTED_PROXIES=private_ranges \
    CADDY_CONFIG_HOME=/data/caddy/config \
    CADDY_DATA_HOME=/data/caddy/data \
    DSH_HOME=/data/dsh \
    DSH_INTERNAL_PORT=3080 \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_WORKSPACE=/workspace \
    GOMEMLIMIT=128MiB \
    GOMAXPROCS=2 \
    HOME=/home/node \
    PNPM_HOME=/home/node/.local/share/pnpm \
    PATH=/home/node/.local/bin:/home/node/.local/share/pnpm:/opt/dsh/node_modules/.bin:${PATH} \
    PORT=8080

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        file \
        git \
        gosu \
        jq \
        less \
        openssh-client \
        procps \
        ripgrep \
        tini \
        unzip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=caddy-builder /usr/bin/caddy /usr/bin/caddy
COPY --from=caddy-builder /licenses /usr/share/licenses/deepseek-harness-caddy
COPY --from=dsh-deps --chown=node:node /opt/dsh /opt/dsh
COPY --from=pnpm-bundle /opt/pnpm /opt/pnpm
COPY Caddyfile Caddyfile.passthrough /etc/caddy/
COPY --chmod=0755 scripts/entrypoint.sh scripts/healthcheck.sh /usr/local/bin/

RUN install -d -m 0750 -o node -g node \
        /data/auth /data/caddy/config /data/caddy/data /data/dsh \
        /home/node/.cache \
        /home/node/.local \
        /home/node/.local/bin \
        /home/node/.local/share \
        /home/node/.local/share/pnpm \
        /workspace \
    && chown -R node:node /home/node \
    && ln -s /opt/pnpm/bin/pnpm.mjs /usr/local/bin/pnpm \
    && ln -s /opt/pnpm/bin/pnpx.mjs /usr/local/bin/pnpx \
    && resolved_dsh_version="${DSH_VERSION:-$(node -p "require('/opt/dsh/package.json').dependencies['@deepseek-ai/dsh']")}" \
    && printf 'DSH_VERSION=%s\n' "${resolved_dsh_version}" > /etc/deepseek-harness-version \
    && caddy version | grep -F "v${CADDY_VERSION}" \
    && caddy list-modules | grep -Fx 'security' \
    && dsh --version | grep -Fx "${resolved_dsh_version}" \
    && node --version | grep -Fx 'v24.19.0' \
    && pnpm --version | grep -Fx "${PNPM_VERSION}"

ENV DSH_VERSION_FILE=/etc/deepseek-harness-version

WORKDIR /workspace

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=45s --retries=4 CMD ["healthcheck.sh"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

FROM go-toolchain AS workstation-tools

ARG TARGETARCH
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SOURCE_SHA256=454800bd4f854592bcfe79b161f71d56e35940eb7016e48a26dd356adc9d400a
ARG RUFF_VERSION=0.16.4
ARG RUFF_SHA256_AMD64=9cb1234804ddb0f7f57cef3f81623ce5acb990e40af7cce08dc7778c9d7ee96c
ARG RUFF_SHA256_ARM64=08eb65c07016f1b6d2a874777492a230c7d5822bdf34030af217825b57911b0a
ARG UV_VERSION=0.12.5
ARG UV_SHA256_AMD64=68a509da24b06b4223a1c0175fb5eb5bc79342b76cbeff0cfe51ac3f5b17b6b2
ARG UV_SHA256_ARM64=9bf43b4d1a07665bf64d4c4e710930b382321a785e0eb10aac07f46471f86a31
ARG YQ_VERSION=4.53.6
ARG YQ_SHA256_AMD64=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385
ARG YQ_SHA256_ARM64=88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09

RUN case "${TARGETARCH}" in \
        amd64) \
            astral_arch=x86_64; \
            ruff_sha256="${RUFF_SHA256_AMD64}"; \
            uv_sha256="${UV_SHA256_AMD64}"; \
            yq_arch=amd64; \
            yq_sha256="${YQ_SHA256_AMD64}" \
            ;; \
        arm64) \
            astral_arch=aarch64; \
            ruff_sha256="${RUFF_SHA256_ARM64}"; \
            uv_sha256="${UV_SHA256_ARM64}"; \
            yq_arch=arm64; \
            yq_sha256="${YQ_SHA256_ARM64}" \
            ;; \
        *) \
            printf 'unsupported workstation tool architecture: %s\n' "${TARGETARCH}" >&2; \
            exit 1 \
            ;; \
    esac \
    && install -d \
        /out/bin \
        /out/licenses/actionlint \
        /out/licenses/ruff \
        /out/licenses/uv \
        /out/licenses/yq \
        /tmp/actionlint-source \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/actionlint-source.tar.gz \
        "https://codeload.github.com/rhysd/actionlint/tar.gz/refs/tags/v${ACTIONLINT_VERSION}" \
    && printf '%s  %s\n' "${ACTIONLINT_SOURCE_SHA256}" /tmp/actionlint-source.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/actionlint-source.tar.gz -C /tmp/actionlint-source --strip-components=1 \
    && grep -Fxq 'module github.com/rhysd/actionlint' /tmp/actionlint-source/go.mod \
    && cd /tmp/actionlint-source \
    && go mod download \
    && go mod verify \
    && CGO_ENABLED=0 go build \
        -mod=readonly \
        -trimpath \
        -ldflags="-s -w -X github.com/rhysd/actionlint.version=${ACTIONLINT_VERSION}" \
        -o /out/bin/actionlint \
        ./cmd/actionlint \
    && cd / \
    && install -m 0644 /tmp/actionlint-source/LICENSE.txt /out/licenses/actionlint/LICENSE.txt \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/yq \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${yq_arch}" \
    && printf '%s  %s\n' "${yq_sha256}" /tmp/yq | sha256sum -c - \
    && install -m 0755 /tmp/yq /out/bin/yq \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/yq-license \
        "https://raw.githubusercontent.com/mikefarah/yq/v${YQ_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        '697db34dabb21562fe84487a2ccd031fbd45382b89c2cbdec8ef31682c486040' \
        /tmp/yq-license | sha256sum -c - \
    && install -m 0644 /tmp/yq-license /out/licenses/yq/LICENSE \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/uv.tar.gz \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${astral_arch}-unknown-linux-gnu.tar.gz" \
    && printf '%s  %s\n' "${uv_sha256}" /tmp/uv.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/uv.tar.gz -C /tmp \
    && install -m 0755 "/tmp/uv-${astral_arch}-unknown-linux-gnu/uv" /out/bin/uv \
    && install -m 0755 "/tmp/uv-${astral_arch}-unknown-linux-gnu/uvx" /out/bin/uvx \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/uv-license-mit \
        "https://raw.githubusercontent.com/astral-sh/uv/${UV_VERSION}/LICENSE-MIT" \
    && printf '%s  %s\n' \
        '860e3d7a86b84e6a7012c7a635fc64df475cebc6cce34dfeb73a5982ec58176c' \
        /tmp/uv-license-mit | sha256sum -c - \
    && install -m 0644 /tmp/uv-license-mit /out/licenses/uv/LICENSE-MIT \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/uv-license-apache \
        "https://raw.githubusercontent.com/astral-sh/uv/${UV_VERSION}/LICENSE-APACHE" \
    && printf '%s  %s\n' \
        'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4' \
        /tmp/uv-license-apache | sha256sum -c - \
    && install -m 0644 /tmp/uv-license-apache /out/licenses/uv/LICENSE-APACHE \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/ruff.tar.gz \
        "https://github.com/astral-sh/ruff/releases/download/${RUFF_VERSION}/ruff-${astral_arch}-unknown-linux-gnu.tar.gz" \
    && printf '%s  %s\n' "${ruff_sha256}" /tmp/ruff.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/ruff.tar.gz -C /tmp \
    && install -m 0755 "/tmp/ruff-${astral_arch}-unknown-linux-gnu/ruff" /out/bin/ruff \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/ruff-license \
        "https://raw.githubusercontent.com/astral-sh/ruff/${RUFF_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        '2597d854122b77ddc71971564ca2350a37608575ce324adc5650a2b2051c8f18' \
        /tmp/ruff-license | sha256sum -c - \
    && install -m 0644 /tmp/ruff-license /out/licenses/ruff/LICENSE \
    && /out/bin/actionlint -version | grep -Fx "${ACTIONLINT_VERSION}" \
    && go version -m /out/bin/actionlint | grep -F 'go1.27.0' \
    && /out/bin/yq --version | grep -F "version v${YQ_VERSION}" \
    && /out/bin/uv --version | grep -F "uv ${UV_VERSION} " \
    && /out/bin/uvx --version | grep -F "uvx ${UV_VERSION} " \
    && /out/bin/ruff --version | grep -Fx "ruff ${RUFF_VERSION}"

FROM runtime-base AS workstation

WORKDIR /

ARG DOCKER_BUILDX_VERSION=0.36.1
ARG DOCKER_COMPOSE_VERSION=5.5.0
ARG DOCKER_VERSION=29.7.2
ARG GO_VERSION=1.27.0
ARG NPM_VERSION=11.19.0
ARG PYTHON_VERSION=3.12.14
ARG PYTEST_VERSION=9.1.1
ARG PNPM_VERSION=11.22.0

ENV AUTH_STATE_DIR=/data/auth \
    CADDY_CONFIG_HOME=/data/caddy/config \
    CADDY_DATA_HOME=/data/caddy/data \
    DSH_IMAGE_VARIANT=workstation \
    DSH_HOME=/data/dsh \
    GOPATH=/home/node/go \
    PIPX_BIN_DIR=/home/node/.local/bin \
    PIPX_HOME=/home/node/.local/pipx \
    PATH=/home/node/.local/bin:/home/node/go/bin:/usr/local/go/bin:/home/node/.local/share/pnpm:/opt/dsh/node_modules/.bin:${PATH}

COPY --from=go-toolchain /usr/local/go /usr/local/go
COPY --from=docker-tools-builder /out/docker /usr/local/bin/docker
COPY --from=docker-tools-builder /out/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
COPY --from=docker-tools-builder /out/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
COPY --from=docker-tools-builder /licenses /usr/share/licenses/deepseek-harness-docker
COPY --from=workstation-tools /out/bin/ /usr/local/bin/
COPY --from=workstation-tools /out/licenses/ /usr/share/licenses/deepseek-harness-workstation-tools/
COPY --from=python-toolchain /usr/local /usr/local
COPY --from=npm-bundle /opt/npm /opt/npm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bat \
        bind9-dnsutils \
        build-essential \
        clang \
        clang-format \
        cmake \
        diffutils \
        direnv \
        entr \
        fd-find \
        fzf \
        gdb \
        gh \
        git-lfs \
        htop \
        hyperfine \
        iproute2 \
        iputils-ping \
        just \
        libbz2-dev \
        libffi-dev \
        liblzma-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        libtool \
        lsof \
        mtr-tiny \
        ncdu \
        netcat-openbsd \
        ninja-build \
        openssl \
        patch \
        pigz \
        pipx \
        pkg-config \
        pre-commit \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        rsync \
        shellcheck \
        shfmt \
        sqlite3 \
        strace \
        tmux \
        tree \
        vim \
        wget \
        xz-utils \
        yamllint \
        zip \
        zstd \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf \
        /usr/local/lib/node_modules/corepack \
        /usr/local/lib/node_modules/npm \
    && rm -f \
        /usr/local/bin/corepack \
        /usr/local/bin/npm \
        /usr/local/bin/npx \
    && ln -s /opt/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s /opt/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && ln -s /usr/bin/batcat /usr/local/bin/bat \
    && install -d -m 0750 -o node -g node \
        /home/node/.cache \
        /home/node/.local \
        /home/node/.local/bin \
        /home/node/.local/pipx \
        /home/node/.local/share/pnpm \
        /home/node/go \
    && chown -R node:node /home/node \
    && test "$(pnpm --version)" = "${PNPM_VERSION}" \
    && test "$(npm --version)" = "${NPM_VERSION}" \
    && test "$(npx --version)" = "${NPM_VERSION}" \
    && docker --version | grep -F "Docker version ${DOCKER_VERSION}," \
    && docker compose version | grep -F "Docker Compose version v${DOCKER_COMPOSE_VERSION}" \
    && docker buildx version | grep -F "github.com/docker/buildx v${DOCKER_BUILDX_VERSION} " \
    && go version | grep -F "go${GO_VERSION}" \
    && python3 --version | grep -Fx "Python ${PYTHON_VERSION}" \
    && python3 -m pytest --version | grep -Fx "pytest ${PYTEST_VERSION}" \
    && gcc --version \
    && ! command -v rustc \
    && ! command -v cargo \
    && ! command -v corepack

COPY profile.d/workstation.sh /etc/profile.d/deepseek-harness-workstation.sh
COPY --chmod=0755 scripts/configure-docker-socket-access.sh /usr/local/bin/

RUN test -d /home/node \
    && test ! -L /home/node \
    && test -d /workspace \
    && test ! -L /workspace

WORKDIR /workspace

VOLUME ["/home/node"]

FROM runtime-base AS runtime

ARG PNPM_VERSION=11.22.0

ENV DSH_IMAGE_VARIANT=runtime

RUN rm -rf \
        /usr/local/lib/node_modules/corepack \
        /usr/local/lib/node_modules/npm \
    && rm -f \
        /usr/local/bin/corepack \
        /usr/local/bin/npm \
        /usr/local/bin/npx \
    && test "$(pnpm --version)" = "${PNPM_VERSION}" \
    && ! command -v npm \
    && ! command -v corepack \
    && ! command -v gcc \
    && ! command -v python3 \
    && ! command -v go \
    && ! command -v rustc
