import { describe, expect, it } from 'vitest'
import { AgentApi, renderTranscript, type AgentHost } from '../../src/main/agent-api'
import { publish } from '../../src/main/event-bus'
import type { SessionView } from '../../src/shared/protocol'

function view(sessionId: string, status: string, items: SessionView['items'] = []): SessionView {
  return {
    session: {
      sessionId,
      workspaceRoot: '/p',
      createdAt: '',
      updatedAt: '',
      status,
      activeTurnId: null,
      modelId: null,
      turnCount: 1,
    },
    items,
    approvals: [],
    questions: [],
  }
}
const message = (itemId: string, kind: string, text: string) => ({
  itemId,
  kind,
  revision: 1,
  status: 'completed',
  text,
})

function fakeHost(existing: SessionView['items'] = []) {
  const calls: unknown[][] = []
  const host: AgentHost & { calls: unknown[][] } = {
    calls,
    create: async (project, modelId, options) => {
      calls.push(['create', project, modelId, options])
      return view('s1', 'idle')
    },
    open: async (id) => view(id, 'idle', existing),
    send: async (...args) => {
      calls.push(['send', ...args])
    },
    approve: async (...args) => {
      calls.push(['approve', ...args])
    },
    answer: async (...args) => {
      calls.push(['answer', ...args])
    },
    cancel: async (...args) => {
      calls.push(['cancel', ...args])
    },
    list: async () => ({ sessions: [], nextCursor: null }),
  }
  return host
}
const trusted = { resolveProject: async (project: string) => project }

describe('AgentApi', () => {
  it('creates a session, sends the prompt and completes after the turn runs', async () => {
    const host = fakeHost()
    const api = new AgentApi(host, trusted)
    const job = await api.ask({ project: '/p', prompt: 'hello', effort: 'medium' })
    expect(job.status).toBe('running')
    expect(host.calls[0]).toEqual(['create', '/p', undefined, { worktree: undefined }])
    expect(host.calls[1]).toEqual([
      'send',
      's1',
      [{ type: 'text', text: 'hello' }],
      'medium',
      'queue',
      'hello',
    ])
    const reply = [message('u1', 'userMessage', 'hello'), message('a1', 'agentMessage', 'hi there')]
    publish({ type: 'session', view: view('s1', 'running', reply) })
    expect(api.get(job.id)!.status).toBe('running')
    publish({ type: 'session', view: view('s1', 'idle', reply) })
    const done = api.get(job.id)!
    expect(done.status).toBe('done')
    expect(done.reply).toBe('hi there')
    expect(done.transcript).toContain('**You:** hello')
    api.dispose()
  })
  it('ignores an idle view that arrives before the turn is seen running', async () => {
    const api = new AgentApi(fakeHost(), trusted)
    const job = await api.ask({ project: '/p', prompt: 'x', effort: 'low' })
    publish({ type: 'session', view: view('s1', 'idle') })
    expect(api.get(job.id)!.status).toBe('running')
    api.dispose()
  })
  it('passes the worktree option to Muse', async () => {
    const host = fakeHost()
    const api = new AgentApi(host, trusted)
    await api.ask({ project: '/p', prompt: 'x', effort: 'low', worktree: true })
    expect(host.calls[0]).toEqual(['create', '/p', undefined, { worktree: true }])
    api.dispose()
  })
  it('reports pending approvals and questions, and forwards decisions', async () => {
    const host = fakeHost()
    const api = new AgentApi(host, trusted)
    const job = await api.ask({ project: '/p', prompt: 'rm things', effort: 'medium' })
    const pending = view('s1', 'running')
    pending.approvals = [
      {
        approvalId: 'a1',
        sessionId: 's1',
        toolName: 'shell',
        rawArgs: '',
        currentRequirementId: { approvalId: 'a1', sourceIndex: 0 },
        subject: { kind: 'command', command: 'rm -rf build' },
        availableChoices: [{ choiceId: 'c1', label: 'Allow', decision: 'allow', scope: 'once' }],
      },
    ]
    publish({ type: 'session', view: pending })
    expect(api.get(job.id)).toMatchObject({
      status: 'waiting-approval',
      approvals: [
        {
          approvalId: 'a1',
          summary: 'shell: rm -rf build',
          choices: [{ choiceId: 'c1', label: 'Allow' }],
        },
      ],
    })
    await api.approve(job.id, 'a1', 'c1')
    expect(host.calls.at(-1)).toEqual(['approve', 's1', 'a1', 'c1'])
    const asking = view('s1', 'running')
    asking.questions = [
      {
        userInputId: 'q1',
        sessionId: 's1',
        questions: [
          {
            id: 'which',
            header: 'Pick',
            question: 'Which one?',
            options: [{ label: 'A' }, { label: 'B' }],
            selection: { mode: 'single' },
          },
        ],
      },
    ]
    publish({ type: 'session', view: asking })
    expect(api.get(job.id)).toMatchObject({
      status: 'waiting-input',
      questions: [{ userInputId: 'q1', questions: [{ id: 'which', options: ['A', 'B'] }] }],
    })
    await api.answer(job.id, 'q1', [{ questionId: 'which', selectedLabel: 'A' }])
    expect(host.calls.at(-1)).toEqual([
      'answer',
      's1',
      'q1',
      [{ questionId: 'which', selectedLabel: 'A' }],
    ])
    api.dispose()
  })
  it('limits a session to one active job and cancels through Muse', async () => {
    const host = fakeHost()
    const api = new AgentApi(host, trusted)
    const job = await api.ask({ project: '/p', sessionId: 's1', prompt: 'one', effort: 'low' })
    await expect(
      api.ask({ project: '/p', sessionId: 's1', prompt: 'two', effort: 'low' }),
    ).rejects.toThrow('still active')
    await api.cancel(job.id)
    expect(host.calls.at(-1)).toEqual(['cancel', 's1'])
    expect(api.get(job.id)!.status).toBe('cancelled')
    await api.ask({ project: '/p', sessionId: 's1', prompt: 'three', effort: 'low' })
    api.dispose()
  })
  it('limits the transcript to items this job produced', async () => {
    const earlier = [message('old', 'agentMessage', 'from an earlier turn')]
    const api = new AgentApi(fakeHost(earlier), trusted)
    const job = await api.ask({ sessionId: 's1', prompt: 'new', effort: 'low' })
    const items = [...earlier, message('new', 'agentMessage', 'this turn')]
    publish({ type: 'session', view: view('s1', 'running', items) })
    expect(api.get(job.id)!.reply).toBe('this turn')
    expect(api.get(job.id)!.transcript).not.toContain('earlier')
    api.dispose()
  })
  it('surfaces a turn error', async () => {
    const api = new AgentApi(fakeHost(), trusted)
    const job = await api.ask({ project: '/p', prompt: 'x', effort: 'low' })
    publish({ type: 'session', view: { ...view('s1', 'idle'), error: 'model unavailable' } })
    expect(api.get(job.id)).toMatchObject({ status: 'error', error: 'model unavailable' })
    api.dispose()
  })
  it('refuses projects and sessions outside the trusted set', async () => {
    const refuse = {
      resolveProject: async () => {
        throw new Error('That project is not trusted in Muse Desktop.')
      },
    }
    const api = new AgentApi(fakeHost(), refuse)
    await expect(api.ask({ project: '/nope', prompt: 'x', effort: 'low' })).rejects.toThrow(
      'trusted',
    )
    await expect(api.ask({ sessionId: 's9', prompt: 'x', effort: 'low' })).rejects.toThrow(
      'trusted',
    )
    api.dispose()
  })
  it('renders tool calls and subagents', () => {
    const text = renderTranscript([
      { itemId: '1', kind: 'userMessage', revision: 1, status: 'completed', text: 'do it' },
      {
        itemId: '2',
        kind: 'toolCall',
        revision: 1,
        status: 'completed',
        tool: 'shell',
        commandText: 'ls',
        visibleOutput: 'a.txt',
      },
      { itemId: '3', kind: 'reasoning', revision: 1, status: 'completed', text: 'private' },
      { itemId: '4', kind: 'agentMessage', revision: 1, status: 'completed', text: 'done' },
    ])
    expect(text).toContain('**You:** do it')
    expect(text).toContain('> `ls`')
    expect(text).toContain('a.txt')
    expect(text).not.toContain('private')
    expect(text).toContain('done')
  })
})
