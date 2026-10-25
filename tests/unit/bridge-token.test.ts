import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { readToken, regenerateToken, type TokenCipher } from '../../src/main/bridge-token'

let dir: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'muse-token-'))
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})
const reversing: TokenCipher = {
  available: () => true,
  encrypt: (value) => Buffer.from([...value].reverse().join('')),
  decrypt: (value) => [...value.toString()].reverse().join(''),
}
const unavailable: TokenCipher = { ...reversing, available: () => false }

describe('bridge token', () => {
  it('returns no token before one is made', async () => {
    expect(await readToken(join(dir, 'token'), reversing)).toBe('')
  })
  it('stores the token encrypted and private, and replaces it on regeneration', async () => {
    const file = join(dir, 'token')
    const first = await regenerateToken(file, reversing)
    expect(first).toMatch(/^[A-Za-z0-9_-]{32}$/)
    expect((await readFile(file)).toString()).not.toContain(first)
    expect((await stat(file)).mode & 0o777).toBe(0o600)
    expect(await readToken(file, reversing)).toBe(first)
    const second = await regenerateToken(file, reversing)
    expect(second).not.toBe(first)
    expect(await readToken(file, reversing)).toBe(second)
  })
  it('falls back to a private plain file without a keychain', async () => {
    const file = join(dir, 'token')
    const token = await regenerateToken(file, unavailable)
    expect(await readToken(file, unavailable)).toBe(token)
  })
})
