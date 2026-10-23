// A scripted stand-in for src/headless/server.ts, for mMac's UI tests. It speaks the line
// protocol of src/headless/wire.ts (keep `protocol` below equal to HEADLESS_PROTOCOL) and
// serves three conversations. The first asks once when opened, then waits on an approval and a
// question. It also answers the inspector's and the Settings window's methods from fixed or
// in-memory data, and its rename Asks before it replies. A `send` of "crash now" ends the
// process with code 1, as a backend that crashes does.
// The M4a methods answer with the real backend's shapes: `export` writes its file with mode 0600,
// `attachments` checks each file and keeps it under an `att-<n>` id, and `send` takes those ids.
// `terminal`, `cli-terminal` and `voice` open nothing: no Terminal window, and no microphone.
// FAKE_BACKEND_OFFLINE=1 starts disconnected until mMac calls `connect`. FAKE_BACKEND_NO_PROJECT=1
// starts with no recent project, so mMac starts on All projects.
// Each request and Ask answer is appended to the file FAKE_BACKEND_LOG names, with the fake's
// start and every reply it writes, so a failed test shows how far the fake got.
import {
  appendFileSync,
  closeSync,
  fchmodSync,
  openSync,
  rmSync,
  statSync,
  writeSync,
} from 'node:fs'
import { basename, isAbsolute } from 'node:path'
import { createInterface } from 'node:readline'

const logFile = process.env.FAKE_BACKEND_LOG
// FAKE_BACKEND_COPY names a second file, outside the test's temporary folder, that
// mac/scripts/ui-tests.sh keeps after the run. Its folder may not exist when no script set it up.
const copyFile = process.env.FAKE_BACKEND_COPY
const record = (entry) => {
  const line = `${JSON.stringify(entry)}\n`
  if (logFile) appendFileSync(logFile, line)
  if (copyFile) {
    try {
      appendFileSync(copyFile, line)
    } catch {
      // No folder: the run is not the script's, so there is nothing to keep.
    }
  }
}
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
const preferences = {
  theme: 'muse',
  cliPath: '',
  recentProjects: process.env.FAKE_BACKEND_NO_PROJECT === '1' ? [] : [project],
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
  const other = others.find((entry) => entry.session.sessionId === sessionId)
  return other
    ? { ...other, approvals: [], questions: [] }
    : { session, items, approvals, questions }
}
// Sends the changed first conversation shortly after a reply, as MuseHost does.
const update = () => setTimeout(() => write({ event: { type: 'session', view: view() } }), 50)
const ready = { state: 'ready', version: 'fake', path: '/usr/local/bin/muse' }
let offline = process.env.FAKE_BACKEND_OFFLINE === '1'
const sessionById = (sessionId) =>
  sessionId === 'fake-1'
    ? session
    : others.find((entry) => entry.session.sessionId === sessionId)?.session

// The composer's attachments, as src/headless/attachments.ts keeps them: id → the chip.
const attachments = new Map()
let attachmentCount = 0
const m4aMethods = {
  // As muse-host.ts's compact: the CLI's status.
  compact: () => ({ status: 'started' }),
  // As backend.ts's export: an absolute path, mode 0600 on the open file before any content, and
  // the path back.
  export: (sessionId, path) => {
    if (typeof path !== 'string' || !isAbsolute(path))
      throw new Error('Choose a full path for the exported file.')
    const shown = view(sessionId)
    const content = [
      `# ${shown.session.name || 'Muse conversation'}`,
      `Project: ${shown.session.workspaceRoot || 'None'}`,
      ...shown.items.map(
        (item) =>
          `## ${item.kind === 'userMessage' ? 'You' : item.kind === 'agentMessage' ? 'Muse' : item.kind}\n\n${item.text ?? item.statusLine ?? ''}`,
      ),
    ].join('\n\n')
    const fd = openSync(path, 'w', 0o600)
    try {
      fchmodSync(fd, 0o600)
      writeSync(fd, `${content}\n`)
    } finally {
      closeSync(fd)
    }
    return path
  },
  // As attachments.ts's register: every file is checked, then all are kept, or none.
  attachments: (paths) => {
    if (paths.some((path) => !isAbsolute(path)))
      throw new Error('Choose files by their full paths.')
    if (paths.length > 5) throw new Error('Select up to five files at a time.')
    const chosen = paths.map((path) => {
      let info
      try {
        info = statSync(path)
      } catch {
        info = null
      }
      if (!info?.isFile() || info.size > 2 * 1024 * 1024)
        throw new Error(`${basename(path)} must be a file smaller than 2 MB.`)
      return {
        id: `att-${++attachmentCount}`,
        name: basename(path),
        kind: /\.(png|jpe?g|webp|gif)$/i.test(path) ? 'image' : 'text',
        size: info.size,
      }
    })
    for (const chip of chosen) attachments.set(chip.id, chip)
    return chosen
  },
  'remove-attachment': (id) => {
    attachments.delete(id)
  },
  // As backend.ts's voice: the clip is deleted after it is read. No CLI runs.
  voice: (path) => {
    if (typeof path !== 'string' || !isAbsolute(path) || !/\.wav$/i.test(path))
      throw new Error('The recording is not a supported PCM audio clip. Please record it again.')
    rmSync(path, { force: true })
    return 'Fake transcription.'
  },
  'cancel-voice': () => null,
  // Terminal never opens: the real methods run osascript.
  terminal: () => null,
  'cli-terminal': () => null,
}

const methods = {
  // As backend.ts does: a client that speaks another protocol gets an error reply.
  hello: (theirs) => {
    if (theirs !== 1)
      throw new Error(`mMac speaks backend protocol ${theirs}, but the fake speaks 1.`)
    return { protocol: 1, version: 'fake' }
  },
  start: (options) => {
    bridgeToken = options?.bridgeToken ?? ''
    return {
      preferences,
      status: offline
        ? { state: 'error', message: 'The fake Muse Code is offline.', path: '/usr/local/bin/muse' }
        : ready,
    }
  },
  connect: () => {
    offline = false
    return ready
  },
  sessions: () => ({
    sessions: [session, ...others.map((entry) => entry.session)],
    nextCursor: null,
  }),
  models: () => models,
  open: (sessionId) => view(sessionId),
  send: ({ text, attachments: ids = [] }) => {
    // A crash: no reply, and stdout closes with the process.
    if (text === 'crash now') process.exit(1)
    // As backend.ts's send: at most five, text or a file, and only ids it still holds.
    if (ids.length > 5) throw new Error('You can attach up to five files per message.')
    if (!text.trim() && !ids.length) throw new Error('Write a message or attach a file first.')
    if (ids.some((id) => !attachments.has(id)))
      throw new Error('An attachment expired. Select it again.')
    for (const id of ids) attachments.delete(id)
    return null
  },
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
  ...m4aMethods,
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
    // A rename Asks while mMac's rename sheet is still open, as a trust prompt can. The renamed
    // conversation's event goes before the reply, so mMac shows the new name once rename returns.
    if (message.method === 'rename') {
      pending = {
        id: message.id,
        value: () => {
          const [sessionId, name] = message.args
          const renamed = sessionById(sessionId)
          if (renamed) renamed.name = name
          write({ event: { type: 'session', view: view(sessionId) } })
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
