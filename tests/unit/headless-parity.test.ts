import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

// mMac's backend repeats the wiring of src/main/index.ts (see the mMac spec).
// This test keeps the two front doors from drifting apart. When a milestone
// ports a method, delete it from notYet.

function names(file: string, pattern: RegExp) {
  const source = readFileSync(new URL(`../../${file}`, import.meta.url), 'utf8')
  return [...source.matchAll(pattern)].map((match) => match[1])
}

const electron = names('src/main/index.ts', /\bhandle\('([^']+)'/g)
const headless = names('src/headless/server.ts', /\bmethod\('([^']+)'/g)

const electronOnly: Record<string, string> = {
  'update-status': 'Sparkle runs natively in mMac',
  'check-updates': 'Sparkle runs natively in mMac',
  'automatic-updates': 'Sparkle runs natively in mMac',
  microphone: 'mMac asks macOS for the microphone',
  bootstrap: 'start returns the same data',
  'choose-cli': 'mMac shows the panel and saves the path as a preference',
  'choose-project': 'mMac shows the panel and sends the folder to add-project',
  attachments: 'mMac shows the panel and sends the chosen paths',
  'mcp-reveal': 'mMac reveals files with NSWorkspace',
  'bridge-reveal': 'mMac reveals files with NSWorkspace',
  'reveal-project': 'mMac reveals files with NSWorkspace',
  'bridge-copy-token': 'mMac keeps the token in the Keychain and copies it',
  external: 'mMac opens links with NSWorkspace',
  'window-action': 'AppKit owns the window',
}

const headlessOnly: Record<string, string> = {
  hello: 'checks that mMac and the backend speak one protocol',
  start: 'carries the data folder and connects to Muse',
  'add-project': 'takes the folder mMac chose in its own panel',
  shutdown: 'the quit path that Electron runs on before-quit',
}

const notYet = [
  'voice',
  'cancel-voice',
  'preferences',
  'mcp-list',
  'mcp-add',
  'mcp-enabled',
  'mcp-remove',
  'mcp-login',
  'bridge-status',
  'bridge-token',
  'worktrees',
  'worktree-merge',
  'worktree-remove',
  'compact',
  'rename',
  'models',
  'set-model',
  'approve',
  'answer',
  'cancel-question',
  'remove-attachment',
  'git-status',
  'git-diff',
  'git-raw-diff',
  'git-revert-file',
  'git-revert-hunk',
  'git-stage-file',
  'files',
  'read-file',
  'terminal',
  'cli-terminal',
  'export',
  'output',
]

describe('headless method parity', () => {
  it('finds both front doors', () => {
    expect(electron).toHaveLength(53)
    expect(headless).toHaveLength(10)
  })

  it('accounts for every Electron channel', () => {
    const missing = electron.filter(
      (name) => !headless.includes(name) && !(name in electronOnly) && !notYet.includes(name),
    )
    expect(missing).toEqual([])
  })

  it('accounts for every headless method', () => {
    const extra = headless.filter((name) => !electron.includes(name) && !(name in headlessOnly))
    expect(extra).toEqual([])
  })

  it('keeps the lists apart', () => {
    const lists = [Object.keys(electronOnly), Object.keys(headlessOnly), notYet]
    const all = lists.flat()
    expect(new Set(all).size).toBe(all.length)
    expect(notYet.filter((name) => headless.includes(name))).toEqual([])
    expect(Object.keys(electronOnly).filter((name) => headless.includes(name))).toEqual([])
  })
})
