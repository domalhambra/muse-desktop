import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { HEADLESS_PROTOCOL } from '../../src/headless/wire'

// mMac's backend repeats the wiring of src/main/index.ts (see the mMac spec).
// This test keeps the two front doors from drifting apart. When a milestone
// ports a method, delete it from notYet.

function names(file: string, pattern: RegExp) {
  const source = readFileSync(new URL(`../../${file}`, import.meta.url), 'utf8')
  return [...source.matchAll(pattern)].map((match) => match[1])
}

const electron = names('src/main/index.ts', /\bhandle\('([^']+)'/g)
const headless = names('src/headless/backend.ts', /\bmethod\('([^']+)'/g)
const preload = names('src/preload/index.ts', /\binvoke\('([^']+)'/g)

const electronOnly: Record<string, string> = {
  'update-status': 'Sparkle runs natively in mMac',
  'check-updates': 'Sparkle runs natively in mMac',
  'automatic-updates': 'Sparkle runs natively in mMac',
  microphone: 'mMac asks macOS for the microphone',
  bootstrap: 'hello and start return its data; mMac knows the home folder and platform natively',
  'choose-cli': 'mMac shows the panel and saves the path as a preference',
  'choose-project': 'mMac shows the panel and sends the folder to add-project',
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

const notYet: string[] = []

function duplicates(list: string[]) {
  return list.filter((name, index) => list.indexOf(name) !== index)
}

describe('headless method parity', () => {
  it('finds both front doors', () => {
    expect(electron).toHaveLength(53)
    expect(headless).toHaveLength(44)
  })

  it('finds every Electron channel the preload calls', () => {
    expect(
      [...electron].sort(),
      'src/main/index.ts and src/preload/index.ts disagree: a registration the regex cannot see may have been added',
    ).toEqual([...preload].sort())
  })

  it('accounts for every Electron channel', () => {
    const missing = electron.filter(
      (name) => !headless.includes(name) && !(name in electronOnly) && !notYet.includes(name),
    )
    expect(
      missing,
      'Port it in src/headless/backend.ts, or add it to electronOnly with a reason, or to notYet',
    ).toEqual([])
  })

  it('accounts for every headless method', () => {
    const extra = headless.filter((name) => !electron.includes(name) && !(name in headlessOnly))
    expect(
      extra,
      'Add it to src/main/index.ts as a channel, or to headlessOnly with a reason',
    ).toEqual([])
  })

  it('keeps the lists apart', () => {
    const lists = [Object.keys(electronOnly), Object.keys(headlessOnly), notYet]
    expect(duplicates(lists.flat())).toEqual([])
    expect(notYet.filter((name) => headless.includes(name))).toEqual([])
    expect(Object.keys(electronOnly).filter((name) => headless.includes(name))).toEqual([])
  })

  it('speaks the same protocol number as MuseBackend', () => {
    const swift = readFileSync(
      new URL('../../mac/Packages/MuseBackend/Sources/MuseBackend/Messages.swift', import.meta.url),
      'utf8',
    )
    const match = swift.match(/public let backendProtocol = (\d+)/)
    expect(match, 'Messages.swift should declare public let backendProtocol = N').not.toBeNull()
    expect(
      Number(match![1]),
      'Raise HEADLESS_PROTOCOL in src/headless/wire.ts and backendProtocol in Messages.swift together',
    ).toBe(HEADLESS_PROTOCOL)
  })

  it('has no stale entries', () => {
    expect(notYet.filter((name) => !electron.includes(name))).toEqual([])
    expect(Object.keys(electronOnly).filter((name) => !electron.includes(name))).toEqual([])
    expect(Object.keys(headlessOnly).filter((name) => !headless.includes(name))).toEqual([])
    expect(Object.keys(headlessOnly).filter((name) => electron.includes(name))).toEqual([])
  })
})
