ARG BASE_IMAGE_TAG=147.0.7727
FROM lscr.io/linuxserver/chrome:${BASE_IMAGE_TAG}

USER root

ARG GEMINI_SKILL_REPO=https://github.com/WJZ-P/gemini-skill.git
ARG GEMINI_SKILL_REF=main
ARG NODE_MAJOR=20

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

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates git gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth=1 --branch ${GEMINI_SKILL_REF} ${GEMINI_SKILL_REPO} ${GEMINI_SKILL_HOME} \
    && cd ${GEMINI_SKILL_HOME} \
    && npm install --omit=dev \
    && npm cache clean --force

COPY . /

RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-gemini-skill-daemon/run /usr/local/bin/patch_gemini_ops_sendwait.py \
    && mkdir -p /output /config/.XDG /config/browser-profile /etc/s6-overlay/s6-rc.d/svc-gemini-skill-daemon/dependencies.d \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-gemini-skill-daemon \
    && chown -R abc:abc /output /config/.XDG /config/browser-profile ${GEMINI_SKILL_HOME} \
    && python3 /usr/local/bin/patch_gemini_ops_sendwait.py ${GEMINI_SKILL_HOME}/src/gemini-ops.js

EXPOSE 3001 40225 9222

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 CMD ["/bin/sh", "-lc", "curl -fsS http://127.0.0.1:${DAEMON_PORT}/health >/dev/null"]
