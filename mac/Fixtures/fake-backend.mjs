// A scripted stand-in for src/headless/server.ts, for mMac's UI tests. It speaks the line
// protocol of src/headless/wire.ts (keep `protocol` below equal to HEADLESS_PROTOCOL) and
// serves one conversation that asks once, then waits on an approval and a question.
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
]
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
  shutdown: () => {
    setTimeout(() => process.exit(0), 50)
    return true
  },
}

let asked = false
let waitingOpen = null
createInterface({ input: process.stdin })
  .on('line', (line) => {
    // As wire.ts does: blank lines are skipped.
    if (!line.trim()) return
    const message = JSON.parse(line)
    if ('answer' in message) {
      record({ answer: message.answer, choice: message.choice })
      if (waitingOpen !== null) write({ id: waitingOpen, ok: true, value: view() })
      waitingOpen = null
      return
    }
    record({ method: message.method, args: message.args ?? [] })
    // The first open Asks first, so the test can press Escape on a real Ask sheet.
    if (message.method === 'open' && !asked) {
      asked = true
      waitingOpen = message.id
      write({
        ask: 1,
        kind: 'confirm',
        title: 'Open the fake conversation?',
        message: 'Press Escape to choose the last button.',
        buttons: ['Open', 'Open anyway'],
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
