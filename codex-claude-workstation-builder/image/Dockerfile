# codex-claude-workstation Dockerfile v2
# Ubuntu 24.04 base, linux/amd64 and linux/arm64
FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TARGETARCH=amd64
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=24
ARG NPM_VERSION=12.0.2
ARG GO_VERSION=1.27.0
ARG GO_SHA256_AMD64=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685
ARG GO_SHA256_ARM64=51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda
ARG RUST_VERSION=stable
ARG BUN_VERSION=latest
ARG DENO_VERSION=latest
ARG ACTIONLINT_VERSION=1.7.12
ARG CODE_SERVER_TAR_VERSION=7.5.22
ARG MIHOMO_VERSION=1.19.30
ARG MIHOMO_SOURCE_REF=ac017cdd246ce8bd547653d927e7bf77d7ee73d5
ARG MIHOMO_SOURCE_SHA256=971dd4533e4e2c3dad7473e8115200da8c0d7471b4b61da54da896345c5b3850
ARG SING_BOX_VERSION=1.14.0
ARG SING_BOX_SOURCE_REF=0b8995879f29a9b98ee027bc17b75e101445b238
ARG SING_BOX_SOURCE_SHA256=faa17ef1634429371401b495f32c498fa35b92e5872dce245ba44a9155f95f14
ARG XRAY_VERSION=26.7.28
ARG XRAY_SOURCE_REF=5ca6f4b7d4dc20a881d4330e498892697627ec0c
ARG XRAY_SOURCE_SHA256=45de3ead5186fea442b04c662c554a1ffd1d7bd9093a83410f2edabe74fb766e
ARG PROXY_X_CRYPTO_VERSION=0.55.0
ARG PROXY_X_NET_VERSION=0.58.0
ARG PROXY_X_TEXT_VERSION=0.41.0
ARG PROXY_GRPC_VERSION=1.83.1
ARG PNPM_VERSION=latest
ARG YARN_VERSION=stable
ARG RUFF_VERSION=latest
ARG BLACK_VERSION=latest
ARG MYPY_VERSION=latest
ARG CODE_SERVER_EXTENSIONS="anthropic.claude-code openai.chatgpt ms-python.python charliermarsh.ruff redhat.vscode-yaml tamasfe.even-better-toml editorconfig.editorconfig esbenp.prettier-vscode dbaeumer.vscode-eslint ms-azuretools.vscode-docker ms-ceintl.vscode-language-pack-zh-hans"

# ── Locale ──
RUN apt-get update && apt-get install -y locales \
    && locale-gen zh_CN.UTF-8 \
    && update-locale LANG=zh_CN.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ── Docker repo (needs curl + gpg first) ──
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

# ── System packages ──
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
    bat \
    bash \
    bind9-dnsutils \
    build-essential \
    bubblewrap \
    ca-certificates \
    clang \
    cmake \
    curl \
    diffutils \
    direnv \
    docker-buildx-plugin \
    docker-ce-cli \
    docker-compose-plugin \
    fd-find \
    file \
    fzf \
    gettext-base \
    gh \
    git \
    git-lfs \
    htop \
    httpie \
    iotop \
    iproute2 \
    iputils-ping \
    jq \
    less \
    libbz2-dev \
    libffi-dev \
    liblzma-dev \
    libreadline-dev \
    libsqlite3-dev \
    libssl-dev \
    lsof \
    mariadb-client \
    maven \
    mtr \
    ncdu \
    nethogs \
    net-tools \
    netcat-openbsd \
    openjdk-21-jdk-headless \
    openssh-client \
    openssl \
    patch \
    pigz \
    pipx \
    pkg-config \
    postgresql-client \
    pre-commit \
    procps \
    python3 \
    python3-dev \
    python3-pip \
    python3-pytest \
    python3-venv \
    redis-tools \
    ripgrep \
    rsync \
    shellcheck \
    shfmt \
    sqlite3 \
    strace \
    sudo \
    supervisor \
    tig \
    tini \
    tldr \
    tmux \
    tree \
    tzdata \
    uidmap \
    unzip \
    vim \
    wget \
    xz-utils \
    yamllint \
    zip \
    zstd \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

# ── Node.js via NodeSource ──
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "npm@${NPM_VERSION}"

# ── Go ──
RUN dpkg_arch="$(dpkg --print-architecture)" \
    && case "${dpkg_arch}" in \
        amd64) go_arch="amd64"; go_sha256="${GO_SHA256_AMD64}" ;; \
        arm64) go_arch="arm64"; go_sha256="${GO_SHA256_ARM64}" ;; \
        *) echo "unsupported architecture for Go install: ${dpkg_arch}" >&2; exit 1 ;; \
    esac \
    && if [ "${GO_VERSION}" = "latest" ]; then \
        go_version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | sed -n '1p')"; \
    else \
        go_version="go${GO_VERSION#go}"; \
    fi \
    && [[ "${go_version}" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    && [[ "${go_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] \
    && go_asset="${go_version}.linux-${go_arch}.tar.gz" \
    && curl -fsSL "https://go.dev/dl/${go_asset}" -o "/tmp/${go_asset}" \
    && printf '%s  %s\n' "${go_sha256}" "/tmp/${go_asset}" | sha256sum -c - \
    && tar -C /usr/local -xzf "/tmp/${go_asset}" \
    && rm "/tmp/${go_asset}" \
    && echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh

# ── Rust ──
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && chmod +x /tmp/rustup-init.sh \
    && mkdir -p /opt/rust /home/dev \
    && CARGO_HOME=/opt/rust/cargo RUSTUP_HOME=/opt/rust/rustup /tmp/rustup-init.sh -y --default-toolchain "${RUST_VERSION}" \
    && rm /tmp/rustup-init.sh

# ── Bun ──
RUN if [ "${BUN_VERSION}" = "latest" ]; then \
        curl -fsSL https://bun.sh/install | bash; \
    else \
        curl -fsSL https://bun.sh/install | bash -s -- "bun-v${BUN_VERSION#v}"; \
    fi \
    && mv /root/.bun /opt/bun

# ── Deno ──
RUN if [ "${DENO_VERSION}" = "latest" ]; then \
        curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/opt/deno sh; \
    else \
        curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/opt/deno sh -s "v${DENO_VERSION#v}"; \
    fi

# ── uv / uvx ──
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# ── Python quality tools ──
RUN install_pipx_tool() { \
        local name="$1"; \
        local version="$2"; \
        if [ "${version}" = "latest" ]; then \
            PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install "${name}"; \
        else \
            PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install "${name}==${version}"; \
        fi; \
    }; \
    install_pipx_tool ruff "${RUFF_VERSION}" \
    && install_pipx_tool black "${BLACK_VERSION}" \
    && install_pipx_tool mypy "${MYPY_VERSION}"

# ── yq ──
RUN dpkg_arch="$(dpkg --print-architecture)" \
    && case "${dpkg_arch}" in \
        amd64) yq_arch="amd64" ;; \
        arm64) yq_arch="arm64" ;; \
        *) echo "unsupported architecture for yq install: ${dpkg_arch}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# ── actionlint ──
RUN dpkg_arch="$(dpkg --print-architecture)" \
    && case "${dpkg_arch}" in \
        amd64) actionlint_arch="amd64" ;; \
        arm64) actionlint_arch="arm64" ;; \
        *) echo "unsupported architecture for actionlint install: ${dpkg_arch}" >&2; exit 1 ;; \
    esac \
    && actionlint_version="${ACTIONLINT_VERSION#v}" \
    && actionlint_asset="actionlint_${actionlint_version}_linux_${actionlint_arch}.tar.gz" \
    && curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${actionlint_version}/${actionlint_asset}" -o "/tmp/${actionlint_asset}" \
    && curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${actionlint_version}/actionlint_${actionlint_version}_checksums.txt" -o /tmp/actionlint_checksums.txt \
    && grep "  ${actionlint_asset}$" /tmp/actionlint_checksums.txt > /tmp/actionlint.sha256 \
    && (cd /tmp && sha256sum -c /tmp/actionlint.sha256) \
    && tar -xzf "/tmp/${actionlint_asset}" -C /tmp actionlint \
    && install -m 0755 /tmp/actionlint /usr/local/bin/actionlint \
    && actionlint --version \
    && rm -f "/tmp/${actionlint_asset}" /tmp/actionlint_checksums.txt /tmp/actionlint.sha256 /tmp/actionlint

# ── Proxy cores: Clash.Meta (mihomo), sing-box, Xray ──
# Build from immutable upstream source revisions so the Go security fixes are
# present in the binaries even when a release artifact lags behind its source.
RUN dpkg_arch="$(dpkg --print-architecture)" \
    && case "${dpkg_arch}" in \
        amd64) go_arch="amd64"; export GOAMD64=v1 ;; \
        arm64) go_arch="arm64"; unset GOAMD64 ;; \
        *) echo "unsupported architecture for proxy core build: ${dpkg_arch}" >&2; exit 1 ;; \
    esac \
    && export PATH="/usr/local/go/bin:${PATH}" CGO_ENABLED=0 GOOS=linux GOARCH="${go_arch}" GOTOOLCHAIN=local \
    && [[ "${MIHOMO_SOURCE_REF}" =~ ^[0-9a-fA-F]{40}$ ]] \
    && [[ "${SING_BOX_SOURCE_REF}" =~ ^[0-9a-fA-F]{40}$ ]] \
    && [[ "${XRAY_SOURCE_REF}" =~ ^[0-9a-fA-F]{40}$ ]] \
    && [[ "${MIHOMO_SOURCE_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] \
    && [[ "${SING_BOX_SOURCE_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] \
    && [[ "${XRAY_SOURCE_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] \
    && mihomo_version="${MIHOMO_VERSION#v}" \
    && sing_box_version="${SING_BOX_VERSION#v}" \
    && xray_version="${XRAY_VERSION#v}" \
    && mihomo_source_ref="${MIHOMO_SOURCE_REF#v}" \
    && sing_box_source_ref="${SING_BOX_SOURCE_REF#v}" \
    && xray_source_ref="${XRAY_SOURCE_REF#v}" \
    && mihomo_source_archive="/tmp/mihomo-${mihomo_source_ref}.tar.gz" \
    && sing_box_source_archive="/tmp/sing-box-${sing_box_source_ref}.tar.gz" \
    && xray_source_archive="/tmp/xray-${xray_source_ref}.tar.gz" \
    && mkdir -p /tmp/proxy-build/mihomo /tmp/proxy-build/sing-box /tmp/proxy-build/xray \
    && curl -fsSL "https://github.com/MetaCubeX/mihomo/archive/${mihomo_source_ref}.tar.gz" -o "${mihomo_source_archive}" \
    && printf '%s  %s\n' "${MIHOMO_SOURCE_SHA256}" "${mihomo_source_archive}" | sha256sum -c - \
    && curl -fsSL "https://github.com/SagerNet/sing-box/archive/${sing_box_source_ref}.tar.gz" -o "${sing_box_source_archive}" \
    && printf '%s  %s\n' "${SING_BOX_SOURCE_SHA256}" "${sing_box_source_archive}" | sha256sum -c - \
    && curl -fsSL "https://github.com/XTLS/Xray-core/archive/${xray_source_ref}.tar.gz" -o "${xray_source_archive}" \
    && printf '%s  %s\n' "${XRAY_SOURCE_SHA256}" "${xray_source_archive}" | sha256sum -c - \
    && tar -xzf "${mihomo_source_archive}" --strip-components=1 -C /tmp/proxy-build/mihomo \
    && tar -xzf "${sing_box_source_archive}" --strip-components=1 -C /tmp/proxy-build/sing-box \
    && tar -xzf "${xray_source_archive}" --strip-components=1 -C /tmp/proxy-build/xray \
    && export GOMODCACHE=/tmp/proxy-build/go-modcache GOCACHE=/tmp/proxy-build/go-cache \
    && build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    && (cd /tmp/proxy-build/mihomo \
        && go mod edit \
            -require="golang.org/x/crypto@v${PROXY_X_CRYPTO_VERSION}" \
            -require="golang.org/x/net@v${PROXY_X_NET_VERSION}" \
            -require="golang.org/x/text@v${PROXY_X_TEXT_VERSION}" \
            -require="google.golang.org/grpc@v${PROXY_GRPC_VERSION}" \
        && go mod tidy \
        && go build -tags with_gvisor -trimpath \
            -ldflags "-X github.com/metacubex/mihomo/constant.Version=${mihomo_version} -X github.com/metacubex/mihomo/constant.BuildTime=${build_time} -w -s -buildid=" \
            -o /tmp/proxy-build/mihomo-bin .) \
    && sing_box_tags="$(tr -d '\n' < /tmp/proxy-build/sing-box/release/DEFAULT_BUILD_TAGS_OTHERS)" \
    && sing_box_ldflags="$(cat /tmp/proxy-build/sing-box/release/LDFLAGS)" \
    && (cd /tmp/proxy-build/sing-box \
        && go mod edit \
            -require="golang.org/x/crypto@v${PROXY_X_CRYPTO_VERSION}" \
            -require="golang.org/x/net@v${PROXY_X_NET_VERSION}" \
            -require="golang.org/x/text@v${PROXY_X_TEXT_VERSION}" \
            -require="google.golang.org/grpc@v${PROXY_GRPC_VERSION}" \
        && go mod tidy \
        && go build -trimpath -tags "${sing_box_tags}" \
            -ldflags "${sing_box_ldflags} -X github.com/sagernet/sing-box/constant.Version=${sing_box_version} -s -w -buildid=" \
            -o /tmp/proxy-build/sing-box-bin ./cmd/sing-box) \
    && (cd /tmp/proxy-build/xray \
        && go mod edit \
            -require="golang.org/x/crypto@v${PROXY_X_CRYPTO_VERSION}" \
            -require="golang.org/x/net@v${PROXY_X_NET_VERSION}" \
            -require="golang.org/x/text@v${PROXY_X_TEXT_VERSION}" \
            -require="google.golang.org/grpc@v${PROXY_GRPC_VERSION}" \
        && go mod tidy \
        && go build -trimpath -buildvcs=false -ldflags '-s -w -buildid=' \
            -o /tmp/proxy-build/xray-bin ./main) \
    && install -m 0755 /tmp/proxy-build/mihomo-bin /usr/local/bin/mihomo \
    && install -m 0755 /tmp/proxy-build/sing-box-bin /usr/local/bin/sing-box \
    && install -m 0755 /tmp/proxy-build/xray-bin /usr/local/bin/xray \
    && ln -sf /usr/local/bin/mihomo /usr/local/bin/clash-meta \
    && for binary in mihomo sing-box xray; do \
        go version -m "/usr/local/bin/${binary}" | grep -Fq $'\tdep\tgolang.org/x/crypto\tv'"${PROXY_X_CRYPTO_VERSION}" || { echo "${binary} has an unexpected x/crypto version" >&2; exit 1; }; \
        go version -m "/usr/local/bin/${binary}" | grep -Fq $'\tdep\tgolang.org/x/net\tv'"${PROXY_X_NET_VERSION}" || { echo "${binary} has an unexpected x/net version" >&2; exit 1; }; \
        go version -m "/usr/local/bin/${binary}" | grep -Fq $'\tdep\tgolang.org/x/text\tv'"${PROXY_X_TEXT_VERSION}" || { echo "${binary} has an unexpected x/text version" >&2; exit 1; }; \
    done \
    && for binary in sing-box xray; do \
        go version -m "/usr/local/bin/${binary}" | grep -Fq $'\tdep\tgoogle.golang.org/grpc\tv'"${PROXY_GRPC_VERSION}" || { echo "${binary} has an unexpected grpc version" >&2; exit 1; }; \
    done \
    && mihomo_output="$(/usr/local/bin/mihomo -v)" \
    && grep -Fq "Mihomo Meta ${mihomo_version}" <<<"${mihomo_output}" \
    && sing_box_output="$(/usr/local/bin/sing-box version)" \
    && grep -Fq "sing-box version ${sing_box_version}" <<<"${sing_box_output}" \
    && xray_output="$(/usr/local/bin/xray version)" \
    && grep -Fq "Xray ${xray_version}" <<<"${xray_output}" \
    && rm -rf /tmp/proxy-build
# ── code-server ──
RUN curl -fsSL https://code-server.dev/install.sh | sh

# Keep code-server's bundled tar within its declared ^7.5.9 range while
# upstream release artifacts catch up with security fixes.
RUN [[ "${CODE_SERVER_TAR_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    && code_server_tar_dir="/usr/lib/code-server/lib/vscode/node_modules/tar" \
    && tarball="$(npm pack --silent --pack-destination /tmp "tar@${CODE_SERVER_TAR_VERSION}")" \
    && [[ "${tarball}" == "tar-${CODE_SERVER_TAR_VERSION}.tgz" ]] \
    && find "${code_server_tar_dir}" -mindepth 1 -delete \
    && tar -xzf "/tmp/${tarball}" --strip-components=1 -C "${code_server_tar_dir}" \
    && node -e 'const [path, expected] = process.argv.slice(1); const actual = require(path).version; if (actual !== expected) throw new Error(`expected tar ${expected}, got ${actual}`)' \
        "${code_server_tar_dir}/package.json" "${CODE_SERVER_TAR_VERSION}" \
    && find /tmp -maxdepth 1 -name "${tarball}" -delete

# ── npm globals and Corepack package managers ──
# Claude's audited postinstall links its platform-native optional dependency.
# Keep lifecycle scripts from all other global packages blocked by npm 12.
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code typescript@5 @openai/codex @anthropic-ai/claude-code oh-my-codex \
    && codex --version \
    && claude --version \
    && omx --version \
    && mkdir -p /opt/corepack \
    && corepack enable \
    && COREPACK_HOME=/opt/corepack corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && COREPACK_HOME=/opt/corepack corepack prepare "yarn@${YARN_VERSION}" --activate

# ── Paseo mobile/web remote control ──
# The complete production dependency graph is pinned in package-lock.json.
# Lifecycle scripts stay disabled; the reviewed native packages ship usable
# prebuilt artifacts for supported architectures and are probed below.
COPY paseo-runtime/package.json paseo-runtime/package-lock.json /opt/paseo/
RUN cd /opt/paseo \
    && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm audit signatures \
    && npm audit --omit=dev --audit-level=high \
    && node -e "require('node-pty'); require('@parcel/watcher'); require('sherpa-onnx-node')" \
    && paseo_version="$(./node_modules/.bin/paseo --version)" \
    && [ "${paseo_version}" = "0.3.1" ] \
    && ln -s /opt/paseo/node_modules/.bin/paseo /usr/local/bin/paseo \
    && paseo --version
COPY paseo-runtime/LICENSE paseo-runtime/UPSTREAM.md /usr/share/doc/paseo/

# ── User, directories, root password, sudo ──
# check=skip=SecretsUsedInArgOrEnv
ARG ROOT_PASSWORD=codex2024
RUN useradd -m -s /bin/bash -u 1001 dev \
    && mkdir -p \
        /workspace \
        /run/codex \
        /etc/supervisor/conf.d \
        /home/dev/.bun/bin \
        /home/dev/.cache/npm \
        /home/dev/.cargo/bin \
        /home/dev/.claude \
        /home/dev/.codex \
        /home/dev/.config/code-server \
        /home/dev/.deno/bin \
        /home/dev/.local/bin \
        /home/dev/.local/share/code-server/extensions \
        /home/dev/.npm \
        /home/dev/.paseo \
        /home/dev/go/bin \
        /home/dev/proxy \
    && chown -R dev:dev /workspace /run/codex /home/dev /opt/corepack \
    && echo "root:${ROOT_PASSWORD}" | chpasswd \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# ── Preinstall code-server extensions ──
RUN for extension in ${CODE_SERVER_EXTENSIONS}; do \
        sudo -u dev code-server --install-extension "${extension}"; \
    done \
    && mkdir -p /opt/code-server/extensions \
    && cp -a /home/dev/.local/share/code-server/extensions/. /opt/code-server/extensions/ \
    && chown -R dev:dev /opt/code-server
# ── Supervisord config ──
COPY config/supervisord/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/supervisord/conf.d/ /etc/supervisor/conf.d/

# ── Scripts ──
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY scripts/doctor.sh /usr/local/bin/doctor.sh
COPY scripts/smoke-test.sh /usr/local/bin/smoke-test.sh
COPY scripts/paseo-password.sh /usr/local/lib/codex-workstation/paseo-password.sh
RUN chmod 0644 /usr/local/lib/codex-workstation/paseo-password.sh \
    && chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/doctor.sh /usr/local/bin/smoke-test.sh

USER dev

# ── Environment ──
ENV USER=dev
ENV HOME=/home/dev
ENV CONTAINER_WORKSPACE=/workspace
ENV LANG=zh_CN.UTF-8
ENV LC_ALL=zh_CN.UTF-8
ENV BUN_INSTALL=/home/dev/.bun
ENV CARGO_HOME=/home/dev/.cargo
ENV DENO_INSTALL=/home/dev/.deno
ENV COREPACK_HOME=/opt/corepack
ENV GOPATH=/home/dev/go
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-${TARGETARCH}
ENV NPM_CONFIG_CACHE=/home/dev/.cache/npm
ENV NPM_CONFIG_PREFIX=/home/dev/.local
ENV PASEO_HOME=/home/dev/.paseo
ENV PASEO_LISTEN=0.0.0.0:6767
ENV PASEO_HOSTNAMES=paseo.internal
ENV PASEO_RELAY_ENABLED=false
ENV PASEO_SERVICE_PROXY_ENABLED=false
ENV PASEO_TRUSTED_PROXIES=loopback
ENV PASEO_WEB_UI_ENABLED=true
ENV PASEO_VOICE_MODE_ENABLED=false
ENV PASEO_DICTATION_ENABLED=false
ENV PASEO_LOCAL_SPEECH_AUTO_DOWNLOAD=false
ENV PASEO_VERSION=0.3.1
ENV PIPX_BIN_DIR=/home/dev/.local/bin
ENV RUSTUP_HOME=/opt/rust/rustup
ENV PATH=/home/dev/.local/bin:/home/dev/go/bin:/home/dev/.cargo/bin:/home/dev/.bun/bin:/home/dev/.deno/bin:/opt/bun/bin:/opt/deno/bin:/usr/local/go/bin:/opt/rust/cargo/bin:${PATH}

# ── Runtime ──
EXPOSE 8080 6767

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
