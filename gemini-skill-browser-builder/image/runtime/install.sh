#!/usr/bin/env bash
set -euo pipefail

[[ "${GEMINI_SKILL_REF}" =~ ^[a-f0-9]{40}$ ]] || { echo 'An immutable source commit is required' >&2; exit 1; }
git init "${GEMINI_SKILL_HOME}"
cd "${GEMINI_SKILL_HOME}"
git fetch --depth=1 https://github.com/WJZ-P/gemini-skill.git "${GEMINI_SKILL_REF}"
git checkout --detach FETCH_HEAD
test "$(git rev-parse HEAD)" = "${GEMINI_SKILL_REF}"
node /tmp/runtime/puppeteer-compat.mjs
cp /tmp/runtime/package.json /tmp/runtime/package-lock.json ./
npm ci --omit=dev --ignore-scripts
node --input-type=module -e "import sharp from 'sharp'; import 'puppeteer-core'; await sharp({create:{width:2,height:2,channels:3,background:'red'}}).png().toBuffer();"
rm -rf .git /root/.npm
chown -R "$1" "${GEMINI_SKILL_HOME}"
