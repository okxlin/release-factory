# syntax=docker/dockerfile:1.7
FROM node:24-bookworm-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG BUN_VERSION=1.4.0
ARG ACTIONLINT_VERSION=1.7.12
ARG GO_VERSION=1.27.0
ARG GO_SHA256_AMD64=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685
ARG GO_SHA256_ARM64=51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda
ARG USERNAME=opencode
ARG USER_UID=1000
ARG USER_GID=1000
ARG HOST_DOCKER_GID=997

ENV USER=${USERNAME}
ENV HOME=/home/${USERNAME}
ENV DEBIAN_FRONTEND=noninteractive \
    BUN_INSTALL=/opt/bun \
    CARGO_HOME=/home/${USERNAME}/.cargo \
    CONTAINER_CACHE=/cache \
    OPENCODE_HOME=/home/${USERNAME}/.local/share/opencode \
    OMO_HOME=/home/${USERNAME}/.local/share/oh-my-opencode \
    CONTAINER_WORKSPACE=/workspace \
    RUSTUP_HOME=/home/${USERNAME}/.rustup \
    XDG_DATA_HOME=/home/${USERNAME}/.local/share

ENV PATH=/opt/bun/bin:/usr/local/go/bin:/home/${USERNAME}/.cargo/bin:/home/${USERNAME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        dumb-init \
        fd-find \
        g++ \
        gcc \
        gh \
        git \
        gnupg \
        jq \
        make \
        node-typescript \
        openssh-client \
        pkg-config \
        procps \
        python3 \
        python3-pip \
        ripgrep \
        rsync \
        sqlite3 \
        sudo \
        tini \
        unzip \
        xz-utils \
        vim-tiny \
        wget \
        tree \
        zip \
        htop \
        net-tools \
        iproute2 \
        iputils-ping \
        git-lfs \
        postgresql-client \
        redis-tools \
        mariadb-client \
        tmux \
        gettext-base \
        diffutils \
        patch \
        shellcheck \
        shfmt \
        bat \
        fzf \
        ncdu \
        httpie \
        tig \
        zstd \
        mtr \
        iotop \
        nethogs \
        strace \
        pigz \
        yq \
        tldr \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
    && npm install -g @code-yeongyu/comment-checker corepack npm pnpm yarn \
    && ln -sf /usr/local/lib/node_modules/@code-yeongyu/comment-checker/cli.js /usr/local/bin/comment-checker \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose \
    && ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose \
    && ln -sf /usr/libexec/docker/cli-plugins/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx \
    && corepack enable \
    && corepack prepare pnpm@latest --activate \
    && corepack prepare yarn@stable --activate \
    && rm -rf /var/lib/apt/lists/*

RUN if getent group "${USER_GID}" >/dev/null; then \
      existing_group="$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
      groupadd --gid "${USER_GID}" "${USERNAME}"; \
      existing_group="${USERNAME}"; \
    fi \
    && if getent passwd "${USER_UID}" >/dev/null; then \
         existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
         if [ "${existing_user}" != "${USERNAME}" ]; then \
           usermod --login "${USERNAME}" --home "/home/${USERNAME}" --move-home "${existing_user}"; \
         else \
           usermod --home "/home/${USERNAME}" --move-home "${USERNAME}"; \
         fi; \
         usermod --gid "${existing_group}" --shell /bin/bash "${USERNAME}"; \
       else \
         useradd --uid "${USER_UID}" --gid "${existing_group}" --create-home --shell /bin/bash "${USERNAME}"; \
       fi \
    && if getent group "${HOST_DOCKER_GID}" >/dev/null; then \
         docker_group="$(getent group "${HOST_DOCKER_GID}" | cut -d: -f1)"; \
       else \
         docker_group="hostdocker"; \
         groupadd --gid "${HOST_DOCKER_GID}" "${docker_group}"; \
       fi \
    && usermod -aG "${docker_group}" "${USERNAME}" \
    && chown -R "${USER_UID}:${USER_GID}" "/home/${USERNAME}"

RUN curl -fsSL https://bun.sh/install | bash -s -- bun-v${BUN_VERSION} \
    && bun --version

ENV BUN_VERSION=${BUN_VERSION}

RUN dpkg_arch="$(dpkg --print-architecture)" \
    && case "${dpkg_arch}" in \
         amd64) actionlint_arch='amd64' ;; \
         arm64) actionlint_arch='arm64' ;; \
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

RUN dpkg_arch="$(dpkg --print-architecture)" \
    && case "${dpkg_arch}" in \
         amd64) go_arch='amd64'; go_sha256="${GO_SHA256_AMD64}" ;; \
         arm64) go_arch='arm64'; go_sha256="${GO_SHA256_ARM64}" ;; \
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
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf "/tmp/${go_asset}" \
    && rm "/tmp/${go_asset}" \
    && echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile.d/go.sh

ARG RUST_VERSION=stable
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && chmod +x /tmp/rustup-init.sh \
    && sudo -u "${USERNAME}" env HOME="/home/${USERNAME}" CARGO_HOME="/home/${USERNAME}/.cargo" RUSTUP_HOME="/home/${USERNAME}/.rustup" /tmp/rustup-init.sh -y --default-toolchain "${RUST_VERSION}" \
    && rm /tmp/rustup-init.sh \
    && echo "export PATH=/home/${USERNAME}/.cargo/bin:\$PATH" >> /etc/profile.d/rust.sh

RUN npm install -g typescript@5 \
    && tsc --version

WORKDIR /app

COPY scripts /app/scripts
RUN chmod +x /app/scripts/*.sh /app/scripts/*.py

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd || true \
    && ln -sf /usr/bin/vim.tiny /usr/local/bin/vim || true \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat || true

RUN mkdir -p \
      /workspace \
      /cache \
      /home/${USERNAME}/.config/opencode \
      /home/${USERNAME}/.agents \
      /home/${USERNAME}/.cache/npm \
      /home/${USERNAME}/.claude \
      /home/${USERNAME}/.cargo/bin \
      /home/${USERNAME}/.opencode \
      /home/${USERNAME}/.local/share/opencode \
      /home/${USERNAME}/.local/share/oh-my-opencode \
      /home/${USERNAME}/.local/bin \
      /home/${USERNAME}/.npm \
      /home/${USERNAME}/.rustup \
    && chown -R ${USER_UID}:${USER_GID} /app /workspace /cache /opt/bun /usr/local/go /home/${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

ENV NPM_CONFIG_CACHE=/home/${USERNAME}/.cache/npm
ENV NPM_CONFIG_PREFIX=/home/${USERNAME}/.local

USER ${USERNAME}
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/app/scripts/entrypoint.sh"]
CMD ["shell"]
