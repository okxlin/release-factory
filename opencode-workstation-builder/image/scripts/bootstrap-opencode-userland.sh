#!/usr/bin/env bash
set -euo pipefail

: "${OPENCODE_NPM_PACKAGE:=opencode-ai}"
: "${OPENCODE_INSTALL_DIR:=$HOME/.local/share/opencode}"
: "${OPENCODE_NPM_BIN_DIR:=$HOME/.local/bin}"
: "${OPENCODE_FORCE_INSTALL:=0}"

mkdir -p "${OPENCODE_INSTALL_DIR}" "${OPENCODE_NPM_BIN_DIR}"

if [[ "${OPENCODE_FORCE_INSTALL}" != "1" ]] && command -v opencode >/dev/null 2>&1; then
  echo "[bootstrap] opencode already available: $(opencode --version 2>/dev/null || echo unknown)"
  exit 0
fi

echo "[bootstrap] installing ${OPENCODE_NPM_PACKAGE} into ${OPENCODE_INSTALL_DIR}"
package_json="${OPENCODE_INSTALL_DIR}/package.json"
if [[ ! -f "${package_json}" ]]; then
  printf '{"private":true}\n' > "${package_json}"
fi
npm pkg set --prefix "${OPENCODE_INSTALL_DIR}" --json 'allowScripts.opencode-ai=true'
npm install \
  --prefix "${OPENCODE_INSTALL_DIR}" \
  --install-strategy=shallow \
  "${OPENCODE_NPM_PACKAGE}"

if [[ -x "${OPENCODE_INSTALL_DIR}/node_modules/.bin/opencode" ]]; then
  ln -sf "${OPENCODE_INSTALL_DIR}/node_modules/.bin/opencode" "${OPENCODE_NPM_BIN_DIR}/opencode"
fi

command -v opencode >/dev/null 2>&1
opencode --version
