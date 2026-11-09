import { randomBytes } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'

// The MCP bridge's bearer token. Kept out of preferences (which reach the
// renderer) in its own file, encrypted with the OS keychain when available.

export type TokenCipher = {
  available(): boolean
  encrypt(value: string): Buffer
  decrypt(value: Buffer): string
}

const PLAIN = Buffer.from('plain:')

export async function readToken(file: string, cipher: TokenCipher): Promise<string> {
  let stored: Buffer
  try {
    stored = await readFile(file)
  } catch {
    return ''
  }
  if (stored.subarray(0, PLAIN.length).equals(PLAIN))
    return stored.subarray(PLAIN.length).toString('utf8')
  try {
    return cipher.available() ? cipher.decrypt(stored) : ''
  } catch {
    return ''
  }
}

export async function regenerateToken(file: string, cipher: TokenCipher): Promise<string> {
  const token = randomBytes(24).toString('base64url')
  const stored = cipher.available()
    ? cipher.encrypt(token)
    : Buffer.concat([PLAIN, Buffer.from(token, 'utf8')])
  await writeFile(file, stored, { mode: 0o600 })
  return token
}
