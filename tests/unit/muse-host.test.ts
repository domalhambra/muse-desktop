import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { AppEvent } from '../../src/shared/protocol'

const wire = vi.hoisted(() => ({
  request: vi.fn(),
  command: vi.fn(),
  close: vi.fn(),
  initializeResult: { experimentalApi: true } as Record<string, unknown>,
  initializeOptions: {} as Record<string, unknown>,
  receive: (_notification: { method: string; params: Record<string, unknown> }) => {},
}))
const trust = vi.hoisted(() => ({ record: vi.fn(async () => true) }))
vi.mock('../../src/main/muse-config', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../src/main/muse-config')>()),
  recordMuseTrust: trust.record,
}))
vi.mock('../../src/main/cli', () => ({
  discoverCli: async () => ({ path: '/test/muse', version: '1.4.7', environment: {} }),
}))
vi.mock('@muse-code/sdk', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@muse-code/sdk')>()),
  spawnMspConnection: () => ({
    close: wire.close,
    initialize: async (options: Record<string, unknown>) => {
      wire.initializeOptions = options
      return {
        close: wire.close,
        initializeResult: wire.initializeResult,
        connection: {
          request: wire.request,
          command: wire.command,
          closed: new Promise(() => {}),
          onNotification: (callback: typeof wire.receive) => {
            wire.receive = callback
          },
          onProtocolError: () => {},
        },
      }
    },
  }),
}))
import { MuseHost } from '../../src/main/muse-host'

const session = {
  sessionId: 's1',
  workspaceRoot: '/project',
  createdAt: '2026-10-12T00:00:00Z',
  updatedAt: '2026-10-12T00:00:00Z',
  status: 'idle',
  activeTurnId: null,
  modelId: null,
  turnCount: 0,
}
const result = (items: object[] = []) => ({
  session: { ...session },
  viewCursor: 'cursor-1',
  history: { mode: 'inline', items, snapshot: null },
})
const approval = {
  sessionId: 's1',
  approvalId: 'approval-1',
  toolName: 'shell',
  rawArgs: '{}',
  currentRequirementId: { approvalId: 'approval-1', sourceIndex: 0 },
  subject: { kind: 'shell', command: 'npm test' },
  availableChoices: [
    { choiceId: 'once', label: 'Allow once', decision: 'approved', scope: 'once' },
    { choiceId: 'deny', label: 'Deny', decision: 'denied', scope: 'once' },
  ],
}
const notify = (method: string, params: Record<string, unknown>) =>
  wire.receive({ method, params: { sessionId: 's1', ...params } })

beforeEach(() => {
  vi.clearAllMocks()
  wire.initializeResult = { experimentalApi: true }
  wire.command.mockImplementation(async (method: string) =>
    method === 'session/start' || method === 'session/resume' ? result() : {},
  )
  wire.request.mockImplementation(async (method: string) =>
    method === 'approval/listPending' ? { approvals: [], userInputs: [] } : result(),
  )
})

describe('Muse protocol boundary', () => {
  it('forwards only an explicit current approval choice and its requirement token', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    notify('approval/requested', approval)
    expect(wire.command).not.toHaveBeenCalledWith(
      'approval/decide',
      expect.anything(),
      expect.anything(),
    )
    await expect(host.approve('s1', 'approval-1', 'invented')).rejects.toThrow('approval changed')
    notify('approval/updated', {
      approvalId: 'approval-1',
      currentRequirementId: { approvalId: 'approval-1', sourceIndex: 2 },
    })
    await host.approve('s1', 'approval-1', 'once')
    expect(wire.command).toHaveBeenLastCalledWith(
      'approval/decide',
      {
        sessionId: 's1',
        approvalId: 'approval-1',
        choiceId: 'once',
        requirementId: { approvalId: 'approval-1', sourceIndex: 2 },
      },
      { maxAttempts: 1 },
    )
    notify('approval/resolved', { approvalId: 'approval-1' })
    await expect(host.approve('s1', 'approval-1', 'once')).rejects.toThrow('approval changed')
    await host.close()
  })

  it('replaces streamed deltas with the completed revision without duplicate text', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    const item = {
      itemId: 'i1',
      kind: 'agentMessage',
      revision: 1,
      status: 'inProgress',
      text: 'Hello',
    }
    notify('item/started', { item })
    notify('item/delta', { itemId: 'i1', delta: ', world.', field: 'text' })
    expect(host.getView('s1').items[0].text).toBe('Hello, world.')
    notify('item/completed', {
      item: { ...item, revision: 2, status: 'completed', text: 'Hello, world.' },
    })
    notify('item/started', { item })
    expect(host.getView('s1').items).toHaveLength(1)
    expect(host.getView('s1').items[0].text).toBe('Hello, world.')
    await host.close()
  })

  it('restores snapshot history and pending requests before replaying a view gap', async () => {
    const events: AppEvent[] = []
    const host = new MuseHost((event) => events.push(event))
    await host.connect('')
    await host.create('/project')
    const item = {
      itemId: 'restored',
      kind: 'agentMessage',
      revision: 3,
      status: 'completed',
      text: 'Recovered',
    }
    wire.request.mockImplementation(async (method: string) =>
      method === 'approval/listPending'
        ? { approvals: [approval], userInputs: [] }
        : result([item]),
    )
    notify('view/gap', {})
    await vi.waitFor(() =>
      expect(wire.request).toHaveBeenCalledWith('view/subscribe', {
        sessionId: 's1',
        after: 'cursor-1',
      }),
    )
    expect(wire.request).toHaveBeenCalledWith('session/read', {
      sessionId: 's1',
      excludeItems: false,
    })
    expect(host.getView('s1').items[0].text).toBe('Recovered')
    expect(host.getView('s1').approvals).toHaveLength(1)
    expect(events.filter((event) => event.type === 'error')).toEqual([])
    await host.close()
  })

  it('reads paged transcripts to the snapshot head and folds item deltas', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    const saved = {
      ...result(),
      viewCursor: 'head',
      history: { mode: 'none', items: null, snapshot: null },
    }
    const item = {
      itemId: 'paged',
      kind: 'agentMessage',
      status: 'inProgress',
      revision: 1,
      text: 'Earlier',
    }
    wire.request.mockImplementation(async (method: string, params: { cursor?: string }) => {
      if (method === 'session/read') return saved
      if (method === 'approval/listPending') return { approvals: [], userInputs: [] }
      if (method === 'view/page')
        return params.cursor
          ? {
              events: [
                {
                  method: 'item/delta',
                  params: {
                    sessionId: 's1',
                    viewCursor: 'head',
                    itemId: 'paged',
                    delta: ' conversation',
                    field: 'text',
                  },
                },
              ],
              nextCursor: null,
            }
          : {
              events: [
                { method: 'item/started', params: { sessionId: 's1', viewCursor: 'first', item } },
              ],
              nextCursor: 'first',
            }
      return {}
    })
    const view = await host.open('s1')
    expect(view.items[0].text).toBe('Earlier conversation')
    expect(view.historyNotice).toBeUndefined()
    expect(wire.request).toHaveBeenCalledWith('view/subscribe', { sessionId: 's1', after: 'head' })
    await host.close()
  })

  it('rejects repeated paging cursors instead of hanging on old history', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    wire.request.mockImplementation(async (method: string) =>
      method === 'session/read'
        ? { ...result(), history: { mode: 'none', items: null, snapshot: null } }
        : { events: [], nextCursor: 'same' },
    )
    await expect(host.open('s1')).rejects.toThrow('repeated transcript cursor')
    await host.close()
  })

  it('sets the approval mode and keeps the session current from the reply and the event', async () => {
    const events: AppEvent[] = []
    const host = new MuseHost((event) => events.push(event))
    await host.connect('')
    await host.create('/project')
    wire.command.mockImplementation(async (method: string) => {
      if (method === 'session/setApprovalMode')
        return {
          applyOutcome: 'completed',
          effectiveMode: { mode: 'onRequest', source: 'approvalReconfigure' },
        }
      return method === 'session/start' || method === 'session/resume' ? result() : {}
    })
    await expect(host.setApprovalMode('s1', 'onRequest')).resolves.toBe('onRequest')
    expect(wire.command).toHaveBeenLastCalledWith(
      'session/setApprovalMode',
      { sessionId: 's1', mode: 'onRequest' },
      { maxAttempts: 1 },
    )
    expect(host.getSession('s1').approvalMode?.mode).toBe('onRequest')
    notify('session/approvalModeChanged', { mode: 'denyUnmatched', source: 'replay' })
    expect(host.getSession('s1').approvalMode?.mode).toBe('denyUnmatched')
    await host.close()
  })

  it('approval mode: a changed event for an unknown session is ignored', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    wire.receive({
      method: 'session/approvalModeChanged',
      params: { sessionId: 'other', mode: 'allowAll' },
    })
    expect(host.getSession('s1').approvalMode).toBeUndefined()
    await host.close()
  })

  it('folds context usage into the view, with and without a window', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    notify('session/contextUsage', { usedTokens: 4200, windowTokens: 10000, pressure: 'normal' })
    expect(host.getView('s1').context).toEqual({ used: 4200, window: 10000, pressure: 'normal' })
    notify('session/contextUsage', { usedTokens: 9900, pressure: 'blocked' })
    expect(host.getView('s1').context).toEqual({
      used: 9900,
      window: undefined,
      pressure: 'blocked',
    })
    await host.close()
  })

  const usage = {
    observedAtMs: 1_800_000_000_000,
    tier: 'pro',
    window: { usedPercent: 42, resetsAtMs: 1_800_000_600_000, windowDurationMins: 300 },
    weekly: { usedPercent: 112, resetsAtMs: 1_800_400_000_000 },
  }
  const limits = {
    observedAt: 1_800_000_000_000,
    tier: 'pro',
    window: { usedPercent: 42, resetsAt: 1_800_000_600_000, minutes: 300 },
    weekly: { usedPercent: 112, resetsAt: 1_800_400_000_000 },
  }

  it('reads the limits once at connect and emits them', async () => {
    const events: AppEvent[] = []
    wire.request.mockImplementation(async (method: string) =>
      method === 'usage/read' ? { usage } : {},
    )
    const host = new MuseHost((event) => events.push(event))
    await host.connect('')
    await vi.waitFor(() => expect(host.limits).toEqual(limits))
    expect(wire.request.mock.calls.filter(([method]) => method === 'usage/read')).toHaveLength(1)
    expect(events).toContainEqual({ type: 'usage-changed', limits })
    await host.close()
  })

  it('keeps the limits null when Muse has observed nothing or the read fails', async () => {
    const events: AppEvent[] = []
    wire.request.mockImplementation(async (method: string) => {
      if (method === 'usage/read') throw new Error('Method not found')
      return {}
    })
    const host = new MuseHost((event) => events.push(event))
    expect((await host.connect('')).state).toBe('ready')
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(host.limits).toBeNull()
    expect(events.some((event) => event.type === 'usage-changed')).toBe(false)
    await host.close()
  })

  it('folds usage/changed into the limits without a session id', async () => {
    const events: AppEvent[] = []
    const host = new MuseHost((event) => events.push(event))
    await host.connect('')
    notify('usage/changed', { ...usage, window: { ...usage.window, usedPercent: 85 } })
    expect(host.limits?.window.usedPercent).toBe(85)
    expect(events.at(-1)).toEqual({
      type: 'usage-changed',
      limits: { ...limits, window: { ...limits.window, usedPercent: 85 } },
    })
    await host.close()
  })

  it('keeps the session cost and the quota stop, and clears the stop on a clean turn', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    notify('session/tokenUsage', {
      sessionId: 's1',
      cumulative: {
        promptTokens: 100,
        outputTokens: 28,
        totalTokens: 128,
        cost: { usd: 0.84, partial: true },
      },
    })
    expect(host.getView('s1').cost).toEqual({ usd: 0.84, partial: true })
    notify('turn/completed', {
      sessionId: 's1',
      turnId: 't1',
      error: {
        kind: 'modelError',
        message: 'quota',
        retryable: false,
        quota: { limitKind: 'tierLimit', resetsAtMs: 1_800_000_600_000 },
      },
    })
    expect(host.getView('s1').quota).toEqual({ kind: 'tierLimit', resetsAt: 1_800_000_600_000 })
    notify('turn/completed', { sessionId: 's1', turnId: 't2' })
    expect(host.getView('s1').quota).toBeUndefined()
    await host.close()
  })

  it('replaces the todo list wholesale and clears it on an empty list', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    notify('session/todoListChanged', {
      items: [
        {
          text: 'Clean the build folder',
          status: 'inProgress',
          activeForm: 'Cleaning the build folder',
        },
        { text: 'Run the tests', status: 'pending' },
      ],
      revision: 1,
      sourceTool: 'TodoWrite',
    })
    expect(host.getView('s1').todos?.map((todo) => todo.text)).toEqual([
      'Clean the build folder',
      'Run the tests',
    ])
    notify('session/todoListChanged', { items: [], revision: 2, sourceTool: 'TodoWrite' })
    expect(host.getView('s1').todos).toEqual([])
    await host.close()
  })

  it('opens a side chat as a loaded session of its own', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    wire.command.mockImplementation(async (method: string) => {
      if (method === 'session/sideChat')
        return { ...result(), session: { ...session, sessionId: 'side-1', kind: 'sideChat' } }
      return method === 'session/start' || method === 'session/resume' ? result() : {}
    })
    const side = await host.sideChat('s1')
    expect(side.session.sessionId).toBe('side-1')
    expect(wire.command).toHaveBeenCalledWith(
      'session/sideChat',
      { sessionId: 's1' },
      { maxAttempts: 1 },
    )
    // Loaded: a send goes straight out, with no resume first.
    wire.command.mockClear()
    await host.send('side-1', [{ type: 'text', text: 'hi' }], 'high', 'queue', 'hi')
    expect(wire.command.mock.calls.map((call) => call[0])).toEqual(['turn/start'])
    await host.close()
  })

  it('runs a shell command in the session and asks for the userShell capability', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    await host.runShell('s1', 'echo hi')
    expect(wire.command).toHaveBeenLastCalledWith(
      'session/userShell',
      { sessionId: 's1', commandText: 'echo hi' },
      { maxAttempts: 1 },
    )
    expect(wire.initializeOptions).toMatchObject({
      capabilities: { requestedCapabilities: ['sessionListStream', 'userShell'] },
    })
    await host.close()
  })

  it('dispatches compaction through the CLI without rewriting the conversation', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    wire.command.mockResolvedValueOnce({ status: 'noop' })
    expect(await host.compact('s1')).toEqual({ status: 'noop' })
    expect(wire.command).toHaveBeenLastCalledWith(
      'session/compact',
      { sessionId: 's1' },
      { maxAttempts: 1 },
    )
    await host.close()
  })

  it('forwards questions, queue and steer modes, and cancellation without policy changes', async () => {
    const host = new MuseHost(() => {})
    await host.connect('')
    await host.create('/project')
    notify('userInput/requested', {
      userInputId: 'q1',
      questions: [
        {
          id: 'color',
          header: 'Color',
          question: 'Which color?',
          options: [{ label: 'Blue' }],
          selection: { mode: 'single' },
        },
      ],
    })
    expect(host.getView('s1').questions).toHaveLength(1)
    await host.answer('s1', 'q1', [{ questionId: 'color', selectedLabel: 'Blue' }])
    expect(wire.command).toHaveBeenLastCalledWith(
      'userInput/answer',
      {
        sessionId: 's1',
        userInputId: 'q1',
        answers: [{ questionId: 'color', selectedLabel: 'Blue' }],
      },
      { maxAttempts: 1 },
    )
    notify('userInput/settled', { userInputId: 'q1' })
    expect(host.getView('s1').questions).toEqual([])
    for (const mode of ['queue', 'steer']) {
      await host.send('s1', [{ type: 'text', text: 'Next' }], 'high', mode, 'Next')
      expect(wire.command).toHaveBeenLastCalledWith(
        'turn/start',
        {
          sessionId: 's1',
          input: [{ type: 'text', text: 'Next' }],
          displayText: 'Next',
          reasoningEffort: 'high',
          ifBusy: mode,
        },
        { maxAttempts: 1 },
      )
    }
    await host.cancel('s1')
    expect(wire.command).toHaveBeenLastCalledWith(
      'turn/cancel',
      { sessionId: 's1' },
      { maxAttempts: 1 },
    )
    await host.close()
  })
})

describe('Muse worktrees', () => {
  it('asks Muse to create a worktree only when requested', async () => {
    const host = new MuseHost(() => {})
    expect((await host.connect('/test/muse')).experimental).toBe(true)
    await host.create('/project')
    expect(wire.command.mock.calls.at(-1)?.[1]).toEqual({ workspaceRoot: '/project' })
    expect(trust.record).not.toHaveBeenCalled()
    await host.create('/project', undefined, { worktree: true })
    expect(wire.command.mock.calls.at(-1)?.[1]).toEqual({
      workspaceRoot: '/project',
      worktree: { mode: 'create' },
    })
    expect(trust.record).toHaveBeenLastCalledWith(expect.any(String), '/project')
  })
  it('makes a new worktree from the parent project when started inside a worktree', async () => {
    const host = new MuseHost(() => {})
    await host.connect('/test/muse')
    await host.create('/project/.muse/worktrees/20261020-ab12', undefined, { worktree: true })
    expect(wire.command.mock.calls.at(-1)?.[1]).toMatchObject({ workspaceRoot: '/project' })
    expect(trust.record).toHaveBeenLastCalledWith(expect.any(String), '/project')
  })
  it('refuses worktree sessions when the CLI withholds experimental methods', async () => {
    wire.initializeResult = { experimentalApi: false }
    const host = new MuseHost(() => {})
    await host.connect('/test/muse')
    await expect(host.create('/project', undefined, { worktree: true })).rejects.toThrow('worktree')
    expect(await host.listWorktrees('/project')).toEqual([])
  })
  it('lists worktrees and treats an untrusted repository as having none', async () => {
    const host = new MuseHost(() => {})
    await host.connect('/test/muse')
    const entry = { path: '/project', branch: 'main', isMain: true, sessionIds: [] }
    wire.request.mockImplementationOnce(async () => ({ worktrees: [entry] }))
    expect(await host.listWorktrees('/project')).toEqual([entry])
    const { MspError } = await import('@muse-code/sdk')
    wire.request.mockImplementationOnce(async () => {
      throw new MspError({
        code: -32000,
        message: 'not trusted',
        data: { kind: 'workspaceNotTrusted' },
      })
    })
    expect(await host.listWorktrees('/project')).toEqual([])
  })
})
