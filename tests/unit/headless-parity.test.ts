import { readdirSync, readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { HEADLESS_PROTOCOL } from '../../src/headless/wire'

// mMac's backend has been the app's only front door since M4a removed Electron's shell. This test
// pins its method list. Adding or removing a method changes the protocol mMac speaks: update
// `expected`, give the method its typed call in mac/Packages/MuseBackend, and raise
// HEADLESS_PROTOCOL with backendProtocol when a message shape changes.

function read(file: string) {
  return readFileSync(new URL(`../../${file}`, import.meta.url), 'utf8')
}

const methods = [...read('src/headless/backend.ts').matchAll(/\bmethod\('([^']+)'/g)].map(
  (match) => match[1],
)

const expected = [
  // The launch, the connection and the quit path
  'hello',
  'start',
  'connect',
  'shutdown',
  // Projects and conversations
  'add-project',
  'sessions',
  'create',
  'open',
  'send',
  'cancel',
  'rename',
  'compact',
  'export',
  'models',
  'set-model',
  'set-approval-mode',
  'side-chat',
  'shell',
  'preferences',
  // Approvals, questions and stored output
  'approve',
  'answer',
  'cancel-question',
  'output',
  // The inspector
  'git-status',
  'git-diff',
  'git-raw-diff',
  'git-revert-file',
  'git-revert-hunk',
  'git-stage-file',
  'files',
  'read-file',
  'worktrees',
  'worktree-merge',
  'worktree-remove',
  // Settings: MCP servers and bridges
  'mcp-list',
  'mcp-add',
  'mcp-enabled',
  'mcp-remove',
  'mcp-login',
  'bridge-status',
  'bridge-token',
  // The composer: attachments and voice
  'attachments',
  'remove-attachment',
  'voice',
  'cancel-voice',
  // The inspector's footer
  'terminal',
  'cli-terminal',
]

const swiftFolder = new URL('../../mac/Packages/MuseBackend/Sources/MuseBackend/', import.meta.url)
const swift = readdirSync(swiftFolder)
  .filter((name) => name.endsWith('.swift'))
  .map((name) => readFileSync(new URL(name, swiftFolder), 'utf8'))
  .join('\n')

describe('the backend method list', () => {
  it('registers each method once', () => {
    expect(methods.filter((name, index) => methods.indexOf(name) !== index)).toEqual([])
  })

  it('registers exactly the expected methods', () => {
    expect(
      [...methods].sort(),
      'Register a method with a literal method(…) call, and list it in expected here',
    ).toEqual([...expected].sort())
    expect(expected).toHaveLength(47)
  })

  it('gives every method a call in MuseBackend', () => {
    expect(
      expected.filter((name) => !swift.includes(`"${name}"`)),
      'Add a typed call that names the method in mac/Packages/MuseBackend/Sources/MuseBackend/',
    ).toEqual([])
  })

  it('speaks the same protocol number as MuseBackend', () => {
    const match = swift.match(/public let backendProtocol = (\d+)/)
    expect(match, 'Messages.swift should declare public let backendProtocol = N').not.toBeNull()
    expect(
      Number(match![1]),
      'Raise HEADLESS_PROTOCOL in src/headless/wire.ts and backendProtocol in Messages.swift together',
    ).toBe(HEADLESS_PROTOCOL)
  })
})
