# codex-web-workstation Dockerfile v2
# Ubuntu 24.04 base, amd64 only for MVP
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# ── Locale ──
RUN apt-get update && apt-get install -y locales \
    && locale-gen zh_CN.UTF-8 \
    && update-locale LANG=zh_CN.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ── Docker repo ──
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

# ── System packages ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    bat \
    bash \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    curl \
    diffutils \
    docker-buildx-plugin \
    docker-ce-cli \
    docker-compose-plugin \
    fd-find \
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
    mariadb-client \
    mtr \
    ncdu \
    nethogs \
    net-tools \
    openssh-client \
    patch \
    pigz \
    pkg-config \
    postgresql-client \
    procps \
    python3 \
    python3-pip \
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
    unzip \
    vim \
    wget \
    xz-utils \
    zip \
    zstd \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

# ── Node.js 20.x via NodeSource ──
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest

# ── Go 1.22.5 ──
RUN curl -fsSL https://go.dev/dl/go1.22.5.linux-amd64.tar.gz | tar -C /usr/local -xzf - \
    && echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh

# ── Rust 1.77.0 ──
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && chmod +x /tmp/rustup-init.sh \
    && mkdir -p /opt/rust /home/dev \
    && CARGO_HOME=/opt/rust/cargo RUSTUP_HOME=/opt/rust/rustup /tmp/rustup-init.sh -y --default-toolchain 1.77.0 \
    && rm /tmp/rustup-init.sh

# ── Bun 1.3.14 ──
RUN curl -fsSL https://bun.sh/install | bash -s -- bun-v1.3.14 \
    && mv /root/.bun /opt/bun

# ── yq ──
RUN curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# ── code-server ──
RUN curl -fsSL https://code-server.dev/install.sh | sh

# ── npm globals ──
RUN npm install -g typescript@5 pnpm yarn @openai/codex @anthropic-ai/claude-code oh-my-codex \
    && corepack enable

# ── User, directories, root password, sudo ──
ARG ROOT_PASSWORD=root
RUN useradd -m -s /bin/bash -u 1000 dev \
    && mkdir -p /workspace /run/codex /etc/supervisor/conf.d \
    && chown -R dev:dev /workspace /run/codex /home/dev \
    && echo "root:${ROOT_PASSWORD}" | chpasswd \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev

# ── Preinstall code-server extensions ──
# ── Supervisord config ──
COPY config/supervisord/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/supervisord/conf.d/ /etc/supervisor/conf.d/

# ── Scripts ──
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY scripts/configure-provider.sh /usr/local/bin/configure-provider.sh
COPY scripts/doctor.sh /usr/local/bin/doctor.sh
COPY scripts/smoke-test.sh /usr/local/bin/smoke-test.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/configure-provider.sh /usr/local/bin/doctor.sh /usr/local/bin/smoke-test.sh

# ── Environment ──
ENV USER=dev
ENV HOME=/home/dev
ENV CONTAINER_WORKSPACE=/workspace
ENV LANG=zh_CN.UTF-8
ENV LC_ALL=zh_CN.UTF-8
ENV PATH=/opt/bun/bin:/usr/local/go/bin:/opt/rust/cargo/bin:/home/dev/.local/bin:${PATH}

# ── Runtime ──
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
