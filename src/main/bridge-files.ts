import { watch, type FSWatcher } from 'chokidar'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'
import { z } from 'zod'
import { effortSchema, type QuestionAnswer } from '../shared/protocol'
import type { AgentApi, AskInput, Job } from './agent-api'

// A folder-based bridge: another agent writes a Markdown request into inbox/,
// Muse Desktop runs it as a Muse Code turn through AgentApi, and keeps
// outbox/<same name>.md current until the job ends. Decisions (approvals,
// answers, cancel) go into decisions/<job id>.md.

const flag = z
  .enum(['true', 'false', 'yes', 'no'])
  .transform((value) => value === 'true' || value === 'yes')
const requestSchema = z.object({
  project: z.string().min(1).optional(),
  session: z.string().min(1).optional(),
  effort: effortSchema.default('medium'),
  mode: z.enum(['queue', 'steer']).default('queue'),
  model: z.string().min(1).optional(),
  worktree: flag.optional(),
})
const decisionSchema = z.union([
  z.object({ approvalId: z.string().min(1), choiceId: z.string().min(1) }),
  z.object({
    userInputId: z.string().min(1),
    questionId: z.string().min(1),
    answer: z.string().min(1).max(500),
  }),
  z.object({ cancel: flag.refine((value) => value, 'Write cancel: true to cancel.') }),
])

export function parseFrontmatter(text: string): { fields: Record<string, string>; body: string } {
  const match = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)([\s\S]*)$/.exec(text)
  if (!match) return { fields: {}, body: text.trim() }
  const fields: Record<string, string> = {}
  for (const line of match[1].split(/\r?\n/)) {
    const index = line.indexOf(':')
    if (index <= 0 || line.trimStart().startsWith('#')) continue
    const value = line
      .slice(index + 1)
      .replace(/\s+#.*$/, '')
      .trim()
      .replace(/^(["'])(.*)\1$/, '$2')
    if (value) fields[line.slice(0, index).trim()] = value
  }
  return { fields, body: match[2].trim() }
}

export function parseRequest(text: string): AskInput {
  const { fields, body } = parseFrontmatter(text)
  const request = requestSchema.parse(fields)
  if (!request.project && !request.session)
    throw new Error('Add a project path (or a session id) to the frontmatter.')
  if (!body) throw new Error('The request has no prompt below the frontmatter.')
  return {
    prompt: body,
    effort: request.effort,
    mode: request.mode,
    ...(request.project ? { project: request.project } : {}),
    ...(request.session ? { sessionId: request.session } : {}),
    ...(request.model ? { modelId: request.model } : {}),
    ...(request.worktree ? { worktree: true } : {}),
  }
}

export function renderJob(job: Job): string {
  const sections = [
    '---',
    `job: ${job.id}`,
    `session: ${job.sessionId}`,
    `project: ${job.project}`,
    `status: ${job.status}`,
    `updated: ${job.updatedAt}`,
    '---',
    '',
    '# Reply',
    job.reply || '_(no reply yet)_',
  ]
  if (job.approvals.length) {
    sections.push('', '# Approvals pending')
    for (const approval of job.approvals)
      sections.push(
        `- ${approval.approvalId}: ${approval.summary}. Choices: ${approval.choices
          .map((choice) => `${choice.choiceId} (${choice.label})`)
          .join(', ')}`,
      )
    sections.push(
      '',
      `To decide, write decisions/${job.id}.md with approvalId and choiceId in its frontmatter.`,
    )
  }
  if (job.questions.length) {
    sections.push('', '# Questions from Muse')
    for (const input of job.questions)
      for (const question of input.questions)
        sections.push(
          `- ${input.userInputId} / ${question.id}: ${question.question}${
            question.options.length ? ` Options: ${question.options.join(', ')}` : ''
          }`,
        )
    sections.push(
      '',
      `To answer, write decisions/${job.id}.md with userInputId, questionId and answer in its frontmatter.`,
    )
  }
  if (job.error) sections.push('', '# Error', job.error)
  sections.push('', '# Prompt', job.prompt, '', '# Transcript', job.transcript || '_(empty)_', '')
  return sections.join('\n')
}

export const BRIDGE_README = `# Muse Desktop bridge

This folder lets another agent, such as Meta's Muse app on this Mac, ask Muse
Code to do work. Muse Desktop runs each request as a Muse Code conversation and
shows it in its window, including any approval Muse needs.

## Ask for work

Write a Markdown file into inbox/. Put settings in YAML frontmatter and the
prompt below it:

    ---
    project: /absolute/path/to/a/project/opened/in/Muse/Desktop
    effort: medium
    worktree: false
    ---
    Describe the task here.

| Field    | Required | Values |
| -------- | -------- | ------ |
| project  | yes, unless session is given | A project already opened and trusted in Muse Desktop |
| session  | no | An existing Muse session id, to continue that conversation |
| effort   | no | none, minimal, low, medium (default), high, xhigh, max, ultra |
| mode     | no | queue (default) or steer, for a session that is already working |
| model    | no | A Muse model id |
| worktree | no | true to run in a new Git worktree that Muse creates |

## Read the result

outbox/<same file name>.md is rewritten while the job runs. Its frontmatter has
status: running, waiting-approval, waiting-input, done, error or cancelled.
Read it until the status is done, error or cancelled. The Reply section holds
Muse's answer. The Transcript section holds every step.

## Decide

When the status is waiting-approval or waiting-input, the outbox file lists what
Muse is waiting for. Write decisions/<job id>.md with one of these frontmatters:

    ---
    approvalId: <id>
    choiceId: <choice>
    ---

    ---
    userInputId: <id>
    questionId: <id>
    answer: <option label or short text>
    ---

    ---
    cancel: true
    ---

The Muse Desktop window shows the same approvals and questions. Either place works.

## Limits

Only projects opened and trusted in Muse Desktop are accepted. A request that
fails is moved to inbox/rejected/ with a .error.txt file that explains why.
Handled requests move to inbox/processed/.
`

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

type BridgeApi = Pick<AgentApi, 'ask' | 'get' | 'approve' | 'answer' | 'cancel'>

export class FileBridge {
  private watcher?: FSWatcher
  private timers = new Map<string, ReturnType<typeof setInterval>>()
  private written = new Map<string, string>()
  readonly inbox: string
  readonly outbox: string
  readonly decisions: string

  constructor(
    readonly root: string,
    private api: BridgeApi,
    private pollMs = 1000,
  ) {
    this.inbox = join(root, 'inbox')
    this.outbox = join(root, 'outbox')
    this.decisions = join(root, 'decisions')
  }

  async start() {
    for (const dir of [
      this.root,
      this.inbox,
      join(this.inbox, 'rejected'),
      join(this.inbox, 'processed'),
      this.outbox,
      this.decisions,
      join(this.decisions, 'processed'),
    ])
      await mkdir(dir, { recursive: true, mode: 0o700 })
    await writeFile(join(this.root, 'README.md'), BRIDGE_README, { mode: 0o600 })
    this.watcher = watch([this.inbox, this.decisions], {
      depth: 0,
      ignoreInitial: false,
      awaitWriteFinish: { stabilityThreshold: 250, pollInterval: 50 },
    })
    // Handled files are moved away at once, so a file reappearing under the same
    // name is new work. chokidar reports a quick delete-and-recreate as a change.
    const arrive = (path: string) => {
      if (!path.endsWith('.md')) return
      const folder = dirname(path)
      if (folder === this.inbox) void this.handleRequest(path)
      else if (folder === this.decisions) void this.handleDecision(path)
    }
    this.watcher.on('add', arrive)
    this.watcher.on('change', arrive)
    await new Promise<void>((resolve) => this.watcher!.once('ready', () => resolve()))
  }

  async stop() {
    for (const timer of this.timers.values()) clearInterval(timer)
    this.timers.clear()
    await this.watcher?.close()
    this.watcher = undefined
  }

  private async handleRequest(path: string) {
    const name = basename(path, '.md')
    const processed = join(this.inbox, 'processed', `${name}.md`)
    let text: string
    try {
      text = await readFile(path, 'utf8')
      await rename(path, processed)
    } catch {
      return
    }
    try {
      const job = await this.api.ask(parseRequest(text))
      await this.writeOut(name, job)
      this.follow(name, job.id)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      await rename(processed, join(this.inbox, 'rejected', `${name}.md`)).catch(() => {})
      await writeFile(join(this.inbox, 'rejected', `${name}.error.txt`), `${message}\n`, {
        mode: 0o600,
      })
    }
  }

  private follow(name: string, jobId: string) {
    const timer = setInterval(() => {
      const job = this.api.get(jobId)
      if (!job) return this.unfollow(jobId)
      void this.writeOut(name, job).catch(() => {})
      if (['done', 'error', 'cancelled'].includes(job.status)) this.unfollow(jobId)
    }, this.pollMs)
    this.timers.set(jobId, timer)
  }

  private unfollow(jobId: string) {
    clearInterval(this.timers.get(jobId))
    this.timers.delete(jobId)
  }

  private async handleDecision(path: string) {
    const jobId = basename(path, '.md')
    let text: string
    try {
      // Claim the file before acting, so a decision written next under the
      // same name arrives as a new file instead of being swept away with this one.
      text = await readFile(path, 'utf8')
      await rename(path, join(this.decisions, 'processed', `${jobId}-${Date.now()}.md`))
    } catch {
      return
    }
    try {
      const decision = decisionSchema.parse(parseFrontmatter(text).fields)
      if ('approvalId' in decision)
        await this.api.approve(jobId, decision.approvalId, decision.choiceId)
      else if ('userInputId' in decision)
        await this.api.answer(jobId, decision.userInputId, [
          toAnswer(this.api.get(jobId), decision),
        ])
      else await this.api.cancel(jobId)
    } catch (error) {
      await writeFile(
        join(this.decisions, `${jobId}.error.txt`),
        `${error instanceof Error ? error.message : String(error)}\n`,
        { mode: 0o600 },
      )
    }
  }

  private async writeOut(name: string, job: Job) {
    const text = renderJob(job)
    if (this.written.get(name) === text) return
    this.written.set(name, text)
    const target = join(this.outbox, `${name}.md`)
    await writeFile(`${target}.tmp`, text, { mode: 0o600 })
    await rename(`${target}.tmp`, target)
  }
}
