# syntax=docker/dockerfile:1.7
FROM node:20-bookworm-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG BUN_VERSION=1.2.15
ARG USERNAME=opencode
ARG USER_UID=1000
ARG USER_GID=1000
ARG HOST_DOCKER_GID=997

ENV USER=${USERNAME}
ENV HOME=/home/${USERNAME}
ENV DEBIAN_FRONTEND=noninteractive \
    BUN_INSTALL=/opt/bun \
    OPENCODE_HOME=/home/${USERNAME}/.local/share/opencode \
    OMO_HOME=/home/${USERNAME}/.local/share/oh-my-opencode \
    CONTAINER_WORKSPACE=/workspace

ENV PATH=/opt/bun/bin:/home/${USERNAME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        cargo \
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
        golang-go \
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
        tini \
        unzip \
        xz-utils \
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
    && ln -sf /usr/local/lib/node_modules/@code-yeongyu/comment-checker/bin/comment-checker /usr/local/bin/comment-checker \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose \
    && ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose \
    && ln -sf /usr/libexec/docker/cli-plugins/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx \
    && corepack enable \
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
    && usermod -aG "${docker_group}" "${USERNAME}"

RUN curl -fsSL https://bun.sh/install | bash -s -- bun-v${BUN_VERSION} \
    && bun --version

WORKDIR /app

COPY scripts /app/scripts
RUN chmod +x /app/scripts/*.sh /app/scripts/*.py

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd || true

RUN mkdir -p /workspace /config /data /cache \
    && chown -R ${USER_UID}:${USER_GID} /app /workspace /config /data /cache /opt/bun /home/${USERNAME}

USER ${USERNAME}
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/app/scripts/entrypoint.sh"]
CMD ["shell"]
