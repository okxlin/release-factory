#!/usr/bin/env node

import { pathToFileURL } from 'node:url'

const SEMVER_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/

export function parseSemver(version) {
  if (typeof version !== 'string') {
    throw new TypeError('npm version must be a string')
  }
  const match = SEMVER_RE.exec(version)
  if (!match) {
    throw new Error(`unsupported npm semantic version: ${version}`)
  }
  const prerelease = match[4] === undefined ? [] : match[4].split('.')
  for (const identifier of prerelease) {
    if (/^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith('0')) {
      throw new Error(`numeric prerelease identifier has a leading zero: ${version}`)
    }
  }
  return {
    version,
    core: [BigInt(match[1]), BigInt(match[2]), BigInt(match[3])],
    prerelease,
  }
}

function compareIdentifier(left, right) {
  const leftNumeric = /^\d+$/.test(left)
  const rightNumeric = /^\d+$/.test(right)
  if (leftNumeric && rightNumeric) {
    const leftNumber = BigInt(left)
    const rightNumber = BigInt(right)
    return leftNumber < rightNumber ? -1 : leftNumber > rightNumber ? 1 : 0
  }
  if (leftNumeric !== rightNumeric) {
    return leftNumeric ? -1 : 1
  }
  return left < right ? -1 : left > right ? 1 : 0
}

export function compareSemver(leftVersion, rightVersion) {
  const left = parseSemver(leftVersion)
  const right = parseSemver(rightVersion)
  for (let index = 0; index < left.core.length; index += 1) {
    if (left.core[index] < right.core[index]) return -1
    if (left.core[index] > right.core[index]) return 1
  }
  if (left.prerelease.length === 0 || right.prerelease.length === 0) {
    if (left.prerelease.length === right.prerelease.length) return 0
    return left.prerelease.length === 0 ? 1 : -1
  }
  const length = Math.max(left.prerelease.length, right.prerelease.length)
  for (let index = 0; index < length; index += 1) {
    if (left.prerelease[index] === undefined) return -1
    if (right.prerelease[index] === undefined) return 1
    const comparison = compareIdentifier(left.prerelease[index], right.prerelease[index])
    if (comparison !== 0) return comparison
  }
  return 0
}

export function resolveLatestVersion(metadata) {
  const versions = typeof metadata === 'string' ? [metadata] : metadata
  if (!Array.isArray(versions) || versions.length === 0) {
    throw new Error('npm returned no published versions')
  }
  if (!versions.every(version => typeof version === 'string')) {
    throw new Error('npm returned a non-string version entry')
  }
  versions.forEach(parseSemver)
  return versions.reduce((latest, candidate) => (
    compareSemver(candidate, latest) > 0 ? candidate : latest
  ))
}

async function main() {
  let input = ''
  process.stdin.setEncoding('utf8')
  for await (const chunk of process.stdin) {
    input += chunk
  }
  const metadata = JSON.parse(input)
  process.stdout.write(`${resolveLatestVersion(metadata)}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    process.stderr.write(`ERROR: ${error.message}\n`)
    process.exitCode = 1
  })
}
