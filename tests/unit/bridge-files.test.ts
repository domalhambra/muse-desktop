import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { FileBridge, parseFrontmatter, parseRequest, toAnswer } from '../../src/main/bridge-files'
import type { AskInput, Job } from '../../src/main/agent-api'

let dir: string
let bridge: FileBridge | undefined
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'muse-bridge-'))
})
afterEach(async () => {
  await bridge?.stop()
  bridge = undefined
  await rm(dir, { recursive: true, force: true })
})

const job = (overrides: Partial<Job> = {}): Job => ({
  id: 'j1',
  sessionId: 's1',
  project: '/p',
  prompt: 'Say hi',
  status: 'running',
  createdAt: '2026-10-20T00:00:00Z',
  updatedAt: '2026-10-20T00:00:00Z',
  reply: '',
  transcript: '',
  approvals: [],
  questions: [],
  ...overrides,
})

function fakeApi(current: { job: Job }) {
  return {
    asked: [] as AskInput[],
    ask: vi.fn(async function (this: unknown, input: AskInput) {
      api.asked.push(input)
      return current.job
    }),
    get: vi.fn(() => current.job),
    approve: vi.fn(async () => {}),
    answer: vi.fn(async () => {}),
    cancel: vi.fn(async () => {}),
  }
}
let api: ReturnType<typeof fakeApi>

describe('request parsing', () => {
  it('parses frontmatter, inline comments, quotes and the prompt body', () => {
    expect(
      parseRequest(
        '---\nproject: "/p q"\neffort: high   # thinking\nworktree: true\nmodel: m1\n---\nDo the thing\n',
      ),
    ).toEqual({
      project: '/p q',
      effort: 'high',
      mode: 'queue',
      modelId: 'm1',
      worktree: true,
      prompt: 'Do the thing',
    })
  })
  it('accepts a session without a project', () => {
    expect(parseRequest('---\nsession: s1\n---\nmore')).toMatchObject({ sessionId: 's1' })
  })
  it('rejects a missing project, an empty prompt and a bad effort', () => {
    expect(() => parseRequest('---\neffort: high\n---\nhi')).toThrow('project')
    expect(() => parseRequest('---\nproject: /p\n---\n')).toThrow('prompt')
    expect(() => parseRequest('---\nproject: /p\neffort: huge\n---\nhi')).toThrow()
  })
  it('treats text without frontmatter as body only', () => {
    expect(parseFrontmatter('just text')).toEqual({ fields: {}, body: 'just text' })
  })
  it('maps answers to option labels or free text', () => {
    const asking = job({
      questions: [
        {
          userInputId: 'q',
          questions: [
            { id: 'one', header: '', question: '', options: ['A', 'B'], mode: 'single' },
            { id: 'many', header: '', question: '', options: ['A', 'B'], mode: 'multiple' },
          ],
        },
      ],
    })
    const ask = (questionId: string, answer: string) =>
      toAnswer(asking, { userInputId: 'q', questionId, answer })
    expect(ask('one', 'B')).toEqual({ questionId: 'one', selectedLabel: 'B' })
    expect(ask('one', 'something else')).toEqual({ questionId: 'one', freeText: 'something else' })
    expect(ask('many', 'A, B')).toEqual({ questionId: 'many', selectedLabels: ['A', 'B'] })
  })
})

describe('FileBridge', () => {
  it('turns an inbox file into a job and keeps the outbox current until it ends', async () => {
    const current = { job: job() }
    api = fakeApi(current)
    bridge = new FileBridge(dir, api, 50)
    await bridge.start()
    expect(await readFile(join(dir, 'README.md'), 'utf8')).toContain('# Muse Desktop bridge')
    await writeFile(join(dir, 'inbox', 'task-1.md'), '---\nproject: /p\n---\nSay hi\n')
    const outbox = join(dir, 'outbox', 'task-1.md')
    await vi.waitFor(async () =>
      expect(await readFile(outbox, 'utf8')).toContain('status: running'),
    )
    expect(api.asked[0]).toMatchObject({ project: '/p', prompt: 'Say hi' })
    expect(await readdir(join(dir, 'inbox', 'processed'))).toEqual(['task-1.md'])
    current.job = job({ status: 'done', reply: 'Hi!', transcript: 'All done.' })
    await vi.waitFor(async () => {
      const text = await readFile(outbox, 'utf8')
      expect(text).toContain('status: done')
      expect(text).toContain('# Reply\nHi!')
      expect(text).toContain('All done.')
    })
  })
  it('processes requests that were waiting before it started', async () => {
    api = fakeApi({ job: job() })
    const early = new FileBridge(dir, api, 50)
    await early.start()
    await early.stop()
    await writeFile(join(dir, 'inbox', 'early.md'), '---\nproject: /p\n---\nqueued\n')
    bridge = new FileBridge(dir, api, 50)
    await bridge.start()
    await vi.waitFor(() => expect(api.asked).toHaveLength(1))
  })
  it('moves an invalid request to rejected with the reason', async () => {
    api = fakeApi({ job: job() })
    api.ask.mockRejectedValueOnce(new Error('That project is not trusted in Muse Desktop.'))
    bridge = new FileBridge(dir, api, 50)
    await bridge.start()
    await writeFile(join(dir, 'inbox', 'bad.md'), '---\neffort: low\n---\nno project')
    await writeFile(join(dir, 'inbox', 'untrusted.md'), '---\nproject: /x\n---\nhi')
    await vi.waitFor(async () => {
      expect(await readFile(join(dir, 'inbox', 'rejected', 'bad.error.txt'), 'utf8')).toContain(
        'project',
      )
      expect(
        await readFile(join(dir, 'inbox', 'rejected', 'untrusted.error.txt'), 'utf8'),
      ).toContain('not trusted')
    })
  })
  it('lists pending approvals and applies approve, answer and cancel decisions', async () => {
    const current = {
      job: job({
        status: 'waiting-approval',
        approvals: [
          {
            approvalId: 'a1',
            summary: 'shell: rm x',
            choices: [{ choiceId: 'c1', label: 'Allow' }],
          },
        ],
        questions: [
          {
            userInputId: 'q1',
            questions: [
              { id: 'pick', header: 'Pick', question: 'Which?', options: ['A'], mode: 'single' },
            ],
          },
        ],
      }),
    }
    api = fakeApi(current)
    bridge = new FileBridge(dir, api, 50)
    await bridge.start()
    await writeFile(join(dir, 'inbox', 't.md'), '---\nproject: /p\n---\nrm x')
    await vi.waitFor(async () => {
      const text = await readFile(join(dir, 'outbox', 't.md'), 'utf8')
      expect(text).toContain('- a1: shell: rm x. Choices: c1 (Allow)')
      expect(text).toContain('q1 / pick: Which? Options: A')
      expect(text).toContain('decisions/j1.md')
    })
    await writeFile(join(dir, 'decisions', 'j1.md'), '---\napprovalId: a1\nchoiceId: c1\n---\n')
    await vi.waitFor(() => expect(api.approve).toHaveBeenCalledWith('j1', 'a1', 'c1'))
    await writeFile(
      join(dir, 'decisions', 'j1.md'),
      '---\nuserInputId: q1\nquestionId: pick\nanswer: A\n---\n',
    )
    await vi.waitFor(() =>
      expect(api.answer).toHaveBeenCalledWith('j1', 'q1', [
        { questionId: 'pick', selectedLabel: 'A' },
      ]),
    )
    await writeFile(join(dir, 'decisions', 'j1.md'), '---\ncancel: true\n---\n')
    await vi.waitFor(() => expect(api.cancel).toHaveBeenCalledWith('j1'))
    expect(await readdir(join(dir, 'decisions', 'processed'))).toHaveLength(3)
  })
  it('explains an invalid decision', async () => {
    api = fakeApi({ job: job() })
    bridge = new FileBridge(dir, api, 50)
    await bridge.start()
    await writeFile(join(dir, 'decisions', 'j1.md'), '---\nchoiceId: c1\n---\n')
    await vi.waitFor(async () =>
      expect(await readFile(join(dir, 'decisions', 'j1.error.txt'), 'utf8')).toBeTruthy(),
    )
    expect(api.approve).not.toHaveBeenCalled()
  })
})
