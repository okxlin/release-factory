# syntax=docker/dockerfile:1
ARG BASE_IMAGE
ARG NODE_IMAGE
FROM ${NODE_IMAGE} AS node-runtime
FROM ${BASE_IMAGE}

USER root

ARG GEMINI_SKILL_REF

COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm

ENV DEBIAN_FRONTEND=noninteractive \
    GEMINI_SKILL_HOME=/opt/gemini-skill \
    OUTPUT_DIR=/data/output \
    BROWSER_DEBUG_PORT=40821 \
    BROWSER_HEADLESS=false \
    BROWSER_USER_DATA_DIR=/data/browser-profile \
    BROWSER_PROTOCOL_TIMEOUT=180000 \
    DAEMON_PORT=40225 \
    DAEMON_TTL_MS=1800000

ARG SECURITY_REFRESH=manual
RUN apt-get update \
    && for package in microsoft-edge-stable locales; do apt-mark hold "$package" 2>/dev/null || true; done \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl ca-certificates git dumb-init \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && node --version \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,source=gemini-skill-browser-builder/image/runtime,target=/tmp/runtime \
    bash /tmp/runtime/install.sh 1000:1000

COPY gemini-skill-browser-builder/image/supervisor/gemini-skill.conf /etc/supervisor/conf.d/gemini-skill.conf
COPY gemini-skill-browser-builder/image/scripts/bootstrap.sh /usr/local/bin/gemini-skill-bootstrap.sh
COPY gemini-skill-browser-builder/image/scripts/healthcheck.sh /usr/local/bin/gemini-skill-healthcheck.sh

RUN chmod +x /usr/local/bin/gemini-skill-bootstrap.sh /usr/local/bin/gemini-skill-healthcheck.sh \
    && mkdir -p /data/output /data/browser-profile \
    && chown -R 1000:1000 /data

LABEL io.release-factory.gemini.revision=${GEMINI_SKILL_REF}

EXPOSE 6901 40225 40821

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 CMD ["/usr/local/bin/gemini-skill-healthcheck.sh"]

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/gemini-skill-bootstrap.sh"]
