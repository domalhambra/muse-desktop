import { describe, expect, it } from 'vitest'
import type { MuseSession, SessionView, TranscriptItem } from '../../src/shared/protocol'
import { exportMarkdown, exportTitle } from '../../src/headless/export'

// Electron's Markdown export (src/main/index.ts, the `export` handler), pinned byte for byte.
// The worked example is the survey's (docs/superpowers/plans/2026-10-22-mmac-m4a-survey.md,
// Part 1, section 3).

function session(overrides: Partial<MuseSession> = {}): MuseSession {
  return {
    sessionId: 's1',
    workspaceRoot: null,
    createdAt: '2026-10-21T00:00:00Z',
    updatedAt: '2026-10-21T00:00:00Z',
    status: 'idle',
    activeTurnId: null,
    modelId: null,
    turnCount: 0,
    ...overrides,
  }
}

function item(overrides: Partial<TranscriptItem> & Pick<TranscriptItem, 'kind'>): TranscriptItem {
  return { itemId: 'i', revision: 1, status: 'completed', ...overrides }
}

function view(value: MuseSession, items: TranscriptItem[]): SessionView {
  return { session: value, items, approvals: [], questions: [] }
}

describe('exportMarkdown', () => {
  it('writes the survey’s worked example byte for byte', () => {
    const conversation = view(session({ name: 'Fix: the "bug" / ok 🎉' }), [
      item({ kind: 'userMessage', text: 'Hello' }),
      item({ kind: 'reasoning', summary: ['think a', 'think b'] }),
      item({ kind: 'toolCall', tool: 'shell', visibleOutput: 'a\nb' }),
      item({ kind: 'toolCall', tool: 'edit' }),
      item({ kind: 'agentMessage', text: 'Done.\n```ts\nconst x = 1\n```' }),
      item({ kind: 'hookRun', fallbackText: 'hook' }),
    ])
    const expected =
      '# Fix: the "bug" / ok 🎉\n\n' +
      'Project: None\n\n' +
      '## You\n\nHello\n\n' +
      '## reasoning\n\nthink a\nthink b\n\n' +
      '## shell\n\na\nb\n\n' +
      '## edit\n\n\n\n' +
      '## Muse\n\nDone.\n```ts\nconst x = 1\n```\n\n' +
      '## hookRun\n\nhook\n'
    const text = exportMarkdown(conversation, exportTitle(conversation.session))
    expect(Buffer.from(text, 'utf8').equals(Buffer.from(expected, 'utf8'))).toBe(true)
    expect(Buffer.byteLength(text)).toBe(170)
  })

  it('takes the first body field that has text, and the tool, else the kind, as the heading', () => {
    const conversation = view(session({ workspaceRoot: '/p' }), [
      item({ kind: 'userMessage', displayText: 'Shown', text: 'raw' }),
      item({
        kind: 'toolCall',
        tool: '',
        text: '',
        visibleOutput: '',
        fallbackText: '',
        summary: [],
        objective: 'Goal',
      }),
      item({ kind: 'subagent' }),
    ])
    expect(exportMarkdown(conversation, 'T')).toBe(
      '# T\n\nProject: /p\n\n## You\n\nShown\n\n## toolCall\n\nGoal\n\n## subagent\n\n\n',
    )
  })

  it('writes the title and project alone for a conversation with no items', () => {
    expect(exportMarkdown(view(session(), []), 'Muse conversation')).toBe(
      '# Muse conversation\n\nProject: None\n',
    )
  })
})

describe('exportTitle', () => {
  it('takes the name, then the title, then the sidebar title, then Muse conversation', () => {
    expect(exportTitle(session({ name: 'Name', title: 'Title' }), 'Sidebar')).toBe('Name')
    expect(exportTitle(session({ title: 'Title' }), 'Sidebar')).toBe('Title')
    expect(exportTitle(session({ name: '', title: '' }), 'Sidebar')).toBe('Sidebar')
    expect(exportTitle(session(), '')).toBe('Muse conversation')
    expect(exportTitle(session())).toBe('Muse conversation')
  })

  it('collapses whitespace, newlines included, so the heading stays one line', () => {
    expect(exportTitle(session({ name: '  Fix the\n\nlogin \t bug \n' }))).toBe('Fix the login bug')
    expect(exportTitle(session(), 'First line\nsecond line')).toBe('First line second line')
  })
})
