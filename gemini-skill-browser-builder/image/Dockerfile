ARG BASE_IMAGE_TAG=1.18.0
FROM kasmweb/edge:${BASE_IMAGE_TAG}

USER root

ARG GEMINI_SKILL_REPO=https://github.com/WJZ-P/gemini-skill.git
ARG GEMINI_SKILL_REF=main
ARG NODE_MAJOR=20

ENV DEBIAN_FRONTEND=noninteractive \
    GEMINI_SKILL_HOME=/opt/gemini-skill \
    OUTPUT_DIR=/data/output \
    BROWSER_DEBUG_PORT=40821 \
    BROWSER_HEADLESS=false \
    BROWSER_USER_DATA_DIR=/data/browser-profile \
    BROWSER_PROTOCOL_TIMEOUT=180000 \
    DAEMON_PORT=40225 \
    DAEMON_TTL_MS=1800000

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates git dumb-init \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth=1 --branch ${GEMINI_SKILL_REF} ${GEMINI_SKILL_REPO} ${GEMINI_SKILL_HOME} \
    && cd ${GEMINI_SKILL_HOME} \
    && npm install --omit=dev \
    && npm cache clean --force

COPY supervisor/gemini-skill.conf /etc/supervisor/conf.d/gemini-skill.conf
COPY scripts/bootstrap.sh /usr/local/bin/gemini-skill-bootstrap.sh
COPY scripts/healthcheck.sh /usr/local/bin/gemini-skill-healthcheck.sh

RUN chmod +x /usr/local/bin/gemini-skill-bootstrap.sh /usr/local/bin/gemini-skill-healthcheck.sh \
    && mkdir -p /data/output /data/browser-profile \
    && chown -R 1000:1000 /data ${GEMINI_SKILL_HOME}

EXPOSE 6901 40225 40821

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 CMD ["/usr/local/bin/gemini-skill-healthcheck.sh"]

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/usr/local/bin/gemini-skill-bootstrap.sh"]
