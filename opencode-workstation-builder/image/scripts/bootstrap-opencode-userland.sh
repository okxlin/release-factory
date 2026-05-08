#!/usr/bin/env bash
set -euo pipefail

: "${OPENCODE_NPM_PACKAGE:=opencode-ai}"
: "${CONTAINER_DATA:=/data}"
: "${OPENCODE_INSTALL_DIR:=${CONTAINER_DATA}/opencode}"
: "${OPENCODE_NPM_BIN_DIR:=${CONTAINER_DATA}/bin}"

mkdir -p "${OPENCODE_INSTALL_DIR}" "${OPENCODE_NPM_BIN_DIR}"

if command -v opencode >/dev/null 2>&1; then
  echo "[bootstrap] opencode already available: $(opencode --version 2>/dev/null || echo unknown)"
  exit 0
fi

echo "[bootstrap] installing ${OPENCODE_NPM_PACKAGE} into ${OPENCODE_INSTALL_DIR}"
npm install --prefix "${OPENCODE_INSTALL_DIR}" --global-style "${OPENCODE_NPM_PACKAGE}"

if [[ -x "${OPENCODE_INSTALL_DIR}/node_modules/.bin/opencode" ]]; then
  ln -sf "${OPENCODE_INSTALL_DIR}/node_modules/.bin/opencode" "${OPENCODE_NPM_BIN_DIR}/opencode"
fi

command -v opencode >/dev/null 2>&1
opencode --version
