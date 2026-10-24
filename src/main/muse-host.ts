import { ItemStore, MspError, spawnMspConnection, type SpawnedMspConnection } from '@muse-code/sdk'
import { z } from 'zod'
import {
  approvalSchema,
  itemSchema,
  modelSchema,
  questionSchema,
  sessionSchema,
  todoItemSchema,
  worktreeEntrySchema,
  type AppEvent,
  type ApprovalMode,
  type ConnectionStatus,
  type MuseSession,
  type QuestionAnswer,
  type SessionView,
  type SubscriptionLimits,
  type TranscriptItem,
} from '../shared/protocol'
import { discoverCli } from './cli'
import { museConfigDir, recordMuseTrust } from './muse-config'
import { projectRoot } from '../shared/worktree'

const sessionResultSchema = z.object({
  session: sessionSchema,
  viewCursor: z.string(),
  history: z
    .object({
      items: z.array(itemSchema).nullable(),
      mode: z.string(),
      snapshot: z.object({ state: z.object({ items: z.array(itemSchema) }) }).nullable(),
    })
    .optional(),
  lastTurn: z.object({ error: z.object({ message: z.string() }).optional() }).optional(),
})
const pendingSchema = z.object({
  approvals: z.array(approvalSchema),
  userInputs: z.array(questionSchema),
})
/** `SubscriptionUsage` (msp.d.ts:2543), the payload of `usage/read` and `usage/changed`. */
const subscriptionUsageSchema = z.object({
  observedAtMs: z.number(),
  tier: z.string(),
  window: z.object({
    usedPercent: z.number(),
    resetsAtMs: z.number(),
    windowDurationMins: z.number(),
  }),
  weekly: z.object({ usedPercent: z.number(), resetsAtMs: z.number() }),
})

function toLimits(value: unknown): SubscriptionLimits {
  const usage = subscriptionUsageSchema.parse(value)
  return {
    observedAt: usage.observedAtMs,
    tier: usage.tier,
    window: {
      usedPercent: usage.window.usedPercent,
      resetsAt: usage.window.resetsAtMs,
      minutes: usage.window.windowDurationMins,
    },
    weekly: { usedPercent: usage.weekly.usedPercent, resetsAt: usage.weekly.resetsAtMs },
  }
}

type LiveSession = { view: SessionView; store: ItemStore<TranscriptItem>; loaded: boolean }

export class MuseHost {
  status: ConnectionStatus = { state: 'connecting' }
  private host?: SpawnedMspConnection
  private connecting?: Promise<ConnectionStatus>
  private sessions = new Map<string, LiveSession>()
  private timers = new Map<string, ReturnType<typeof setTimeout>>()
  private refreshing = new Set<string>()
  private closing = false
  private environment: NodeJS.ProcessEnv = process.env
  private experimental = false
  /** The subscription's limits as Muse last observed them, or null before any observation. */
  limits: SubscriptionLimits | null = null

  constructor(private emit: (event: AppEvent) => void) {}

  connect(cliPath: string): Promise<ConnectionStatus> {
    if (this.connecting) return this.connecting
    this.connecting = this.start(cliPath).finally(() => {
      this.connecting = undefined
    })
    return this.connecting
  }

  private async start(cliPath: string): Promise<ConnectionStatus> {
    await this.close()
    this.closing = false
    this.limits = null
    this.setStatus({ state: 'connecting' })
    let handshake: ReturnType<typeof spawnMspConnection> | undefined
    try {
      const cli = await discoverCli(cliPath)
      this.environment = cli.environment
      const isCmdWrapper = process.platform === 'win32' && /\.(cmd|bat)$/i.test(cli.path)
      const serveArgs = [
        'serve',
        '--trust-workspace',
        ...(process.env.MUSE_DESKTOP_TEST_PROVIDER === 'echo' ? ['--provider', 'echo'] : []),
      ]
      handshake = spawnMspConnection({
        command: isCmdWrapper ? process.env.ComSpec || 'cmd.exe' : cli.path,
        args: isCmdWrapper ? ['/d', '/s', '/c', cli.path, ...serveArgs] : serveArgs,
        env: cli.environment,
        shutdownTimeoutMs: 3000,
      })
      let timeout: ReturnType<typeof setTimeout> | undefined
      try {
        this.host = await Promise.race([
          handshake.initialize({
            clientInfo: { name: 'muse_desktop', title: 'Muse Desktop', version: '0.2.0' },
            capabilities: {
              userInputDialogs: true,
              requestedCapabilities: ['sessionListStream', 'userShell'],
              experimentalApi: true,
            },
          }),
          new Promise<never>((_, reject) => {
            timeout = setTimeout(
              () =>
                reject(
                  new Error(
                    'Muse did not finish connecting within 15 seconds. Check the CLI in Terminal.',
                  ),
                ),
              15000,
            )
          }),
        ])
      } finally {
        clearTimeout(timeout)
      }
      this.host.connection.onNotification((notification) => {
        try {
          this.receive(notification.method, notification.params ?? {})
        } catch (error) {
          this.emit({ type: 'error', message: `Could not read a Muse update: ${messageOf(error)}` })
        }
      })
      this.host.connection.onProtocolError((error) =>
        this.emit({ type: 'error', message: error.message }),
      )
      const ownedHost = this.host
      void ownedHost.connection.closed.then(() => {
        if (this.closing || this.host !== ownedHost) return
        this.host = undefined
        this.setStatus({
          ...this.status,
          state: 'error',
          message: 'The Muse connection closed. Reconnect to restore your saved conversations.',
        })
      })
      this.experimental = this.host.initializeResult?.experimentalApi === true
      this.setStatus({
        state: 'ready',
        experimental: this.experimental,
        path: cli.path,
        version: cli.version,
        message: cli.shellWarning,
        fingerprintWarning: this.host.fingerprintWarning
          ? 'This CLI has a different protocol revision. If a feature fails, check the compatibility guide.'
          : undefined,
      })
      void this.readLimits()
    } catch (error) {
      if (handshake) await handshake.close()
      this.host = undefined
      this.setStatus({
        state: /not found|executable/.test(messageOf(error)) ? 'missing' : 'error',
        message: messageOf(error),
      })
    }
    return this.status
  }

  private setStatus(status: ConnectionStatus) {
    this.status = status
    this.emit({ type: 'connection', status })
  }

  /** `usage/read` (msp.d.ts:3030): omitted when Muse has observed nothing. A CLI without the method keeps null. */
  private async readLimits() {
    try {
      const result = z
        .object({ usage: z.unknown().optional() })
        .parse(await this.connection.request('usage/read', {}))
      if (result.usage === undefined) return
      this.limits = toLimits(result.usage)
      this.emit({ type: 'usage-changed', limits: this.limits })
    } catch {
      // An older CLI, or a read that failed: the footer stays hidden.
    }
  }

  private get connection() {
    if (!this.host || this.status.state !== 'ready')
      throw new Error('Muse is not connected. Reconnect in Settings.')
    return this.host.connection
  }

  async list(cursor?: string) {
    return z.object({ sessions: z.array(sessionSchema), nextCursor: z.string().nullable() }).parse(
      await this.connection.request('session/list', {
        limit: 100,
        ...(cursor ? { cursor } : {}),
      }),
    )
  }

  async models(sessionId?: string) {
    const result = await this.connection.request('model/list', sessionId ? { sessionId } : {})
    return z.object({ models: z.array(modelSchema) }).parse(result).models
  }

  /** Muse Code's config folder (settings.json, auth.json, trust.json). */
  configDir() {
    return museConfigDir(this.environment)
  }

  /**
   * Starts a session. With `worktree`, Muse creates a worktree of the project
   * (the parent project when `project` is itself a Muse worktree). Muse's
   * worktree methods need the repository in its trust.json, so callers must
   * pass only projects Desktop already trusts.
   */
  async create(project: string, modelId?: string, options: { worktree?: boolean } = {}) {
    if (options.worktree && !this.experimental)
      throw new Error('This Muse Code version does not offer worktree sessions.')
    const workspaceRoot = options.worktree ? projectRoot(project) : project
    if (options.worktree) await recordMuseTrust(this.configDir(), workspaceRoot)
    const result = sessionResultSchema.parse(
      await this.connection.command(
        'session/start',
        {
          workspaceRoot,
          ...(modelId ? { modelId } : {}),
          ...(options.worktree ? { worktree: { mode: 'create' } } : {}),
        },
        { maxAttempts: 1 },
      ),
    )
    const live = await this.hydrate(result, true)
    this.emit({ type: 'sessions-changed' })
    return this.view(live)
  }

  async open(sessionId: string): Promise<SessionView> {
    const existing = this.sessions.get(sessionId)
    if (existing?.loaded) return this.view(existing)
    if (existing) await this.unsubscribe(sessionId)
    const result = sessionResultSchema.parse(
      await this.connection.request('session/read', { sessionId, excludeItems: false }),
    )
    const live = await this.hydrate(result, false)
    try {
      await this.connection.request('view/subscribe', { sessionId, after: result.viewCursor })
    } catch (error) {
      // CLI 1.4.7 can read durable history without loading, but requires a loaded
      // session for live subscriptions. Do not claim another process's session just to view it.
      if (!(error instanceof MspError) || error.kind !== 'sessionNotLoaded') throw error
    }
    return this.view(live)
  }

  private async unsubscribe(sessionId: string) {
    try {
      await this.connection.request('view/unsubscribe', { sessionId })
    } catch (error) {
      if (!(error instanceof MspError) || error.kind !== 'sessionNotLoaded') throw error
    }
  }

  async resume(sessionId: string) {
    if (this.sessions.get(sessionId)?.loaded) return
    const result = sessionResultSchema.parse(
      await this.connection.command(
        'session/resume',
        {
          sessionId,
          history: 'inline',
        },
        { maxAttempts: 1 },
      ),
    )
    await this.hydrate(result, true)
    await this.refreshPending(sessionId)
    this.schedule(sessionId)
  }

  private seed(result: z.infer<typeof sessionResultSchema>, loaded: boolean) {
    const items = result.history?.items ?? result.history?.snapshot?.state.items ?? []
    const store = new ItemStore<TranscriptItem>()
    store.seed(items)
    const live: LiveSession = {
      store,
      loaded,
      view: {
        session: result.session,
        items,
        approvals: [],
        questions: [],
        error: result.lastTurn?.error?.message,
        historyNotice:
          result.history?.mode === 'none'
            ? 'Muse did not include earlier messages in this response.'
            : undefined,
      },
    }
    this.sessions.set(result.session.sessionId, live)
    return live
  }

  private async hydrate(result: z.infer<typeof sessionResultSchema>, loaded: boolean) {
    const live = this.seed(result, loaded)
    if (result.history?.mode !== 'none') return live
    const cursors = new Set<string>()
    let cursor: string | undefined
    let reachedHead = false
    do {
      const page = z
        .object({
          events: z.array(
            z.object({
              method: z.string(),
              params: z.object({ sessionId: z.string(), viewCursor: z.string() }).passthrough(),
            }),
          ),
          nextCursor: z.string().nullable(),
        })
        .parse(
          await this.connection.request('view/page', {
            sessionId: result.session.sessionId,
            direction: 'forward',
            limit: 500,
            ...(cursor ? { cursor } : {}),
          }),
        )
      for (const event of page.events) {
        if (event.params.sessionId !== result.session.sessionId)
          throw new Error('Muse returned history for a different conversation.')
        if (['item/started', 'item/updated', 'item/completed'].includes(event.method))
          live.store.apply(itemSchema.parse(event.params.item))
        if (event.method === 'item/delta') {
          const delta = z
            .object({ itemId: z.string(), delta: z.string(), field: z.string().optional() })
            .parse(event.params)
          live.store.applyDelta(delta.itemId, delta.delta, delta.field)
        }
        if (event.params.viewCursor === result.viewCursor) {
          reachedHead = true
          break
        }
      }
      cursor = page.nextCursor || undefined
      if (cursor && cursors.has(cursor))
        throw new Error('Muse returned a repeated transcript cursor. Reconnect and try again.')
      if (cursor) cursors.add(cursor)
    } while (cursor && !reachedHead)
    live.view.historyNotice = undefined
    return live
  }

  private async refreshPending(sessionId: string) {
    const pending = pendingSchema.parse(
      await this.connection.request('approval/listPending', { sessionId }),
    )
    const live = this.requireSession(sessionId)
    live.view.approvals = pending.approvals
    live.view.questions = pending.userInputs
  }

  async send(
    sessionId: string,
    input: Record<string, unknown>[],
    effort: string,
    mode: string,
    displayText: string,
  ) {
    await this.resume(sessionId)
    const live = this.requireSession(sessionId)
    live.view.error = undefined
    await this.connection.command(
      'turn/start',
      { sessionId, input, displayText, reasoningEffort: effort, ifBusy: mode },
      { maxAttempts: 1 },
    )
  }

  async cancel(sessionId: string) {
    await this.connection.command('turn/cancel', { sessionId }, { maxAttempts: 1 })
  }

  async compact(sessionId: string) {
    await this.resume(sessionId)
    return z
      .object({ status: z.string() })
      .parse(await this.connection.command('session/compact', { sessionId }, { maxAttempts: 1 }))
  }

  async rename(sessionId: string, name: string) {
    await this.resume(sessionId)
    const result = z
      .object({ name: z.string().optional() })
      .parse(
        await this.connection.command('session/rename', { sessionId, name }, { maxAttempts: 1 }),
      )
    const live = this.sessions.get(sessionId)
    if (live && result.name) {
      live.view.session.name = result.name
      this.schedule(sessionId)
    }
    this.emit({ type: 'sessions-changed' })
  }

  async setModel(sessionId: string, modelId: string) {
    await this.resume(sessionId)
    await this.connection.command(
      'session/setModel',
      { sessionId, model: { modelId } },
      { maxAttempts: 1 },
    )
    this.requireSession(sessionId).view.session.modelId = modelId
    this.schedule(sessionId)
  }

  /**
   * Selects an approval mode for the session. Muse applies it to its next action; an action
   * already awaiting approval is not re-decided (msp.d.ts, `session/setApprovalMode`).
   */
  async setApprovalMode(sessionId: string, mode: ApprovalMode) {
    await this.resume(sessionId)
    const result = z
      .object({
        applyOutcome: z.string(),
        effectiveMode: z.object({ mode: z.string() }).passthrough(),
      })
      .parse(
        await this.connection.command(
          'session/setApprovalMode',
          { sessionId, mode },
          { maxAttempts: 1 },
        ),
      )
    this.requireSession(sessionId).view.session.approvalMode = result.effectiveMode
    this.schedule(sessionId)
    return result.effectiveMode.mode
  }

  /**
   * A side session seeded from `sessionId`: a place for a question that must not join the main
   * conversation. Muse returns the new session's resume envelope (msp.d.ts, `session/sideChat`),
   * so it is hydrated loaded, like a created session. The caller shows it; it never joins the
   * sidebar (its kind is `sideChat`).
   */
  async sideChat(sessionId: string): Promise<SessionView> {
    await this.resume(sessionId)
    const result = sessionResultSchema.parse(
      await this.connection.command('session/sideChat', { sessionId }, { maxAttempts: 1 }),
    )
    const live = await this.hydrate(result, true)
    return this.view(live)
  }

  /**
   * Runs a shell command in the session's folder, the TUI's `!` escape (msp.d.ts,
   * `session/userShell`). The result arrives as a `userShell` item through the item events.
   */
  async runShell(sessionId: string, commandText: string) {
    await this.resume(sessionId)
    await this.connection.command(
      'session/userShell',
      { sessionId, commandText },
      { maxAttempts: 1 },
    )
  }

  async approve(sessionId: string, approvalId: string, choiceId: string) {
    await this.resume(sessionId)
    const approval = this.requireSession(sessionId).view.approvals.find(
      (entry) => entry.approvalId === approvalId,
    )
    if (!approval || !approval.availableChoices.some((choice) => choice.choiceId === choiceId)) {
      throw new Error('This approval changed. Review the current choices and try again.')
    }
    await this.connection.command(
      'approval/decide',
      {
        sessionId,
        approvalId,
        choiceId,
        requirementId: approval.currentRequirementId,
      },
      { maxAttempts: 1 },
    )
  }

  async answer(sessionId: string, userInputId: string, answers: QuestionAnswer[]) {
    await this.resume(sessionId)
    await this.connection.command(
      'userInput/answer',
      { sessionId, userInputId, answers },
      { maxAttempts: 1 },
    )
  }

  async cancelQuestion(sessionId: string, userInputId: string) {
    await this.resume(sessionId)
    await this.connection.command(
      'userInput/cancel',
      { sessionId, userInputId },
      { maxAttempts: 1 },
    )
  }

  async readOutput(sessionId: string, itemId: string) {
    const item = this.requireSession(sessionId).store.get(itemId)
    if (!item?.outputRef) throw new Error('There is no stored output for this item.')
    const result = z.object({ content: z.string(), encoding: z.string(), eof: z.boolean() }).parse(
      await this.connection.request('item/readOutput', {
        sessionId,
        itemId,
        outputRef: item.outputRef.id,
        lengthBytes: 1024 * 1024,
      }),
    )
    if (result.encoding !== 'utf8') return 'Binary output cannot be displayed as text.'
    return (
      result.content +
      (result.eof
        ? ''
        : '\n\n[Preview limited to 1 MB. Full output remains in Muse’s session log.]')
    )
  }

  /** Every worktree of the repository at `project`, via Muse's `worktree/list`. */
  async listWorktrees(project: string) {
    if (!this.experimental) return []
    try {
      const result = await this.connection.request('worktree/list', { workspaceRoot: project })
      return z.object({ worktrees: z.array(worktreeEntrySchema) }).parse(result).worktrees
    } catch (error) {
      // Untrusted or non-Git folders have no Muse worktrees to show.
      if (error instanceof MspError && error.kind === 'workspaceNotTrusted') return []
      if (/not a git repository|not trusted|no repository/i.test(messageOf(error))) return []
      throw error
    }
  }

  getSession(sessionId: string): MuseSession {
    return this.requireSession(sessionId).view.session
  }
  getView(sessionId: string): SessionView {
    return this.view(this.requireSession(sessionId))
  }
  hasActiveTurns() {
    return (
      this.status.state === 'ready' &&
      [...this.sessions.values()].some((live) => live.view.session.status === 'running')
    )
  }

  private requireSession(sessionId: string) {
    const live = this.sessions.get(sessionId)
    if (!live) throw new Error('Open this conversation before performing an action.')
    return live
  }

  private view(live: LiveSession): SessionView {
    const items = live.store.list().map((item) => {
      if (item.status !== 'inProgress') return item
      const text = live.store.accumulated(item.itemId, 'text')
      const output = live.store.accumulated(item.itemId, 'output')
      const summary = [...(item.summary ?? [])]
      for (const field of live.store.accumulatedFields(item.itemId)) {
        if (/^summary\.\d+$/.test(field))
          summary[Number(field.split('.')[1])] =
            (item.summary?.[Number(field.split('.')[1])] ?? '') +
            (live.store.accumulated(item.itemId, field) ?? '')
      }
      return {
        ...item,
        ...(text !== undefined ? { text: (item.text ?? '') + text } : {}),
        ...(output !== undefined ? { visibleOutput: (item.visibleOutput ?? '') + output } : {}),
        summary,
      }
    })
    return { ...live.view, items }
  }

  private schedule(sessionId: string) {
    if (this.timers.has(sessionId)) return
    this.timers.set(
      sessionId,
      setTimeout(() => {
        this.timers.delete(sessionId)
        const live = this.sessions.get(sessionId)
        if (live) this.emit({ type: 'session', view: this.view(live) })
      }, 32),
    )
  }

  private receive(method: string, params: Record<string, unknown>) {
    if (method === 'session/listChanged' || method === 'session/started') {
      this.emit({ type: 'sessions-changed' })
      return
    }
    if (method === 'usage/changed') {
      this.limits = toLimits(params)
      this.emit({ type: 'usage-changed', limits: this.limits })
      return
    }
    const sessionId = typeof params.sessionId === 'string' ? params.sessionId : undefined
    if (!sessionId) return
    const live = this.sessions.get(sessionId)
    if (!live) return
    if (['item/started', 'item/updated', 'item/completed'].includes(method)) {
      const item = itemSchema.parse(params.item)
      live.store.apply(item)
      if (item.kind === 'userMessage' && !live.view.session.firstUserPrompt)
        live.view.session.firstUserPrompt = item.displayText || item.text
    } else if (method === 'item/delta') {
      const delta = z
        .object({ itemId: z.string(), delta: z.string(), field: z.string().optional() })
        .parse(params)
      live.store.applyDelta(delta.itemId, delta.delta, delta.field)
    } else if (method === 'turn/started') {
      live.view.session.activeTurnId = z.string().parse(params.turnId)
      live.view.session.status = 'running'
    } else if (method === 'turn/completed') {
      live.view.session.activeTurnId = null
      live.view.session.status = 'idle'
      live.view.session.updatedAt = new Date().toISOString()
      const error = z
        .object({
          message: z.string(),
          quota: z.object({ limitKind: z.string(), resetsAtMs: z.number() }).optional(),
        })
        .optional()
        .parse(params.error)
      live.view.error = error?.message
      live.view.quota = error?.quota
        ? { kind: error.quota.limitKind, resetsAt: error.quota.resetsAtMs }
        : undefined
      this.emit({ type: 'sessions-changed' })
    } else if (method === 'session/statusChanged') {
      live.view.session.status = z.string().parse(params.status)
    } else if (method === 'session/nameChanged') {
      live.view.session.name = z.string().parse(params.name)
      this.emit({ type: 'sessions-changed' })
    } else if (method === 'approval/requested') {
      const approval = approvalSchema.parse(params)
      live.view.approvals = [
        ...live.view.approvals.filter((entry) => entry.approvalId !== approval.approvalId),
        approval,
      ]
    } else if (method === 'approval/updated') {
      live.view.approvals = live.view.approvals.map((approval) =>
        approval.approvalId === params.approvalId
          ? approvalSchema.parse({ ...approval, ...params })
          : approval,
      )
    } else if (method === 'approval/resolved') {
      live.view.approvals = live.view.approvals.filter(
        (entry) => entry.approvalId !== params.approvalId,
      )
    } else if (method === 'userInput/requested') {
      const question = questionSchema.parse(params)
      live.view.questions = [
        ...live.view.questions.filter((entry) => entry.userInputId !== question.userInputId),
        question,
      ]
    } else if (method === 'userInput/settled') {
      live.view.questions = live.view.questions.filter(
        (entry) => entry.userInputId !== params.userInputId,
      )
    } else if (method === 'session/tokenUsage') {
      const usage = z
        .object({
          promptTokens: z.number(),
          outputTokens: z.number(),
          totalTokens: z.number(),
          cost: z.object({ usd: z.number(), partial: z.boolean() }).optional(),
        })
        .parse(params.cumulative)
      live.view.usage = {
        input: usage.promptTokens,
        output: usage.outputTokens,
        total: usage.totalTokens,
      }
      live.view.cost = usage.cost
    } else if (method === 'session/contextUsage') {
      const usage = z
        .object({
          usedTokens: z.number(),
          windowTokens: z.number().optional(),
          pressure: z.string(),
        })
        .parse(params)
      live.view.context = {
        used: usage.usedTokens,
        window: usage.windowTokens,
        pressure: usage.pressure,
      }
    } else if (method === 'session/todoListChanged') {
      live.view.todos = z.array(todoItemSchema).parse(params.items)
    } else if (method === 'session/approvalModeChanged') {
      live.view.session.approvalMode = {
        ...(live.view.session.approvalMode ?? {}),
        mode: z.string().parse(params.mode),
      }
    } else if (method === 'view/gap') {
      void this.recover(sessionId).catch((error: unknown) => {
        live.view.error = `Could not recover missed updates: ${messageOf(error)}`
        this.schedule(sessionId)
      })
    }
    this.schedule(sessionId)
  }

  private async recover(sessionId: string) {
    if (this.refreshing.has(sessionId)) return
    this.refreshing.add(sessionId)
    try {
      await this.connection.request('view/unsubscribe', { sessionId })
      const result = sessionResultSchema.parse(
        await this.connection.request('session/read', { sessionId, excludeItems: false }),
      )
      const loaded = this.requireSession(sessionId).loaded
      await this.hydrate(result, loaded)
      if (loaded) await this.refreshPending(sessionId)
      await this.connection.request('view/subscribe', { sessionId, after: result.viewCursor })
      this.schedule(sessionId)
    } finally {
      this.refreshing.delete(sessionId)
    }
  }

  async close() {
    this.closing = true
    for (const timer of this.timers.values()) clearTimeout(timer)
    this.timers.clear()
    this.sessions.clear()
    if (this.host) await this.host.close()
    this.host = undefined
  }
}

export function messageOf(error: unknown): string {
  if (error instanceof z.ZodError) {
    const field = error.issues[0]?.path.join('.')
    return field
      ? `Muse could not read “${field}”. Restart the app to use the latest version, then try again.`
      : 'Muse could not read this request. Restart the app and try again.'
  }
  return error instanceof Error ? error.message : String(error)
}
