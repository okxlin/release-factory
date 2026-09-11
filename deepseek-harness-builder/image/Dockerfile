# syntax=docker/dockerfile:1.26.0@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom

# Required base-image arguments are validated from components.lock.json.

ARG CADDY_IMAGE
ARG PYTHON_IMAGE
ARG NODE_IMAGE
ARG GO_IMAGE

FROM ${CADDY_IMAGE} AS caddy-builder

ARG GO_AUTHCRUNCH_SOURCE_SHA256
ARG CADDY_LICENSE_SHA256
ARG CADDY_SECURITY_LICENSE_SHA256
ARG CEL_GO_LICENSE_SHA256
ARG GO_AUTHCRUNCH_LICENSE_SHA256
ARG CADDY_RATELIMIT_LICENSE_SHA256
ARG CADDY_VERSION
ARG CADDY_SOURCE_ARCHIVE_SHA256
ARG CADDY_SECURITY_VERSION
ARG CEL_GO_VERSION
ARG GO_AUTHCRUNCH_VERSION
ARG GRPC_VERSION
ARG KLAUSPOST_COMPRESS_VERSION
ARG X_CRYPTO_VERSION
ARG X_TEXT_VERSION
ARG CADDY_RATELIMIT_REF

COPY patches/caddy-cel-go-v0.30.patch /tmp/caddy-cel-go-v0.30.patch
COPY patches/caddy-cel-go-module-relocation.patch /tmp/caddy-cel-go-module-relocation.patch
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
    && git apply /tmp/caddy-cel-go-v0.30.patch \
    && git apply --check --unidiff-zero /tmp/caddy-cel-go-module-relocation.patch \
    && git apply --unidiff-zero /tmp/caddy-cel-go-module-relocation.patch \
    && PATH="/usr/local/go/bin:${PATH}" go mod edit \
        -droprequire=github.com/google/cel-go \
        -require="cel.dev/cel-go@v${CEL_GO_VERSION}" \
    && grep -Eq "^[[:space:]]+cel\.dev/cel-go v${CEL_GO_VERSION}[[:space:]]*$" go.mod \
    && ! grep -R -F 'github.com/google/cel-go' modules/caddyhttp

# caddy-security's local password flow does not use go-authcrunch's GPG public
# key parser. Remove that parser because x/crypto/openpgp is unmaintained and
# has no fixed release, then test the patched identity package before linking.
RUN wget -qO /tmp/go-authcrunch.tar.gz \
        "https://github.com/greenpau/go-authcrunch/archive/refs/tags/v${GO_AUTHCRUNCH_VERSION}.tar.gz" \
    && printf '%s  %s\n' \
        "${GO_AUTHCRUNCH_SOURCE_SHA256}" \
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
        --replace "google.golang.org/grpc=google.golang.org/grpc@v${GRPC_VERSION}" \
        --replace "github.com/klauspost/compress=github.com/klauspost/compress@v${KLAUSPOST_COMPRESS_VERSION}" \
        --replace "golang.org/x/crypto=golang.org/x/crypto@v${X_CRYPTO_VERSION}" \
        --replace "golang.org/x/text=golang.org/x/text@v${X_TEXT_VERSION}" \
    && ./caddy version \
    && ./caddy list-modules | grep -Fx 'security' \
    && ./caddy list-modules | grep -Fx 'http.handlers.authenticator' \
    && ./caddy list-modules | grep -Fx 'http.authentication.providers.authorizer' \
    && ./caddy list-modules | grep -Fx 'http.handlers.rate_limit'

RUN PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq "google\.golang\.org/grpc[[:space:]]+v${GRPC_VERSION}" \
    && PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq "github\\.com/klauspost/compress[[:space:]]+v${KLAUSPOST_COMPRESS_VERSION}" \
    && PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq "cel\.dev/cel-go[[:space:]]+v${CEL_GO_VERSION}" \
    && PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq "golang\.org/x/crypto[[:space:]]+v${X_CRYPTO_VERSION}" \
    && PATH="/usr/local/go/bin:${PATH}" go version -m ./caddy | grep -Eq "golang\.org/x/text[[:space:]]+v${X_TEXT_VERSION}" \
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
        "${CADDY_LICENSE_SHA256}" \
        /licenses/CADDY_LICENSE | sha256sum -c - \
    && wget -qO /licenses/CADDY_SECURITY_LICENSE \
        "https://raw.githubusercontent.com/greenpau/caddy-security/v${CADDY_SECURITY_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        "${CADDY_SECURITY_LICENSE_SHA256}" \
        /licenses/CADDY_SECURITY_LICENSE | sha256sum -c - \
    && wget -qO /licenses/CEL_GO_LICENSE \
        "https://raw.githubusercontent.com/cel-expr/cel-go/v${CEL_GO_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        "${CEL_GO_LICENSE_SHA256}" \
        /licenses/CEL_GO_LICENSE | sha256sum -c - \
    && wget -qO /licenses/GO_AUTHCRUNCH_LICENSE \
        "https://raw.githubusercontent.com/greenpau/go-authcrunch/v${GO_AUTHCRUNCH_VERSION}/LICENSE" \
    && printf '%s  %s\n' \
        "${GO_AUTHCRUNCH_LICENSE_SHA256}" \
        /licenses/GO_AUTHCRUNCH_LICENSE | sha256sum -c - \
    && wget -qO /licenses/CADDY_RATELIMIT_LICENSE \
        "https://raw.githubusercontent.com/mholt/caddy-ratelimit/${CADDY_RATELIMIT_REF}/LICENSE" \
    && printf '%s  %s\n' \
        "${CADDY_RATELIMIT_LICENSE_SHA256}" \
        /licenses/CADDY_RATELIMIT_LICENSE | sha256sum -c -

FROM ${PYTHON_IMAGE} AS python-toolchain

ARG PYTHON_VERSION
ARG PYTEST_VERSION

COPY python-requirements.lock /tmp/python-requirements.txt

RUN python3 --version | grep -Fx "Python ${PYTHON_VERSION}" \
    && test "$(python3 -c 'import platform; print(platform.python_version())')" = "${PYTHON_VERSION}" \
    && python3 -m pip --version | grep -F '(python 3.12)' \
    && python3 -m venv /tmp/python-venv \
    && /tmp/python-venv/bin/python --version | grep -Fx "Python ${PYTHON_VERSION}" \
    && python3 -m pip install \
        --no-cache-dir \
        --disable-pip-version-check \
        --only-binary=:all: \
        --require-hashes \
        --requirement /tmp/python-requirements.txt \
    && python3 -m pytest --version | grep -Fx "pytest ${PYTEST_VERSION}" \
    && rm -f /tmp/python-requirements.txt

FROM ${NODE_IMAGE} AS dsh-deps

ARG DSH_VERSION
ARG DSH_SOURCE_VERSION
ARG DSH_SOURCE_REF
ARG DSH_SOURCE_COMMIT
ARG DSH_SOURCE_ARCHIVE_SHA256
ARG PYTHON_VERSION
ARG PYTEST_VERSION
ARG PNPM_VERSION

ADD --checksum=sha256:${DSH_SOURCE_ARCHIVE_SHA256} \
    https://codeload.github.com/deepseek-ai/deepseek-harness/tar.gz/${DSH_SOURCE_COMMIT} /tmp/dsh-source.tar.gz

ENV PYTHON=/usr/local/bin/python3

COPY --from=python-toolchain /usr/local /usr/local

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake \
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
COPY scripts/patch-dsh-authenticated-settings.mjs /tmp/patch-dsh-authenticated-settings.mjs
COPY scripts/patch-dsh-cli-runtime-dependency.mjs /tmp/patch-dsh-cli-runtime-dependency.mjs
COPY scripts/patch-dsh-runtime-package.mjs /tmp/patch-dsh-runtime-package.mjs

RUN corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && resolved_dsh_version="${DSH_VERSION:-${DSH_SOURCE_VERSION}}" \
    && test "${DSH_SOURCE_REF}" = "dsh-v${DSH_SOURCE_VERSION}" \
    && printf '%s\n' "${DSH_SOURCE_COMMIT}" | grep -Eq '^[a-f0-9]{40}$' \
    && printf '%s  %s\n' "${DSH_SOURCE_ARCHIVE_SHA256}" /tmp/dsh-source.tar.gz | sha256sum -c - \
    && if [ "${resolved_dsh_version}" = "${DSH_SOURCE_VERSION}" ]; then \
        mkdir -p /tmp/dsh-source \
        && tar -xzf /tmp/dsh-source.tar.gz -C /tmp/dsh-source --strip-components=1 \
        && test "$(node -p "require('/tmp/dsh-source/package.json').version")" = "${DSH_SOURCE_VERSION}" \
        && test "$(node -p "require('/tmp/dsh-source/apps/cli/package.json').version")" = "${DSH_SOURCE_VERSION}" \
        && cd /tmp/dsh-source \
        && CI=true pnpm install --frozen-lockfile \
        && node /tmp/patch-dsh-cli-runtime-dependency.mjs apps/cli/package.json \
        && CI=true pnpm install --lockfile-only --ignore-scripts \
        && DSH_CLIENT_COMMIT_HASH="${DSH_SOURCE_COMMIT}" CI=true pnpm run build:official \
        && mkdir -p /tmp/dsh-pack/dsh /tmp/dsh-pack/vendor \
        && npm_execpath="$(command -v pnpm)" DSH_CLIENT_COMMIT_HASH="${DSH_SOURCE_COMMIT}" CI=true pnpm exec tsx scripts/release/pack.ts --family dsh --out /tmp/dsh-pack/dsh \
        && npm_execpath="$(command -v pnpm)" DSH_CLIENT_COMMIT_HASH="${DSH_SOURCE_COMMIT}" CI=true pnpm exec tsx scripts/release/pack.ts --family vendor --out /tmp/dsh-pack/vendor \
        && cd /opt/dsh \
        && npm init --yes >/dev/null \
        && npm install --ignore-scripts --include=optional --no-audit --no-fund --package-lock=false \
            /tmp/dsh-pack/dsh/*.tgz /tmp/dsh-pack/vendor/*.tgz \
        && node /opt/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs \
        && if find node_modules -type d -path '*/fs-ext' -print -quit | grep -q .; then \
            npm install-scripts approve fs-ext \
            && npm rebuild --foreground-scripts koffi node-pty fs-ext \
            && find node_modules \
                -path '*/fs-ext/build/Release/fs_ext.node' \
                -type f -print -quit | grep -q . \
            && node -e "require('fs-ext')"; \
          else \
            npm rebuild --foreground-scripts koffi node-pty; \
          fi \
        && if find node_modules -type d -path '*/@deepseek-ai/node-addon-system' -print -quit | grep -q .; then \
            node --input-type=module -e "import { closeSync, openSync, unlinkSync } from 'node:fs'; import { tryLockExclusive } from '@deepseek-ai/node-addon-system/flock'; const path='/tmp/dsh-flock-probe'; const fd=openSync(path, 'w'); try { await tryLockExclusive(fd); } finally { closeSync(fd); unlinkSync(path); }"; \
          fi \
        && node /tmp/patch-dsh-directory-picker.mjs /opt/dsh/node_modules \
        && node /tmp/patch-dsh-authenticated-settings.mjs /opt/dsh/node_modules; \
      else \
        test "$(node -p "require('./package.json').dependencies['@deepseek-ai/dsh']")" = "${resolved_dsh_version}" \
        && pnpm install --prod --frozen-lockfile --trust-lockfile \
        && node /tmp/patch-dsh-directory-picker.mjs \
        && node /tmp/patch-dsh-authenticated-settings.mjs; \
      fi \
    && cd /opt/dsh \
    && node /tmp/patch-dsh-runtime-package.mjs /opt/dsh "${resolved_dsh_version}" \
    && rm -f /tmp/patch-dsh-directory-picker.mjs \
        /tmp/patch-dsh-authenticated-settings.mjs \
        /tmp/patch-dsh-cli-runtime-dependency.mjs \
        /tmp/patch-dsh-runtime-package.mjs \
        /tmp/dsh-source.tar.gz \
    && rm -rf /tmp/dsh-source /tmp/dsh-pack \
    && /opt/dsh/node_modules/.bin/dsh --version | grep -Fx "${resolved_dsh_version}" \
    && node_pty_arch="$(node -p "process.arch")" \
    && case "${node_pty_arch}" in x64|arm64) ;; *) exit 1 ;; esac \
    && find node_modules \
        \( \
            -path '*/node-pty/build/Release/pty.node' \
            -o -path "*/node-pty/prebuilds/linux-${node_pty_arch}/pty.node" \
        \) \
        -type f -print -quit | grep -q .

FROM ${NODE_IMAGE} AS pnpm-bundle

ARG PNPM_ARCHIVE_SHA256
ARG PNPM_VERSION

# The registry tarball is checksum-pinned so the runtime can provide pnpm
# without retaining npm or Corepack.
ADD --checksum=sha256:${PNPM_ARCHIVE_SHA256} \
    https://registry.npmjs.org/pnpm/-/pnpm-${PNPM_VERSION}.tgz /tmp/pnpm.tgz

RUN mkdir -p /opt/pnpm \
    && tar -xzf /tmp/pnpm.tgz -C /opt/pnpm --strip-components=1 \
    && test "$(node -p "require('/opt/pnpm/package.json').version")" = "${PNPM_VERSION}" \
    && test "$(node /opt/pnpm/bin/pnpm.mjs --version)" = "${PNPM_VERSION}" \
    && chmod 0755 /opt/pnpm/bin/pnpm.mjs /opt/pnpm/bin/pnpx.mjs \
    && test -x /opt/pnpm/bin/pnpm.mjs \
    && test -x /opt/pnpm/bin/pnpx.mjs \
    && rm -f /tmp/pnpm.tgz

FROM ${NODE_IMAGE} AS npm-bundle

ARG NPM_ARCHIVE_SHA256
ARG NPM_VERSION

# Node.js 24 currently bundles an older npm release. Keep workstation npm
# independently checksum-pinned so security fixes do not wait for a new Node
# base-image release, while the runtime target can continue omitting npm.
ADD --checksum=sha256:${NPM_ARCHIVE_SHA256} \
    https://registry.npmjs.org/npm/-/npm-${NPM_VERSION}.tgz /tmp/npm.tgz

RUN mkdir -p /opt/npm \
    && tar -xzf /tmp/npm.tgz -C /opt/npm --strip-components=1 \
    && test "$(node -p "require('/opt/npm/package.json').version")" = "${NPM_VERSION}" \
    && test "$(node /opt/npm/bin/npm-cli.js --version)" = "${NPM_VERSION}" \
    && test "$(node /opt/npm/bin/npx-cli.js --version)" = "${NPM_VERSION}" \
    && rm -f /tmp/npm.tgz

FROM ${GO_IMAGE} AS docker-tools-builder

ARG DOCKER_CLI_LICENSE_SHA256
ARG DOCKER_COMPOSE_LICENSE_SHA256
ARG DOCKER_BUILDX_LICENSE_SHA256
ARG DOCKER_ARCHIVE_SHA256
ARG DOCKER_COMPOSE_ARCHIVE_SHA256
ARG DOCKER_BUILDX_ARCHIVE_SHA256
ARG DOCKER_BUILDX_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_VERSION
ARG GO_VERSION
ARG MOBY_GO_ARCHIVE_VERSION
ARG X_MOD_VERSION

ADD --checksum=sha256:${DOCKER_ARCHIVE_SHA256} \
    https://codeload.github.com/docker/cli/tar.gz/refs/tags/v${DOCKER_VERSION} /tmp/docker-cli.tar.gz
ADD --checksum=sha256:${DOCKER_COMPOSE_ARCHIVE_SHA256} \
    https://codeload.github.com/docker/compose/tar.gz/refs/tags/v${DOCKER_COMPOSE_VERSION} /tmp/docker-compose.tar.gz
ADD --checksum=sha256:${DOCKER_BUILDX_ARCHIVE_SHA256} \
    https://codeload.github.com/docker/buildx/tar.gz/refs/tags/v${DOCKER_BUILDX_VERSION} /tmp/docker-buildx.tar.gz

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
    && go version -m /out/docker | grep -F "go${GO_VERSION}" \
    && CGO_ENABLED=0 ./scripts/with-go-mod.sh go list -mod=vendor -deps ./cmd/docker \
        > /licenses/DOCKER_CLI_GO_PACKAGES.txt

WORKDIR /usr/src/docker-buildx

# Retain upstream client source. The package manifests below prove that the
# legacy Docker module contributes only namesgenerator, not daemon AuthZ code.
# go-archive and x/mod fixes still apply to code used by these clients.
RUN go mod edit -require="github.com/moby/go-archive@v${MOBY_GO_ARCHIVE_VERSION}" \
    && go mod edit -require="golang.org/x/mod@v${X_MOD_VERSION}" \
    && go mod tidy

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
    && go version -m /out/docker-buildx | grep -F "go${GO_VERSION}" \
    && go version -m /out/docker-buildx | grep -Eq \
        "github\\.com/moby/go-archive[[:space:]]+v${MOBY_GO_ARCHIVE_VERSION}([[:space:]]|$)" \
    && go version -m /out/docker-buildx | grep -Eq \
        "golang\\.org/x/mod[[:space:]]+v${X_MOD_VERSION}([[:space:]]|$)" \
    && CGO_ENABLED=0 go list -mod=mod -deps ./cmd/buildx \
        > /licenses/DOCKER_BUILDX_GO_PACKAGES.txt

WORKDIR /usr/src/docker-compose

RUN go mod edit -require="github.com/docker/buildx@v${DOCKER_BUILDX_VERSION}" \
    && go mod edit -require="github.com/moby/go-archive@v${MOBY_GO_ARCHIVE_VERSION}" \
    && go mod edit -require="golang.org/x/mod@v${X_MOD_VERSION}" \
    && go mod tidy

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -mod=mod -trimpath \
        -ldflags="-s -w \
            -X github.com/docker/compose/v5/internal.Version=v${DOCKER_COMPOSE_VERSION}" \
        -o /out/docker-compose ./cmd \
    && /out/docker-compose version \
        | grep -F "Docker Compose version v${DOCKER_COMPOSE_VERSION}" \
    && go version -m /out/docker-compose | grep -F "go${GO_VERSION}" \
    && if compose_x_mod_version="$(go list -m -f '{{.Version}}' golang.org/x/mod 2>/dev/null)"; then \
        test "${compose_x_mod_version}" = "v${X_MOD_VERSION}"; \
    fi \
    && CGO_ENABLED=0 go list -mod=mod -deps ./cmd \
        > /licenses/DOCKER_COMPOSE_GO_PACKAGES.txt

RUN grep -Fx 'github.com/docker/cli/cmd/docker' /licenses/DOCKER_CLI_GO_PACKAGES.txt \
    && grep -Fx 'github.com/docker/buildx/cmd/buildx' /licenses/DOCKER_BUILDX_GO_PACKAGES.txt \
    && grep -Fx 'github.com/docker/compose/v5/cmd' /licenses/DOCKER_COMPOSE_GO_PACKAGES.txt \
    && ! grep -Eq '^github.com/docker/docker(/|$)' /licenses/DOCKER_CLI_GO_PACKAGES.txt \
    && for component in BUILDX COMPOSE; do \
        legacy_packages="$(grep -E '^github.com/docker/docker(/|$)' "/licenses/DOCKER_${component}_GO_PACKAGES.txt" || true)"; \
        test -z "${legacy_packages}" || test "${legacy_packages}" \
            = 'github.com/docker/docker/pkg/namesgenerator' || exit 1; \
    done \
    && ! grep -E '^github.com/(docker/docker|moby/moby(/v[0-9]+)?)/(pkg/authorization|daemon)(/|$)' \
        /licenses/DOCKER_*_GO_PACKAGES.txt

RUN printf '%s  %s\n' \
        "${DOCKER_CLI_LICENSE_SHA256}" \
        /licenses/DOCKER_CLI_LICENSE | sha256sum -c - \
    && printf '%s  %s\n' \
        "${DOCKER_COMPOSE_LICENSE_SHA256}" \
        /licenses/DOCKER_COMPOSE_LICENSE | sha256sum -c - \
    && printf '%s  %s\n' \
        "${DOCKER_BUILDX_LICENSE_SHA256}" \
        /licenses/DOCKER_BUILDX_LICENSE | sha256sum -c -

FROM ${GO_IMAGE} AS go-toolchain

ARG GO_VERSION

RUN go version | grep -F "go${GO_VERSION}"

FROM ${NODE_IMAGE} AS runtime-base

ARG NODE_VERSION
ARG CADDY_VERSION
ARG CADDY_SECURITY_VERSION
ARG DSH_VERSION
ARG DSH_SOURCE_VERSION
ARG PYTHON_VERSION
ARG PNPM_VERSION

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
COPY components.lock.json /usr/share/deepseek-harness/components.lock.json
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
    && resolved_dsh_version="${DSH_VERSION:-${DSH_SOURCE_VERSION}}" \
    && printf 'DSH_VERSION=%s\n' "${resolved_dsh_version}" > /etc/deepseek-harness-version \
    && caddy version | grep -F "v${CADDY_VERSION}" \
    && caddy list-modules | grep -Fx 'security' \
    && dsh --version | grep -Fx "${resolved_dsh_version}" \
    && node --version | grep -Fx "v${NODE_VERSION}" \
    && pnpm --version | grep -Fx "${PNPM_VERSION}"

ENV DSH_VERSION_FILE=/etc/deepseek-harness-version

WORKDIR /workspace

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=45s --retries=4 CMD ["healthcheck.sh"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

FROM go-toolchain AS workstation-tools

ARG YQ_LICENSE_SHA256
ARG UV_LICENSE_MIT_SHA256
ARG UV_LICENSE_APACHE_SHA256
ARG RUFF_LICENSE_SHA256
ARG TARGETARCH
ARG ACTIONLINT_VERSION
ARG ACTIONLINT_SOURCE_SHA256
ARG RUFF_VERSION
ARG RUFF_SHA256_AMD64
ARG RUFF_SHA256_ARM64
ARG UV_VERSION
ARG UV_SHA256_AMD64
ARG UV_SHA256_ARM64
ARG YQ_VERSION
ARG YQ_SHA256_AMD64
ARG YQ_SHA256_ARM64

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
        "${YQ_LICENSE_SHA256}" \
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
        "${UV_LICENSE_MIT_SHA256}" \
        /tmp/uv-license-mit | sha256sum -c - \
    && install -m 0644 /tmp/uv-license-mit /out/licenses/uv/LICENSE-MIT \
    && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSLo /tmp/uv-license-apache \
        "https://raw.githubusercontent.com/astral-sh/uv/${UV_VERSION}/LICENSE-APACHE" \
    && printf '%s  %s\n' \
        "${UV_LICENSE_APACHE_SHA256}" \
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
        "${RUFF_LICENSE_SHA256}" \
        /tmp/ruff-license | sha256sum -c - \
    && install -m 0644 /tmp/ruff-license /out/licenses/ruff/LICENSE \
    && /out/bin/actionlint -version | grep -Fx "${ACTIONLINT_VERSION}" \
    && go version -m /out/bin/actionlint | grep -F "go${GO_VERSION}" \
    && /out/bin/yq --version | grep -F "version v${YQ_VERSION}" \
    && /out/bin/uv --version | grep -F "uv ${UV_VERSION} " \
    && /out/bin/uvx --version | grep -F "uvx ${UV_VERSION} " \
    && /out/bin/ruff --version | grep -Fx "ruff ${RUFF_VERSION}"

FROM runtime-base AS workstation

WORKDIR /

ARG DOCKER_BUILDX_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG DOCKER_VERSION
ARG GO_VERSION
ARG NPM_VERSION
ARG PYTHON_VERSION
ARG PYTEST_VERSION
ARG PNPM_VERSION

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

ARG PNPM_VERSION

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
