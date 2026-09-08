#!/usr/bin/env node

import fs from 'node:fs'
import { pathToFileURL } from 'node:url'

import {
  compareSemver,
  parseSemver,
} from './resolve-latest-npm-version.mjs'

const SOURCE_TAG_PREFIX = 'dsh-v'
const SOURCE_VERSION_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/

export function normalizeSourceVersion(value) {
  if (typeof value !== 'string' || value === '') {
    throw new TypeError('source version must be a non-empty string')
  }

  const version = value
    .replace(/^dsh-v/, '')
    .replace(/^v/, '')
  if (!SOURCE_VERSION_RE.test(version)) {
    throw new Error(`unsupported source semantic version: ${value}`)
  }
  parseSemver(version)
  return version
}

function sourceReleaseCandidate(release) {
  if (
    release === null
    || typeof release !== 'object'
    || release.draft === true
    || typeof release.tag_name !== 'string'
    || !release.tag_name.startsWith(SOURCE_TAG_PREFIX)
  ) {
    return null
  }

  const version = release.tag_name.slice(SOURCE_TAG_PREFIX.length)
  if (!SOURCE_VERSION_RE.test(version)) return null

  try {
    parseSemver(version)
  } catch {
    return null
  }

  return {
    version,
    tag: release.tag_name,
  }
}

export function selectSourceRelease(releases, requestedVersion = '') {
  if (!Array.isArray(releases)) {
    throw new TypeError('GitHub releases must be an array')
  }

  const requested = requestedVersion === ''
    ? ''
    : normalizeSourceVersion(requestedVersion)
  const candidates = releases
    .map(sourceReleaseCandidate)
    .filter(candidate => candidate !== null)
    .filter(candidate => requested === '' || candidate.version === requested)

  if (candidates.length === 0) {
    const detail = requested === '' ? 'matching source releases' : `source release ${requested}`
    throw new Error(`GitHub releases contain no ${detail}`)
  }

  return candidates.reduce((latest, candidate) => (
    compareSemver(candidate.version, latest.version) > 0 ? candidate : latest
  ))
}

function printUsage() {
  process.stderr.write('Usage: resolve-dsh-source.mjs --select RELEASES_JSON [VERSION]\n')
}

async function main() {
  if (process.argv[2] !== '--select' || !process.argv[3]) {
    printUsage()
    process.exitCode = 2
    return
  }

  const releases = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'))
  const selected = selectSourceRelease(releases, process.argv[4] ?? '')
  process.stdout.write(`${JSON.stringify(selected)}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    process.stderr.write(`ERROR: ${error.message}\n`)
    process.exitCode = 1
  })
}
