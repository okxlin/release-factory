#!/usr/bin/env node

import assert from 'node:assert/strict'
import test from 'node:test'

import {
  compareSemver,
  resolveLatestVersion,
} from './resolve-latest-npm-version.mjs'

test('selects rc.8 even when rc.7 appears first', () => {
  assert.equal(
    resolveLatestVersion(['0.1.0-rc.7', '0.1.0-rc.8']),
    '0.1.0-rc.8',
  )
})

test('stable releases sort after prereleases', () => {
  assert.equal(
    resolveLatestVersion(['0.1.0', '0.1.0-rc.99']),
    '0.1.0',
  )
})

test('compares numeric core and prerelease identifiers numerically', () => {
  assert.equal(compareSemver('0.10.0', '0.9.99'), 1)
  assert.equal(compareSemver('1.0.0-rc.10', '1.0.0-rc.9'), 1)
})

test('accepts a single explicit npm version response', () => {
  assert.equal(resolveLatestVersion('0.1.0-rc.7'), '0.1.0-rc.7')
})

test('rejects malformed npm metadata', () => {
  assert.throws(() => resolveLatestVersion([]), /no published versions/)
  assert.throws(() => resolveLatestVersion(['not-semver']), /unsupported npm semantic version/)
})
