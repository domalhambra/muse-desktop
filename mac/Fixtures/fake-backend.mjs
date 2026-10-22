// A scripted stand-in for src/headless/server.ts, for mMac's UI tests. It speaks the line
// protocol of src/headless/wire.ts (keep `protocol` below equal to HEADLESS_PROTOCOL) and
// serves one conversation that asks once, then waits on an approval and a question. It also
// answers the inspector's methods from fixed data, and its rename Asks before it replies.
// Each request and Ask answer is appended to the file FAKE_BACKEND_LOG names.
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'

const logFile = process.env.FAKE_BACKEND_LOG
const record = (entry) => logFile && appendFileSync(logFile, `${JSON.stringify(entry)}\n`)
const write = (message) => process.stdout.write(`${JSON.stringify(message)}\n`)

const project = process.env.MMAC_TEST_PROJECT ?? '/tmp'
const now = new Date().toISOString()
const session = {
  sessionId: 'fake-1',
  workspaceRoot: project,
  createdAt: now,
  updatedAt: now,
  status: 'idle',
  activeTurnId: null,
  modelId: 'fake-one',
  name: 'Fake conversation',
  turnCount: 1,
}
const preferences = {
  theme: 'muse',
  cliPath: '',
  recentProjects: [project],
  trustedProjects: [project],
  reasoningEffort: 'high',
  archivedSessionIds: [],
  pinnedSessionIds: [],
}
const models = [
  {
    modelId: 'fake-one',
    displayLabel: 'Fake Model One',
    providerId: 'fake',
    isDefault: true,
    isActive: true,
    contextLimit: null,
  },
  {
    modelId: 'fake-two',
    displayLabel: 'Fake Model Two',
    providerId: 'fake',
    isDefault: false,
    isActive: true,
    contextLimit: null,
  },
]
const items = [
  {
    itemId: 'u1',
    kind: 'userMessage',
    revision: 1,
    status: 'completed',
    text: 'Clean the build folder',
  },
  {
    itemId: 'a1',
    kind: 'agentMessage',
    revision: 1,
    status: 'completed',
    text: 'I need two things from you first.',
  },
  {
    itemId: 'h1',
    kind: 'hookRun',
    revision: 1,
    status: 'completed',
    label: 'Format on save',
    statusLine: 'Ran prettier',
  },
]
// The inspector's fixtures: one modified file with one hunk, one untracked file, one Muse worktree.
const changes = [
  { path: 'src/app.swift', status: 'M', staged: false },
  { path: 'notes.md', status: '??', staged: false },
]
const diff = [
  'Working changes',
  'diff --git a/src/app.swift b/src/app.swift',
  '--- a/src/app.swift',
  '+++ b/src/app.swift',
  '@@ -1,3 +1,3 @@',
  ' let a = 1',
  '-let b = 2',
  '+let b = 3',
  ' let c = 4',
  '',
].join('\n')
const worktreePath = `${project}/.muse/worktrees/feature`
let approvals = [
  {
    approvalId: 'appr-1',
    sessionId: 'fake-1',
    toolName: 'shell',
    rawArgs: 'rm -rf build',
    currentRequirementId: { approvalId: 'appr-1', sourceIndex: 0 },
    subject: { kind: 'command', command: 'rm -rf build' },
    availableChoices: [
      { choiceId: 'once', label: 'Allow once', decision: 'approved', scope: 'once' },
      {
        choiceId: 'always',
        label: 'Always allow',
        decision: 'approvedForSession',
        scope: 'localPersistent',
        rulePreview: 'Allow rm -rf build',
      },
      { choiceId: 'deny', label: 'Deny', decision: 'denied', scope: 'once' },
    ],
  },
]
let questions = [
  {
    userInputId: 'ask-1',
    sessionId: 'fake-1',
    questions: [
      {
        id: 'color',
        header: 'Color',
        question: 'Which color?',
        options: [{ label: 'Blue', description: 'Calm' }, { label: 'Green' }],
        selection: { mode: 'single' },
      },
    ],
  },
]
const view = () => ({ session, items, approvals, questions })
// Sends the changed conversation shortly after a reply, as MuseHost does.
const update = () => setTimeout(() => write({ event: { type: 'session', view: view() } }), 50)
const ready = { state: 'ready', version: 'fake' }

const methods = {
  // As backend.ts does: a client that speaks another protocol gets an error reply.
  hello: (theirs) => {
    if (theirs !== 1)
      throw new Error(`mMac speaks backend protocol ${theirs}, but the fake speaks 1.`)
    return { protocol: 1, version: 'fake' }
  },
  start: () => ({ preferences, status: ready }),
  sessions: () => ({ sessions: [session], nextCursor: null }),
  models: () => models,
  open: () => view(),
  'set-model': (_, modelId) => {
    session.modelId = modelId
    update()
  },
  approve: (_, approvalId) => {
    approvals = approvals.filter((entry) => entry.approvalId !== approvalId)
    update()
  },
  answer: (_, userInputId) => {
    questions = questions.filter((entry) => entry.userInputId !== userInputId)
    update()
  },
  'cancel-question': (_, userInputId) => {
    questions = questions.filter((entry) => entry.userInputId !== userInputId)
    update()
  },
  preferences: (patch) => Object.assign(preferences, patch),
  'git-status': () => ({ branch: 'main', isRepository: true, changes }),
  'git-diff': () => diff,
  'git-revert-hunk': () => null,
  'git-stage-file': () => null,
  'git-revert-file': () => null,
  files: (_, directory) =>
    directory === 'src'
      ? [{ name: 'app.swift', path: 'src/app.swift', directory: false }]
      : [
          { name: 'src', path: 'src', directory: true },
          { name: 'notes.md', path: 'notes.md', directory: false },
        ],
  'read-file': () => 'let a = 1\nlet b = 3\nlet c = 4\n',
  worktrees: () => [
    { path: project, branch: 'main', isMain: true, sessionIds: [] },
    { path: worktreePath, branch: 'muse/feature', isMain: false, sessionIds: [] },
  ],
  'worktree-merge': () => ({ ok: true, output: 'Merged muse/feature.' }),
  'worktree-remove': () => null,
  shutdown: () => {
    setTimeout(() => process.exit(0), 50)
    return true
  },
}

let asked = false
// A request whose reply waits for the answer to the Ask it raised.
let pending = null
createInterface({ input: process.stdin })
  .on('line', (line) => {
    // As wire.ts does: blank lines are skipped.
    if (!line.trim()) return
    const message = JSON.parse(line)
    if ('answer' in message) {
      record({ answer: message.answer, choice: message.choice })
      if (pending) write({ id: pending.id, ok: true, value: pending.value() ?? null })
      pending = null
      return
    }
    record({ method: message.method, args: message.args ?? [] })
    // The first open Asks first, so the test can press Escape on a real Ask sheet.
    if (message.method === 'open' && !asked) {
      asked = true
      pending = { id: message.id, value: view }
      write({
        ask: 1,
        kind: 'confirm',
        title: 'Open the fake conversation?',
        message: 'Press Escape to choose the last button.',
        buttons: ['Open', 'Open anyway'],
      })
      return
    }
    // A rename Asks while mMac's rename sheet is still open, as a trust prompt can.
    if (message.method === 'rename') {
      pending = {
        id: message.id,
        value: () => {
          session.name = message.args[1]
          update()
          write({ event: { type: 'sessions-changed' } })
        },
      }
      write({
        ask: 2,
        kind: 'confirm',
        title: 'Rename needs an answer',
        message: 'The fake asks while the rename sheet is open.',
        buttons: ['Go on', 'Cancel'],
      })
      return
    }
    const action = methods[message.method]
    if (!action) {
      write({ id: message.id, ok: false, error: `The fake backend has no ${message.method}.` })
      return
    }
    try {
      write({ id: message.id, ok: true, value: action(...(message.args ?? [])) ?? null })
    } catch (error) {
      write({ id: message.id, ok: false, error: error.message })
    }
  })
  .on('close', () => process.exit(0))
