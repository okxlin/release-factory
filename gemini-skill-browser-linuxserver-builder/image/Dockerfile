# syntax=docker/dockerfile:1
ARG BASE_IMAGE
ARG NODE_IMAGE
FROM ${NODE_IMAGE} AS node-runtime
FROM ${BASE_IMAGE} AS nginx-module
USER root
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates build-essential libpcre2-dev zlib1g-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,source=gemini-skill-browser-builder/configs/components.json,target=/tmp/browser-components.json \
    --mount=type=bind,source=gemini-skill-browser-builder/image/runtime,target=/tmp/runtime \
    bash /tmp/runtime/build-nginx-module.sh

FROM ${BASE_IMAGE}

USER root

ARG GEMINI_SKILL_REF

COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm

ENV DEBIAN_FRONTEND=noninteractive \
    GEMINI_SKILL_HOME=/opt/gemini-skill \
    OUTPUT_DIR=/output \
    BROWSER_PATH=/usr/bin/wrapped-chrome \
    BROWSER_DEBUG_PORT=9222 \
    BROWSER_HEADLESS=false \
    BROWSER_USER_DATA_DIR=/config/browser-profile \
    BROWSER_PROTOCOL_TIMEOUT=180000 \
    XDG_RUNTIME_DIR=/config/.XDG \
    WAYLAND_DISPLAY=wayland-1 \
    DAEMON_PORT=40225 \
    DAEMON_TTL_MS=1800000

ARG SECURITY_REFRESH=manual
RUN apt-get update \
    && for package in google-chrome-stable chromium chromium-browser locales; do apt-mark hold "$package" 2>/dev/null || true; done \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl ca-certificates git gnupg \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && node --version \
    && rm -rf /var/lib/apt/lists/*

# Debian's stable nginx currently lacks fixes already shipped by nginx.org.
# Keep a newer base package when available; the fallback is integrity-pinned.
RUN --mount=type=bind,source=gemini-skill-browser-builder/configs/components.json,target=/tmp/browser-components.json \
    --mount=type=bind,source=gemini-skill-browser-builder/image/runtime,target=/tmp/runtime \
    --mount=type=bind,from=nginx-module,source=/out,target=/tmp/nginx-module \
    bash /tmp/runtime/install-nginx.sh

RUN --mount=type=bind,source=gemini-skill-browser-builder/image/runtime,target=/tmp/runtime \
    bash /tmp/runtime/install.sh abc:abc

COPY gemini-skill-browser-linuxserver-builder/image/etc/ /etc/
COPY gemini-skill-browser-linuxserver-builder/image/usr/ /usr/

RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-gemini-skill-daemon/run \
    && mkdir -p /output /config/.XDG /config/browser-profile /etc/s6-overlay/s6-rc.d/svc-gemini-skill-daemon/dependencies.d \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-gemini-skill-daemon \
    && touch /etc/s6-overlay/s6-rc.d/svc-gemini-skill-daemon/dependencies.d/init-selkies-end \
    && chmod +x /usr/bin/wrapped-chrome \
    && chown -R abc:abc /output /config/.XDG /config/browser-profile

LABEL io.release-factory.gemini.revision=${GEMINI_SKILL_REF}

EXPOSE 3001 40225 9222

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 CMD ["/bin/sh", "-lc", "curl -fsS http://127.0.0.1:${DAEMON_PORT}/health >/dev/null"]
