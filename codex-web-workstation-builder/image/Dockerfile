# codex-web-workstation Dockerfile
# Ubuntu 24.04 base, amd64 only for MVP
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# ── System packages ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    bat \
    bash \
    build-essential \
    ca-certificates \
    curl \
    fd-find \
    fzf \
    git \
    git-lfs \
    htop \
    httpie \
    iproute2 \
    iputils-ping \
    jq \
    ncdu \
    net-tools \
    openssh-client \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    sudo \
    tig \
    tini \
    tmux \
    tree \
    zstd \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

# ── Node.js 20.x via NodeSource ──
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest

# ── ttyd from GitHub releases ──
ARG TTYD_VERSION=1.7.7
RUN arch=$(dpkg --print-architecture) && \
    ttyd_arch=$(echo "$arch" | sed 's/amd64/x86_64/' | sed 's/arm64/aarch64/') && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
       -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

# ── code-server ──
RUN curl -fsSL https://code-server.dev/install.sh | sh

# ── Codex CLI ──
RUN npm install -g @openai/codex

# ── User and directories ──
RUN useradd -m -s /bin/bash dev \
    && mkdir -p /workspace /run/codex \
    && chown -R dev:dev /workspace /run/codex /home/dev

# ── Scripts ──
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY scripts/configure-provider.sh /usr/local/bin/configure-provider.sh
COPY scripts/doctor.sh /usr/local/bin/doctor.sh
COPY scripts/smoke-test.sh /usr/local/bin/smoke-test.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/configure-provider.sh /usr/local/bin/doctor.sh /usr/local/bin/smoke-test.sh

# ── Runtime ──
USER dev
WORKDIR /workspace

EXPOSE 8080 7681

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]