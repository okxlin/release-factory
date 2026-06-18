# codex-claude-workstation Dockerfile v2
# Ubuntu 24.04 base, amd64 only for MVP
FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=24
ARG NPM_VERSION=latest
ARG GO_VERSION=latest
ARG RUST_VERSION=stable
ARG BUN_VERSION=latest
ARG DENO_VERSION=latest
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
RUN apt-get update && apt-get install -y --no-install-recommends \
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
RUN if [ "${GO_VERSION}" = "latest" ]; then \
        go_version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | sed -n '1p')"; \
    else \
        go_version="go${GO_VERSION#go}"; \
    fi \
    && curl -fsSL "https://go.dev/dl/${go_version}.linux-amd64.tar.gz" | tar -C /usr/local -xzf - \
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
RUN curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# ── Proxy cores: Clash.Meta (mihomo), sing-box, Xray ──
RUN curl -fsSL https://github.com/MetaCubeX/mihomo/releases/download/v1.19.27/mihomo-linux-amd64-compatible-v1.19.27.gz -o /tmp/mihomo.gz \
    && gunzip /tmp/mihomo.gz \
    && mv /tmp/mihomo /usr/local/bin/mihomo \
    && chmod +x /usr/local/bin/mihomo \
    && ln -sf /usr/local/bin/mihomo /usr/local/bin/clash-meta \
    && curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v1.13.13/sing-box-1.13.13-linux-amd64-glibc.tar.gz -o /tmp/sing-box.tgz \
    && tar xzf /tmp/sing-box.tgz -C /usr/local/bin/ --strip-components=1 sing-box-1.13.13-linux-amd64-glibc/sing-box \
    && chmod +x /usr/local/bin/sing-box \
    && curl -fsSL https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip -o /tmp/xray.zip \
    && unzip -o /tmp/xray.zip xray -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/xray \
    && rm -f /tmp/mihomo.gz /tmp/sing-box.tgz /tmp/xray.zip
# ── code-server ──
RUN curl -fsSL https://code-server.dev/install.sh | sh

# ── npm globals and Corepack package managers ──
RUN npm install -g typescript@5 @openai/codex @anthropic-ai/claude-code oh-my-codex \
    && mkdir -p /opt/corepack \
    && corepack enable \
    && COREPACK_HOME=/opt/corepack corepack prepare "pnpm@${PNPM_VERSION}" --activate \
    && COREPACK_HOME=/opt/corepack corepack prepare "yarn@${YARN_VERSION}" --activate

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
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/doctor.sh /usr/local/bin/smoke-test.sh

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
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV NPM_CONFIG_CACHE=/home/dev/.cache/npm
ENV NPM_CONFIG_PREFIX=/home/dev/.local
ENV PIPX_BIN_DIR=/home/dev/.local/bin
ENV RUSTUP_HOME=/opt/rust/rustup
ENV PATH=/home/dev/.local/bin:/home/dev/go/bin:/home/dev/.cargo/bin:/home/dev/.bun/bin:/home/dev/.deno/bin:/opt/bun/bin:/opt/deno/bin:/usr/local/go/bin:/opt/rust/cargo/bin:${PATH}

# ── Runtime ──
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
