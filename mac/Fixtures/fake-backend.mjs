// A scripted stand-in for src/headless/server.ts, for mMac's UI tests. It speaks the line
// protocol of src/headless/wire.ts (keep `protocol` below equal to HEADLESS_PROTOCOL) and
// serves three conversations. The first asks once when opened, then waits on an approval and a
// question. It also answers the inspector's and the Settings window's methods from fixed or
// in-memory data, and its rename Asks before it replies. A `send` of "crash now" ends the
// process with code 1, as a backend that crashes does.
// Each request and Ask answer is appended to the file FAKE_BACKEND_LOG names, with the fake's
// start and every reply it writes, so a failed test shows how far the fake got.
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'

const logFile = process.env.FAKE_BACKEND_LOG
const record = (entry) => logFile && appendFileSync(logFile, `${JSON.stringify(entry)}\n`)
const write = (message) => {
  if ('id' in message) {
    record({ reply: message.id, ok: message.ok, ...(message.ok ? {} : { error: message.error }) })
  }
  process.stdout.write(`${JSON.stringify(message)}\n`)
}
record({ fake: 'started', pid: process.pid })

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
  approvalMode: { mode: 'promptUnmatched' },
}
// Two more conversations, with no cards, for the restart test.
const others = [
  ['fake-2', 'Second fake conversation', 'The second conversation says hello.'],
  ['fake-3', 'Third fake conversation', 'The third conversation says hello.'],
].map(([sessionId, name, text]) => ({
  session: { ...session, sessionId, name },
  items: [
    { itemId: `${sessionId}-a1`, kind: 'agentMessage', revision: 1, status: 'completed', text },
  ],
}))
// The side session a side chat opens. Never in the sessions list.
const side = {
  session: { ...session, sessionId: 'fake-side', kind: 'sideChat', name: 'Side of fake' },
  items: [
    {
      itemId: 'side-a1',
      kind: 'agentMessage',
      revision: 1,
      status: 'completed',
      text: 'The side says hello.',
    },
  ],
}
const preferences = {
  theme: 'muse',
  cliPath: '',
  recentProjects: [project],
  trustedProjects: [project],
  reasoningEffort: 'high',
  archivedSessionIds: [],
  pinnedSessionIds: [],
  fontSize: 'comfortable',
  reduceMotion: false,
  notifyOnCompletion: false,
  bridgeFilesEnabled: false,
  bridgeMcpEnabled: false,
  bridgeMcpPort: 7735,
}
// The Settings window's state. The paths are only strings; the fake never creates them.
const mcp = { file: '/tmp/fake-muse/settings.json', servers: [] }
let bridgeToken = ''

function bridgeStatus() {
  return {
    folder: '/tmp/fake-mmac/bridge',
    files: { enabled: preferences.bridgeFilesEnabled, running: preferences.bridgeFilesEnabled },
    mcp: {
      enabled: preferences.bridgeMcpEnabled,
      running: preferences.bridgeMcpEnabled && Boolean(bridgeToken),
      url: `http://127.0.0.1:${preferences.bridgeMcpPort}/mcp`,
      hasToken: Boolean(bridgeToken),
    },
    activeJobs: 0,
  }
}

const settingsMethods = {
  'mcp-list': () => mcp,
  'mcp-add': (server) => {
    mcp.servers.push(
      server.transport === 'stdio'
        ? {
            name: server.name,
            transport: 'stdio',
            enabled: true,
            command: server.command,
            args: server.args,
            envNames: Object.keys(server.env),
          }
        : {
            name: server.name,
            transport: 'http',
            enabled: true,
            url: server.url,
            headerNames: Object.keys(server.headers),
          },
    )
    return null
  },
  'mcp-enabled': (name, enabled) => {
    const server = mcp.servers.find((entry) => entry.name === name)
    if (server) server.enabled = enabled
    return null
  },
  'mcp-remove': (name) => {
    mcp.servers = mcp.servers.filter((entry) => entry.name !== name)
    return null
  },
  'mcp-login': () => null,
  'bridge-status': () => bridgeStatus(),
  'bridge-token': () => (bridgeToken = 'fake-token-' + Date.now()),
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
  {
    itemId: 't1',
    kind: 'toolCall',
    revision: 1,
    status: 'completed',
    tool: 'edit',
    statusLine: 'Edited app.swift',
    patchSummary: { added: 12, removed: 1, files: 1 },
  },
  {
    itemId: 'sub1',
    kind: 'subagent',
    revision: 1,
    status: 'completed',
    objective: 'Count the files',
    childSessionId: 'fake-2',
    durationMs: 1500,
    controlStatus: 'closed',
    usage: { inputTokens: 100, outputTokens: 20, cachedTokens: 0 },
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
// The plain working diff Revert hunk counts from. The labelled diff above ends with it.
const rawDiff = diff.slice('Working changes\n'.length)
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
const view = (sessionId = 'fake-1') => {
  if (sessionId === 'fake-side') return { ...side, approvals: [], questions: [] }
  const other = others.find((entry) => entry.session.sessionId === sessionId)
  return other
    ? { ...other, approvals: [], questions: [] }
    : {
        session,
        items,
        approvals,
        questions,
        context: { used: 4200, window: 10000, pressure: 'normal' },
        todos: [
          {
            text: 'Clean the build folder',
            status: 'inProgress',
            activeForm: 'Cleaning the build folder',
          },
          { text: 'Run the tests', status: 'pending' },
        ],
      }
}
// Sends the changed first conversation shortly after a reply, as MuseHost does.
const update = () => setTimeout(() => write({ event: { type: 'session', view: view() } }), 50)
const ready = { state: 'ready', version: 'fake', path: '/usr/local/bin/muse' }

const methods = {
  // As backend.ts does: a client that speaks another protocol gets an error reply.
  hello: (theirs) => {
    if (theirs !== 3)
      throw new Error(`mMac speaks backend protocol ${theirs}, but the fake speaks 3.`)
    return { protocol: 3, version: 'fake' }
  },
  start: (options) => {
    bridgeToken = options?.bridgeToken ?? ''
    return { preferences, status: ready }
  },
  sessions: () => ({
    sessions: [session, ...others.map((entry) => entry.session)],
    nextCursor: null,
  }),
  models: () => models,
  open: (sessionId) => view(sessionId),
  send: ({ text }) => {
    // A crash: no reply, and stdout closes with the process.
    if (text === 'crash now') process.exit(1)
    return null
  },
  'set-model': (_, modelId) => {
    session.modelId = modelId
    update()
  },
  'set-approval-mode': (_, mode) => {
    session.approvalMode = { mode }
    update()
    return mode
  },
  'side-chat': () => view('fake-side'),
  shell: (_, command) => {
    items.push({
      itemId: `sh-${items.length}`,
      kind: 'userShell',
      revision: 1,
      status: 'completed',
      commandText: command,
      visibleOutput: 'hi\n',
      exitCode: 0,
      durationMs: 12,
    })
    update()
    return null
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
  'git-raw-diff': () => rawDiff,
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
  ...settingsMethods,
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
    // The first open of the first conversation Asks first, so the test can press Escape on a
    // real Ask sheet.
    if (message.method === 'open' && message.args?.[0] === 'fake-1' && !asked) {
      asked = true
      pending = { id: message.id, value: () => view('fake-1') }
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
