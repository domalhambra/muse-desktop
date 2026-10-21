import { randomUUID } from 'node:crypto'
import { subscribe } from './event-bus'
import type {
  Approval,
  QuestionAnswer,
  ReasoningEffort,
  SessionView,
  TranscriptItem,
} from '../shared/protocol'

// The shared "ask Muse Code" core behind both bridges. A job is one prompt sent
// as one turn to one Muse session, followed through the same session events the
// window receives. Everything a job does is a Muse built-in: session/start
// (optionally in a Muse worktree), turn/start, approval/decide, userInput/answer
// and turn/cancel, all through MuseHost.

// Item kinds from @muse-code/sdk's ItemKind.
export const KIND = {
  user: 'userMessage',
  assistant: 'agentMessage',
  reasoning: 'reasoning',
  tool: 'toolCall',
  shell: 'userShell',
  subagent: 'subagent',
} as const

export type JobStatus =
  'running' | 'waiting-approval' | 'waiting-input' | 'done' | 'error' | 'cancelled'

export type JobApproval = {
  approvalId: string
  summary: string
  choices: { choiceId: string; label: string }[]
}
export type JobQuestion = {
  userInputId: string
  questions: {
    id: string
    header: string
    question: string
    options: string[]
    mode: 'single' | 'multiple'
  }[]
}
export type Job = {
  id: string
  sessionId: string
  project: string
  prompt: string
  status: JobStatus
  createdAt: string
  updatedAt: string
  /** Muse's own messages for this job, without tool output. */
  reply: string
  /** Markdown of every item this job's turn produced. */
  transcript: string
  error?: string
  approvals: JobApproval[]
  questions: JobQuestion[]
}

export type AskInput = {
  project?: string
  sessionId?: string
  prompt: string
  effort: ReasoningEffort
  modelId?: string
  mode?: 'queue' | 'steer'
  worktree?: boolean
}

export interface AgentHost {
  create(project: string, modelId?: string, options?: { worktree?: boolean }): Promise<SessionView>
  open(sessionId: string): Promise<SessionView>
  send(
    sessionId: string,
    input: Record<string, unknown>[],
    effort: string,
    mode: string,
    displayText: string,
  ): Promise<void>
  approve(sessionId: string, approvalId: string, choiceId: string): Promise<void>
  answer(sessionId: string, userInputId: string, answers: QuestionAnswer[]): Promise<void>
  cancel(sessionId: string): Promise<void>
  models(sessionId?: string): Promise<unknown[]>
  list(cursor?: string): Promise<{ sessions: SessionView['session'][]; nextCursor: string | null }>
}

export interface AgentPolicy {
  /** Canonical path of a project Desktop knows and trusts; throws otherwise. */
  resolveProject(project: string): Promise<string>
}

const MAX_JOBS = 200

// An answer that names the question's options selects them; anything else is free text.
export function toAnswer(
  job: Job | undefined,
  decision: { userInputId: string; questionId: string; answer: string },
): QuestionAnswer {
  const question = job?.questions
    .find((input) => input.userInputId === decision.userInputId)
    ?.questions.find((entry) => entry.id === decision.questionId)
  const options = question?.options ?? []
  if (question?.mode === 'multiple') {
    const labels = decision.answer.split(',').map((label) => label.trim())
    if (labels.every((label) => options.includes(label)))
      return { questionId: decision.questionId, selectedLabels: labels }
  } else if (options.includes(decision.answer)) {
    return { questionId: decision.questionId, selectedLabel: decision.answer }
  }
  return { questionId: decision.questionId, freeText: decision.answer }
}

export function renderTranscript(items: TranscriptItem[]): string {
  const blocks: string[] = []
  for (const item of items) {
    if (item.retracted) continue
    switch (item.kind) {
      case KIND.user:
        blocks.push(`**You:** ${item.displayText ?? item.text ?? ''}`)
        break
      case KIND.assistant:
        if (item.text) blocks.push(item.text)
        break
      case KIND.reasoning:
        break
      case KIND.tool:
      case KIND.shell: {
        const head = item.commandText ? `\`${item.commandText}\`` : (item.tool ?? item.kind)
        blocks.push(`> ${head}${item.statusLine ? ` (${item.statusLine})` : ''}`)
        if (item.visibleOutput) blocks.push('```\n' + item.visibleOutput.slice(0, 4000) + '\n```')
        break
      }
      case KIND.subagent:
        blocks.push(
          `> Subagent: ${item.label ?? item.objective ?? ''}${item.finalSummary ? `\n\n${item.finalSummary}` : ''}`,
        )
        break
      default: {
        const text = item.text ?? item.fallbackText ?? item.summary?.join('\n')
        if (text) blocks.push(text)
      }
    }
  }
  return blocks.join('\n\n')
}

function summarize(approval: Approval) {
  const subject = approval.subject
  const target = subject.command ?? subject.path ?? subject.host ?? subject.target ?? ''
  return [approval.toolName, target].filter(Boolean).join(': ')
}

type Tracking = { baseline: Set<string>; sawRunning: boolean }

export class AgentApi {
  private jobs = new Map<string, Job>()
  private tracking = new Map<string, Tracking>()
  private bySession = new Map<string, string>()
  private unsubscribe: () => void

  constructor(
    private host: AgentHost,
    private policy: AgentPolicy,
  ) {
    this.unsubscribe = subscribe((event) => {
      if (event.type !== 'session') return
      const jobId = this.bySession.get(event.view.session.sessionId)
      if (jobId) this.update(jobId, event.view)
    })
  }

  dispose() {
    this.unsubscribe()
  }

  async ask(input: AskInput): Promise<Job> {
    let view: SessionView
    if (input.sessionId) {
      view = await this.host.open(input.sessionId)
      if (!view.session.workspaceRoot) throw new Error('That conversation has no project folder.')
      await this.policy.resolveProject(view.session.workspaceRoot)
    } else {
      if (!input.project) throw new Error('Give a project path or an existing session id.')
      const project = await this.policy.resolveProject(input.project)
      view = await this.host.create(project, input.modelId, { worktree: input.worktree })
    }
    const sessionId = view.session.sessionId
    const active = this.bySession.get(sessionId)
    if (active)
      throw new Error(`Job ${active} is still active in this session. Wait for it or cancel it.`)
    const now = new Date().toISOString()
    const job: Job = {
      id: randomUUID(),
      sessionId,
      project: view.session.workspaceRoot ?? '',
      prompt: input.prompt,
      status: 'running',
      createdAt: now,
      updatedAt: now,
      reply: '',
      transcript: '',
      approvals: [],
      questions: [],
    }
    this.jobs.set(job.id, job)
    this.tracking.set(job.id, {
      baseline: new Set(view.items.map((item) => item.itemId)),
      sawRunning: false,
    })
    this.bySession.set(sessionId, job.id)
    this.prune()
    try {
      await this.host.send(
        sessionId,
        [{ type: 'text', text: input.prompt }],
        input.effort,
        input.mode ?? 'queue',
        input.prompt,
      )
    } catch (error) {
      this.finish(job, 'error', error instanceof Error ? error.message : String(error))
    }
    return { ...job }
  }

  async approve(jobId: string, approvalId: string, choiceId: string) {
    const job = this.require(jobId)
    await this.host.approve(job.sessionId, approvalId, choiceId)
  }

  async answer(jobId: string, userInputId: string, answers: QuestionAnswer[]) {
    const job = this.require(jobId)
    await this.host.answer(job.sessionId, userInputId, answers)
  }

  async cancel(jobId: string) {
    const job = this.require(jobId)
    if (this.bySession.get(job.sessionId) !== job.id) return
    await this.host.cancel(job.sessionId)
    this.finish(job, 'cancelled')
  }

  get(jobId: string): Job | undefined {
    const job = this.jobs.get(jobId)
    return job && { ...job }
  }

  listJobs(): Job[] {
    return [...this.jobs.values()]
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map((job) => ({ ...job }))
  }

  listSessions(cursor?: string) {
    return this.host.list(cursor)
  }

  listModels() {
    return this.host.models()
  }

  get activeCount() {
    return this.bySession.size
  }

  private require(jobId: string) {
    const job = this.jobs.get(jobId)
    if (!job) throw new Error('Unknown job.')
    return job
  }

  private finish(job: Job, status: JobStatus, error?: string) {
    job.status = status
    if (error) job.error = error
    job.updatedAt = new Date().toISOString()
    if (this.bySession.get(job.sessionId) === job.id) this.bySession.delete(job.sessionId)
  }

  private prune() {
    if (this.jobs.size <= MAX_JOBS) return
    const finished = [...this.jobs.values()]
      .filter((job) => this.bySession.get(job.sessionId) !== job.id)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
    for (const job of finished.slice(0, this.jobs.size - MAX_JOBS)) {
      this.jobs.delete(job.id)
      this.tracking.delete(job.id)
    }
  }

  private update(jobId: string, view: SessionView) {
    const job = this.require(jobId)
    const tracking = this.tracking.get(jobId)!
    const items = view.items.filter((item) => !tracking.baseline.has(item.itemId))
    job.transcript = renderTranscript(items)
    job.reply = items
      .filter((item) => item.kind === KIND.assistant && !item.retracted && item.text)
      .map((item) => item.text)
      .join('\n\n')
    job.updatedAt = new Date().toISOString()
    job.approvals = view.approvals.map((approval) => ({
      approvalId: approval.approvalId,
      summary: summarize(approval),
      choices: approval.availableChoices.map((choice) => ({
        choiceId: choice.choiceId,
        label: choice.label,
      })),
    }))
    job.questions = view.questions.map((question) => ({
      userInputId: question.userInputId,
      questions: question.questions.map((entry) => ({
        id: entry.id,
        header: entry.header,
        question: entry.question,
        options: entry.options.map((option) => option.label),
        mode: entry.selection.mode,
      })),
    }))
    if (view.session.status === 'running') tracking.sawRunning = true
    if (view.error) this.finish(job, 'error', view.error)
    else if (job.approvals.length) job.status = 'waiting-approval'
    else if (job.questions.length) job.status = 'waiting-input'
    else if (view.session.status === 'running') job.status = 'running'
    // A view from before the turn started can still report idle; only a turn
    // that was seen running can finish.
    else if (tracking.sawRunning) this.finish(job, 'done')
  }
}
