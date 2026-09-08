#!/usr/bin/env node

import assert from 'node:assert/strict'
import test from 'node:test'

import {
  normalizeSourceVersion,
  selectSourceRelease,
} from './resolve-dsh-source.mjs'

const releases = [
  { tag_name: 'dsh-v0.1.2-alpha.10', draft: false },
  { tag_name: 'dsh-v0.1.3-alpha.1', draft: false },
  { tag_name: 'dsh-v0.1.3-alpha.2', draft: false },
  { tag_name: 'dsh-v0.1.4-alpha.1', draft: true },
  { tag_name: 'dsh-v0.1.3-alpha.01', draft: false },
  { tag_name: 'v99.0.0', draft: false },
  { tag_name: 'dsh-not-a-version', draft: false },
]

test('selects the highest non-draft DSH source release', () => {
  assert.deepEqual(selectSourceRelease(releases), {
    version: '0.1.3-alpha.2',
    tag: 'dsh-v0.1.3-alpha.2',
  })
})

test('accepts source tag aliases for an exact release', () => {
  for (const requested of ['0.1.3-alpha.2', 'v0.1.3-alpha.2', 'dsh-v0.1.3-alpha.2']) {
    assert.deepEqual(selectSourceRelease(releases, requested), {
      version: '0.1.3-alpha.2',
      tag: 'dsh-v0.1.3-alpha.2',
    })
  }
})

test('sorts a stable source release after prereleases', () => {
  assert.deepEqual(selectSourceRelease([
    { tag_name: 'dsh-v0.1.3-alpha.2', draft: false },
    { tag_name: 'dsh-v0.1.3', draft: false },
  ]), {
    version: '0.1.3',
    tag: 'dsh-v0.1.3',
  })
  assert.equal(normalizeSourceVersion('v0.1.3'), '0.1.3')
})

test('rejects an unknown or malformed source release', () => {
  assert.throws(
    () => selectSourceRelease(releases, 'dsh-v0.1.9-alpha.1'),
    /no source release 0\.1\.9-alpha\.1/,
  )
  assert.throws(
    () => normalizeSourceVersion('dsh-v0.1.3-alpha.01'),
    /leading zero/,
  )
  assert.throws(
    () => selectSourceRelease({}),
    /GitHub releases must be an array/,
  )
})
