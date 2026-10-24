import { createServer, type IncomingMessage, type Server } from 'node:http'
import { randomUUID, timingSafeEqual } from 'node:crypto'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import { z } from 'zod'
import { effortSchema } from '../shared/protocol'
import { projectRoot } from '../shared/worktree'
import { toAnswer, type AgentApi, type Job } from './agent-api'

// A localhost MCP server (streamable HTTP, bearer token) whose tools are thin
// wrappers over AgentApi, so an MCP client can drive Muse Code through Desktop.

export type McpBridgeOptions = {
  port: number
  host?: string
  token: string
  /** Projects Desktop knows and trusts. */
  projects: () => string[]
}

type BridgeApi = Pick<
  AgentApi,
  'ask' | 'get' | 'approve' | 'answer' | 'cancel' | 'listJobs' | 'listSessions' | 'listModels'
>

const settled = (job: Job) => !['running'].includes(job.status)
const text = (value: unknown) => ({
  content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }],
})
const failure = (error: unknown) => ({
  content: [
    { type: 'text' as const, text: error instanceof Error ? error.message : String(error) },
  ],
  isError: true,
})
const waitSeconds = z
  .number()
  .int()
  .min(0)
  .max(120)
  .default(0)
  .describe('Wait up to this many seconds for the job to finish or need a decision.')

function sameToken(header: string | undefined, token: string) {
  const expected = Buffer.from(`Bearer ${token}`)
  const given = Buffer.from(header ?? '')
  return given.length === expected.length && timingSafeEqual(given, expected)
}

export class McpBridge {
  private http?: Server
  private transports = new Map<string, StreamableHTTPServerTransport>()

  constructor(
    private api: BridgeApi,
    private options: McpBridgeOptions,
  ) {}

  private async waitFor(jobId: string, seconds: number) {
    const deadline = Date.now() + seconds * 1000
    let job = this.api.get(jobId)
    while (job && !settled(job) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 250))
      job = this.api.get(jobId)
    }
    return job
  }

  private view(job: Job, transcript: boolean) {
    const { transcript: full, ...rest } = job
    return transcript ? job : { ...rest, transcriptLength: full.length }
  }

  private buildServer() {
    const server = new McpServer({ name: 'muse-desktop-bridge', version: '0.1.0' })
    const run =
      <Args>(action: (args: Args) => Promise<unknown> | unknown) =>
      async (args: Args) => {
        try {
          return text(await action(args))
        } catch (error) {
          return failure(error)
        }
      }
    server.registerTool(
      'list_projects',
      {
        description: 'Projects Muse Desktop accepts work for (opened and trusted there).',
        annotations: { readOnlyHint: true },
      },
      run(() => this.options.projects()),
    )
    server.registerTool(
      'list_sessions',
      {
        description: 'Recent Muse Code conversations in those projects, newest first.',
        inputSchema: { cursor: z.string().optional() },
        annotations: { readOnlyHint: true },
      },
      run(async ({ cursor }: { cursor?: string }) => {
        const allowed = new Set(this.options.projects())
        const page = await this.api.listSessions(cursor)
        return {
          sessions: page.sessions.filter(
            (session) => session.workspaceRoot && allowed.has(projectRoot(session.workspaceRoot)),
          ),
          nextCursor: page.nextCursor,
        }
      }),
    )
    server.registerTool(
      'list_models',
      {
        description: 'Models the installed Muse Code offers.',
        annotations: { readOnlyHint: true },
      },
      run(() => this.api.listModels()),
    )
    server.registerTool(
      'ask_muse',
      {
        description:
          'Send a prompt to Muse Code as a new conversation in a project, or as the next turn of an existing session. Returns a job; follow it with get_job.',
        inputSchema: {
          project: z.string().optional().describe('Absolute project path from list_projects.'),
          session: z.string().optional().describe('Existing session id to continue instead.'),
          prompt: z.string().min(1).max(200000),
          effort: effortSchema.default('medium'),
          mode: z.enum(['queue', 'steer']).default('queue'),
          model: z.string().optional(),
          worktree: z
            .boolean()
            .default(false)
            .describe('Run in a new Git worktree that Muse creates.'),
          wait_seconds: waitSeconds,
        },
      },
      run(
        async (args: {
          project?: string
          session?: string
          prompt: string
          effort: z.infer<typeof effortSchema>
          mode: 'queue' | 'steer'
          model?: string
          worktree: boolean
          wait_seconds: number
        }) => {
          const job = await this.api.ask({
            prompt: args.prompt,
            effort: args.effort,
            mode: args.mode,
            ...(args.project ? { project: args.project } : {}),
            ...(args.session ? { sessionId: args.session } : {}),
            ...(args.model ? { modelId: args.model } : {}),
            ...(args.worktree ? { worktree: true } : {}),
          })
          return this.view((await this.waitFor(job.id, args.wait_seconds)) ?? job, false)
        },
      ),
    )
    server.registerTool(
      'get_job',
      {
        description:
          "A job's status, Muse's reply, and any approvals or questions it is waiting on.",
        inputSchema: {
          job: z.string(),
          wait_seconds: waitSeconds,
          include_transcript: z.boolean().default(false),
        },
        annotations: { readOnlyHint: true },
      },
      run(async (args: { job: string; wait_seconds: number; include_transcript: boolean }) => {
        const job = await this.waitFor(args.job, args.wait_seconds)
        if (!job) throw new Error('Unknown job.')
        return this.view(job, args.include_transcript)
      }),
    )
    server.registerTool(
      'list_jobs',
      {
        description: 'Bridge jobs since Muse Desktop started, newest first.',
        annotations: { readOnlyHint: true },
      },
      run(() => this.api.listJobs().map((job) => this.view(job, false))),
    )
    server.registerTool(
      'approve',
      {
        description: 'Decide an approval a job is waiting on, using a choiceId from get_job.',
        inputSchema: { job: z.string(), approvalId: z.string(), choiceId: z.string() },
      },
      run(async (args: { job: string; approvalId: string; choiceId: string }) => {
        await this.api.approve(args.job, args.approvalId, args.choiceId)
        return 'ok'
      }),
    )
    server.registerTool(
      'answer',
      {
        description:
          'Answer a question a job is waiting on. Use an option label, several labels separated by commas for multiple choice, or short free text.',
        inputSchema: {
          job: z.string(),
          userInputId: z.string(),
          questionId: z.string(),
          answer: z.string().min(1).max(500),
        },
      },
      run(
        async (args: { job: string; userInputId: string; questionId: string; answer: string }) => {
          await this.api.answer(args.job, args.userInputId, [
            toAnswer(this.api.get(args.job), args),
          ])
          return 'ok'
        },
      ),
    )
    server.registerTool(
      'cancel',
      {
        description: "Stop a job's turn.",
        inputSchema: { job: z.string() },
        annotations: { destructiveHint: true },
      },
      run(async (args: { job: string }) => {
        await this.api.cancel(args.job)
        return 'ok'
      }),
    )
    return server
  }

  private async route(req: IncomingMessage, res: import('node:http').ServerResponse) {
    const path = (req.url ?? '').split('?')[0]
    if (path !== '/mcp') return void res.writeHead(404).end()
    if (!sameToken(req.headers.authorization, this.options.token))
      return void res.writeHead(401, { 'WWW-Authenticate': 'Bearer' }).end()
    const sessionId = req.headers['mcp-session-id']
    let transport = typeof sessionId === 'string' ? this.transports.get(sessionId) : undefined
    if (!transport) {
      if (typeof sessionId === 'string') return void res.writeHead(404).end()
      if (req.method !== 'POST') return void res.writeHead(400).end()
      const created = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: (id) => {
          this.transports.set(id, created)
        },
        onsessionclosed: (id) => {
          this.transports.delete(id)
        },
      })
      created.onclose = () => {
        if (created.sessionId) this.transports.delete(created.sessionId)
      }
      await this.buildServer().connect(created)
      transport = created
    }
    await transport.handleRequest(req, res)
  }

  async start(): Promise<{ port: number }> {
    if (!this.options.token) throw new Error('Make a bridge token first.')
    this.http = createServer((req, res) => {
      this.route(req, res).catch(() => {
        if (!res.headersSent) res.writeHead(500)
        res.end()
      })
    })
    await new Promise<void>((resolve, reject) => {
      this.http!.once('error', reject)
      this.http!.listen(this.options.port, this.options.host ?? '127.0.0.1', () => {
        this.http!.off('error', reject)
        resolve()
      })
    })
    const address = this.http.address()
    return { port: typeof address === 'object' && address ? address.port : this.options.port }
  }

  async stop() {
    for (const transport of this.transports.values()) await transport.close().catch(() => {})
    this.transports.clear()
    const http = this.http
    this.http = undefined
    if (!http) return
    http.closeAllConnections()
    await new Promise<void>((resolve) => http.close(() => resolve()))
  }
}
