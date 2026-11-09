import { afterEach, describe, expect, it, vi } from 'vitest'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { McpBridge } from '../../src/main/bridge-mcp'
import type { AskInput, Job } from '../../src/main/agent-api'

let bridge: McpBridge | undefined
let client: Client | undefined
afterEach(async () => {
  await client?.close()
  await bridge?.stop()
  client = undefined
  bridge = undefined
})

const job = (overrides: Partial<Job> = {}): Job => ({
  id: 'j1',
  sessionId: 's1',
  project: '/p',
  prompt: 'hi',
  status: 'running',
  createdAt: '',
  updatedAt: '',
  reply: '',
  transcript: 'long transcript',
  approvals: [],
  questions: [],
  ...overrides,
})

function fakeApi() {
  const state = { job: job() }
  return {
    state,
    ask: vi.fn(async (_input: AskInput) => state.job),
    get: vi.fn((id: string) => (id === state.job.id ? state.job : undefined)),
    listJobs: vi.fn(() => [state.job]),
    approve: vi.fn(async () => {}),
    answer: vi.fn(async () => {}),
    cancel: vi.fn(async () => {}),
    listModels: vi.fn(async () => [{ modelId: 'm1' }]),
    listSessions: vi.fn(async () => ({
      sessions: [
        { sessionId: 's1', workspaceRoot: '/p' },
        { sessionId: 's2', workspaceRoot: '/p/.muse/worktrees/20261020-ab12' },
        { sessionId: 's3', workspaceRoot: '/private' },
      ],
      nextCursor: null,
    })),
  }
}

async function connect(api: ReturnType<typeof fakeApi>) {
  bridge = new McpBridge(api as never, { port: 0, token: 'secret', projects: () => ['/p'] })
  const { port } = await bridge.start()
  client = new Client({ name: 'test', version: '0.0.0' })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`), {
      requestInit: { headers: { Authorization: 'Bearer secret' } },
    }),
  )
  return { port, client }
}
const parse = (result: Awaited<ReturnType<Client['callTool']>>) =>
  JSON.parse((result.content as { text: string }[])[0].text)

describe('McpBridge', () => {
  it('refuses to start without a token', async () => {
    const empty = new McpBridge(fakeApi() as never, { port: 0, token: '', projects: () => [] })
    await expect(empty.start()).rejects.toThrow('token')
  })
  it('rejects requests without the right bearer token, and other paths', async () => {
    bridge = new McpBridge(fakeApi() as never, { port: 0, token: 'secret', projects: () => [] })
    const { port } = await bridge.start()
    const post = (headers: Record<string, string>, path = '/mcp') =>
      fetch(`http://127.0.0.1:${port}${path}`, { method: 'POST', headers, body: '{}' })
    expect((await post({})).status).toBe(401)
    expect((await post({ Authorization: 'Bearer wrong!' })).status).toBe(401)
    expect((await post({ Authorization: 'Bearer secret' }, '/other')).status).toBe(404)
  })
  it('lists tools, asks Muse and waits for the job', async () => {
    const api = fakeApi()
    const { client } = await connect(api)
    const tools = (await client.listTools()).tools.map((tool) => tool.name)
    expect(tools).toEqual(
      expect.arrayContaining([
        'list_projects',
        'list_sessions',
        'list_models',
        'ask_muse',
        'get_job',
        'list_jobs',
        'approve',
        'answer',
        'cancel',
      ]),
    )
    setTimeout(() => (api.state.job = job({ status: 'done', reply: 'Hello back' })), 300)
    const result = parse(
      await client.callTool({
        name: 'ask_muse',
        arguments: { project: '/p', prompt: 'hi', worktree: true, wait_seconds: 5 },
      }),
    )
    expect(api.ask).toHaveBeenCalledWith({
      project: '/p',
      prompt: 'hi',
      effort: 'medium',
      mode: 'queue',
      worktree: true,
    })
    expect(result).toMatchObject({ id: 'j1', status: 'done', reply: 'Hello back' })
    expect(result).not.toHaveProperty('transcript')
    const full = parse(
      await client.callTool({
        name: 'get_job',
        arguments: { job: 'j1', include_transcript: true },
      }),
    )
    expect(full.transcript).toBe('long transcript')
  })
  it('lists only sessions in trusted projects, including their worktrees', async () => {
    const { client } = await connect(fakeApi())
    const result = parse(await client.callTool({ name: 'list_sessions', arguments: {} }))
    expect(result.sessions.map((session: { sessionId: string }) => session.sessionId)).toEqual([
      's1',
      's2',
    ])
    expect(parse(await client.callTool({ name: 'list_projects', arguments: {} }))).toEqual(['/p'])
  })
  it('forwards approve, answer and cancel, and reports errors as tool errors', async () => {
    const api = fakeApi()
    api.state.job = job({
      status: 'waiting-input',
      questions: [
        {
          userInputId: 'q1',
          questions: [{ id: 'pick', header: '', question: '', options: ['A'], mode: 'single' }],
        },
      ],
    })
    const { client } = await connect(api)
    await client.callTool({
      name: 'approve',
      arguments: { job: 'j1', approvalId: 'a1', choiceId: 'c1' },
    })
    expect(api.approve).toHaveBeenCalledWith('j1', 'a1', 'c1')
    await client.callTool({
      name: 'answer',
      arguments: { job: 'j1', userInputId: 'q1', questionId: 'pick', answer: 'A' },
    })
    expect(api.answer).toHaveBeenCalledWith('j1', 'q1', [
      { questionId: 'pick', selectedLabel: 'A' },
    ])
    await client.callTool({ name: 'cancel', arguments: { job: 'j1' } })
    expect(api.cancel).toHaveBeenCalledWith('j1')
    api.ask.mockRejectedValueOnce(new Error('That project is not trusted in Muse Desktop.'))
    const refused = await client.callTool({
      name: 'ask_muse',
      arguments: { project: '/x', prompt: 'hi' },
    })
    expect(refused.isError).toBe(true)
    expect(JSON.stringify(refused.content)).toContain('not trusted')
  })
})
