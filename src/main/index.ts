import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  Menu,
  nativeImage,
  clipboard,
  nativeTheme,
  Notification,
  safeStorage,
  shell,
  systemPreferences,
  type IpcMainInvokeEvent,
} from 'electron'
import { execFile, spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { mkdir, readFile, realpath, stat, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, extname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { z } from 'zod'
import {
  answerSchema,
  effortSchema,
  preferencesPatchSchema,
  preferencesSchema,
  type AppEvent,
  type Attachment,
  type BridgeStatus,
  type McpServerView,
  type Preferences,
} from '../shared/protocol'
import { MuseHost, messageOf } from './muse-host'
import { readPreferences, writePreferences } from './preferences'
import { getGitDiff, getGitStatus, getRawDiff, revertFile, revertHunk, stageFile } from './git'
import { listProjectFiles, readProjectFile } from './files'
import { recordMuseTrust } from './muse-config'
import { publish } from './event-bus'
import { AgentApi } from './agent-api'
import { FileBridge } from './bridge-files'
import { McpBridge } from './bridge-mcp'
import { readToken, regenerateToken, type TokenCipher } from './bridge-token'
import {
  addServer,
  listServers,
  mcpServerSchema,
  removeServer,
  setServerEnabled,
  settingsFile,
} from './mcp-config'
import { mergeWorktree, removeWorktree } from './worktrees'
import { projectRoot, worktreeParent } from '../shared/worktree'
import { VoiceTranscriber } from './voice'
import {
  initializeUpdates,
  updateStatus,
  checkForUpdates,
  setAutomaticUpdateChecks,
  setUpdaterBusy,
} from './updates'

if (app.isPackaged) delete process.env.MUSE_DESKTOP_TEST_PROVIDER

app.setPath(
  'userData',
  process.env.MUSE_DESKTOP_USER_DATA && !app.isPackaged
    ? process.env.MUSE_DESKTOP_USER_DATA
    : join(app.getPath('appData'), 'muse-desktop'),
)

const directory = fileURLToPath(new URL('.', import.meta.url))
const execute = promisify(execFile)
const runtimePlatform =
  !app.isPackaged && process.env.MUSE_DESKTOP_PLATFORM
    ? process.env.MUSE_DESKTOP_PLATFORM
    : process.platform
const id = z.string().min(1).max(200)
const pathSchema = z.string().min(1).max(4096)
const rendererPath = resolve(directory, '../renderer/index.html')
const preferencePath = join(app.getPath('userData'), 'preferences.json')
let preferences: Preferences
let window: BrowserWindow | undefined
let quitting = false
let preferenceWrites: Promise<void> = Promise.resolve()
const selectedFiles = new Map<string, { attachment: Attachment; path: string }>()
const previousStatuses = new Map<string, string>()

function emit(event: AppEvent) {
  publish(event)
  if (event.type === 'session') {
    const session = event.view.session
    if (
      previousStatuses.get(session.sessionId) === 'running' &&
      session.status === 'idle' &&
      preferences.notifyOnCompletion &&
      !window?.isFocused()
    ) {
      const notification = new Notification({
        title: 'Muse is ready for you',
        body: session.name || session.title || 'Your conversation has an update.',
      })
      notification.on('click', () => {
        window?.show()
        window?.focus()
      })
      notification.show()
    }
    previousStatuses.set(session.sessionId, session.status)
    setUpdaterBusy([...previousStatuses.values()].some((status) => status === 'running'))
  }
  if (window && !window.isDestroyed()) window.webContents.send('muse:event', event)
}
const muse = new MuseHost(emit)

// Bridges: other agents drive Muse Code through Desktop, limited to projects
// Desktop already knows and trusts.
const agentApi = new AgentApi(muse, {
  resolveProject: async (path) => {
    const project = await knownProject(path)
    if (
      !preferences.trustedProjects.includes(project) &&
      !preferences.trustedProjects.includes(projectRoot(project))
    )
      throw new Error('That project is not trusted in Muse Desktop. Open it there first.')
    return project
  },
})
const bridgeRoot = join(app.getPath('userData'), 'bridge')
const tokenPath = join(app.getPath('userData'), 'bridge-token')
const tokenCipher: TokenCipher = {
  available: () => safeStorage.isEncryptionAvailable(),
  encrypt: (value) => safeStorage.encryptString(value),
  decrypt: (value) => safeStorage.decryptString(value),
}
let fileBridge: FileBridge | undefined
let mcpBridge: { bridge: McpBridge; port: number; token: string } | undefined
const bridgeErrors: { files?: string; mcp?: string } = {}
let bridgeSync: Promise<void> = Promise.resolve()

function syncBridges() {
  bridgeSync = bridgeSync.then(async () => {
    const wantFiles = preferences.bridgeFilesEnabled && !quitting
    if (wantFiles && !fileBridge) {
      const bridge = new FileBridge(bridgeRoot, agentApi)
      try {
        await bridge.start()
        fileBridge = bridge
        delete bridgeErrors.files
      } catch (error) {
        await bridge.stop().catch(() => {})
        bridgeErrors.files = messageOf(error)
      }
    } else if (!wantFiles && fileBridge) {
      await fileBridge.stop().catch(() => {})
      fileBridge = undefined
    }
    if (!wantFiles) delete bridgeErrors.files
    const wantMcp = preferences.bridgeMcpEnabled && !quitting
    const token = wantMcp ? await readToken(tokenPath, tokenCipher) : ''
    const port = preferences.bridgeMcpPort
    if (mcpBridge && (!wantMcp || mcpBridge.port !== port || mcpBridge.token !== token)) {
      await mcpBridge.bridge.stop().catch(() => {})
      mcpBridge = undefined
    }
    if (wantMcp && !mcpBridge) {
      const bridge = new McpBridge(agentApi, {
        port,
        token,
        projects: () =>
          preferences.recentProjects.filter((project) =>
            preferences.trustedProjects.includes(project),
          ),
      })
      try {
        await bridge.start()
        mcpBridge = { bridge, port, token }
        delete bridgeErrors.mcp
      } catch (error) {
        await bridge.stop().catch(() => {})
        bridgeErrors.mcp =
          error instanceof Error && 'code' in error && error.code === 'EADDRINUSE'
            ? `Port ${port} is in use. Choose another port.`
            : messageOf(error)
      }
    } else if (!wantMcp) delete bridgeErrors.mcp
  })
  return bridgeSync
}

async function bridgeStatus(): Promise<BridgeStatus> {
  await bridgeSync
  return {
    folder: bridgeRoot,
    files: {
      enabled: preferences.bridgeFilesEnabled,
      running: Boolean(fileBridge),
      ...(bridgeErrors.files ? { error: bridgeErrors.files } : {}),
    },
    mcp: {
      enabled: preferences.bridgeMcpEnabled,
      running: Boolean(mcpBridge),
      url: `http://127.0.0.1:${preferences.bridgeMcpPort}/mcp`,
      hasToken: Boolean(await readToken(tokenPath, tokenCipher)),
      ...(bridgeErrors.mcp ? { error: bridgeErrors.mcp } : {}),
    },
    activeJobs: agentApi.activeCount,
  }
}
const voice = new VoiceTranscriber()
let microphoneEnabled = false

function trustedSender(event: IpcMainInvokeEvent) {
  const frame = event.senderFrame
  if (!window || frame !== window.webContents.mainFrame) throw new Error('Untrusted app frame.')
  const url = new URL(frame.url)
  const developmentUrl = process.env.ELECTRON_RENDERER_URL
  const trusted =
    app.isPackaged || !developmentUrl
      ? url.protocol === 'file:' &&
        (process.platform === 'win32'
          ? resolve(fileURLToPath(url)).toLowerCase() === rendererPath.toLowerCase()
          : fileURLToPath(url) === rendererPath)
      : url.origin === new URL(developmentUrl).origin
  if (!trusted) throw new Error('Untrusted app origin.')
}

function handle(channel: string, action: (...args: unknown[]) => unknown) {
  ipcMain.handle(`muse:${channel}`, async (event, ...args: unknown[]) => {
    trustedSender(event)
    try {
      return { ok: true, value: await action(...args) }
    } catch (error) {
      return { ok: false, error: messageOf(error) }
    } finally {
      setUpdaterBusy(muse.hasActiveTurns())
    }
  })
}

async function savePreferences(patch: Partial<Preferences>) {
  const write = preferenceWrites.then(async () => {
    const snapshot = preferencesSchema.parse({ ...preferences, ...patch })
    await writePreferences(preferencePath, snapshot)
    preferences = snapshot
    nativeTheme.themeSource =
      snapshot.theme === 'system'
        ? 'system'
        : ['moonlight', 'muse', 'plush'].includes(snapshot.theme)
          ? 'dark'
          : 'light'
    emit({ type: 'preferences', preferences: snapshot })
    if (Object.keys(patch).some((key) => key.startsWith('bridge'))) void syncBridges()
    return snapshot
  })
  preferenceWrites = write.then(
    () => {},
    () => {},
  ) // A failed write must not block later saves.
  return write
}

async function knownProject(value: unknown) {
  const project = await realpath(pathSchema.parse(value))
  const resolvedRecent = await Promise.all(
    preferences.recentProjects.map(async (entry) => {
      try {
        return await realpath(entry)
      } catch {
        return entry
      }
    }),
  )
  // A Muse-created worktree (`<project>/.muse/worktrees/<name>`) belongs to its project.
  const candidates = [project, worktreeParent(project)].filter((entry) => entry !== null)
  const matches = resolvedRecent.some((entry) =>
    candidates.some((candidate) =>
      process.platform === 'win32'
        ? entry.toLowerCase() === candidate.toLowerCase()
        : entry === candidate,
    ),
  )
  if (!matches) throw new Error('Choose this project using Open project first.')
  return project
}

async function trustProject(project: string) {
  if (preferences.trustedProjects.includes(project)) return
  const parent = worktreeParent(project)
  if (parent && preferences.trustedProjects.includes(parent)) return
  if (!window) throw new Error('No app window is available.')
  const { response } = await dialog.showMessageBox(window, {
    type: 'question',
    title: 'Trust this project?',
    message: `Work with Muse in “${basename(project)}”?`,
    detail: `Muse can read and edit this project and use its skills, instructions, and hooks. Its existing sandbox and tool approval settings remain active.\n\n${project}\n\nOnly continue with a project you trust.`,
    buttons: ['Trust project', 'Cancel'],
    defaultId: 1,
    cancelId: 1,
    noLink: true,
  })
  if (response !== 0) throw new Error('Project trust was cancelled. No session was started.')
  await savePreferences({ trustedProjects: [...preferences.trustedProjects, project] })
}

async function sessionProject(sessionId: string) {
  const session = muse.getSession(sessionId)
  if (!session.workspaceRoot) throw new Error('This conversation has no project folder.')
  const project = await realpath(session.workspaceRoot)
  await trustProject(project)
  return project
}

async function openProjectTerminal(project: string, cliArgs?: string[]) {
  const cliBinary = muse.status.path || 'muse'
  if (process.platform === 'darwin') {
    const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`
    const suffix = cliArgs ? ` && ${[cliBinary, ...cliArgs].map(quote).join(' ')}` : ''
    // argv carries the command as data; no project path is interpolated into AppleScript.
    await execute(
      '/usr/bin/osascript',
      [
        '-e',
        'on run argv',
        '-e',
        'tell application "Terminal"',
        '-e',
        'activate',
        '-e',
        'do script (item 1 of argv)',
        '-e',
        'end tell',
        '-e',
        'end run',
        `cd ${quote(project)}${suffix}`,
      ],
      { timeout: 10000 },
    )
    return
  }
  if (process.platform === 'win32') {
    const cmdArgs = cliArgs ? ['/k', cliBinary, ...cliArgs] : []
    await execute('cmd.exe', ['/c', 'start', '', '/d', project, 'cmd.exe', ...cmdArgs], {
      timeout: 10000,
    })
    return
  }
  const terminals = [
    'x-terminal-emulator',
    'gnome-terminal',
    'konsole',
    'xfce4-terminal',
    'kitty',
    'alacritty',
    'wezterm',
    'xterm',
  ]
  for (const terminal of terminals) {
    try {
      await execute('sh', ['-c', 'command -v "$1" >/dev/null 2>&1', '--', terminal], {
        timeout: 3000,
      })
      const args = cliArgs ? ['-e', cliBinary, ...cliArgs] : []
      const child = spawn(terminal, args, { cwd: project, detached: true, stdio: 'ignore' })
      child.unref()
      return
    } catch {
      // Try the next installed desktop terminal emulator.
    }
  }
  throw new Error('Could not find a desktop terminal emulator.')
}

function setupIPC() {
  handle('update-status', updateStatus)
  handle('check-updates', checkForUpdates)
  handle('automatic-updates', (enabled) => setAutomaticUpdateChecks(z.boolean().parse(enabled)))
  handle('microphone', async () => {
    const granted =
      process.platform !== 'darwin' || (await systemPreferences.askForMediaAccess('microphone'))
    if (!granted)
      throw new Error(
        'Microphone access is off. Enable Muse Desktop in System Settings → Privacy & Security → Microphone.',
      )
    microphoneEnabled = true
  })
  handle('voice', (audio) => voice.transcribe(audio, preferences.cliPath))
  handle('cancel-voice', () => voice.cancel())
  handle('bootstrap', () => ({
    preferences,
    status: muse.status,
    version: app.getVersion(),
    home: homedir(),
    platform: runtimePlatform,
  }))
  handle('connect', async () => {
    if (muse.hasActiveTurns()) {
      const { response } = await dialog.showMessageBox(window!, {
        type: 'question',
        message: 'Reconnect while Muse is working?',
        detail:
          'Reconnecting closes the current CLI host and interrupts its active turns. Saved conversations can be resumed afterward.',
        buttons: ['Reconnect', 'Cancel'],
        defaultId: 1,
        cancelId: 1,
      })
      if (response !== 0) return muse.status
    }
    return muse.connect(preferences.cliPath)
  })
  handle('choose-cli', async () => {
    const result = await dialog.showOpenDialog(window!, {
      title: 'Choose the Muse Code executable',
      properties: ['openFile', 'showHiddenFiles'],
    })
    if (result.canceled) return null
    await savePreferences({ cliPath: result.filePaths[0] })
    return result.filePaths[0]
  })
  handle('choose-project', async () => {
    const result = await dialog.showOpenDialog(window!, {
      title: 'Open a project',
      buttonLabel: 'Open project',
      properties: ['openDirectory', 'createDirectory'],
    })
    if (result.canceled) return null
    const project = await realpath(result.filePaths[0])
    await savePreferences({
      recentProjects: [
        project,
        ...preferences.recentProjects.filter((entry) => entry !== project),
      ].slice(0, 30),
    })
    return project
  })
  handle('preferences', (value) => savePreferences(preferencesPatchSchema.parse(value)))
  handle('sessions', async (cursor) => {
    const result = await muse.list(z.string().optional().parse(cursor))
    const roots = [
      ...new Set(
        result.sessions
          .filter((session) => session.kind !== 'subagent')
          .map((session) => session.workspaceRoot)
          .filter((root): root is string => Boolean(root)),
      ),
    ]
    const discovered = await Promise.all(
      roots.map(async (root) => {
        try {
          const canonical = await realpath(root)
          return (await stat(canonical)).isDirectory() ? canonical : null
        } catch {
          return null
        }
      }),
    )
    const recentProjects = [
      ...new Set([
        ...preferences.recentProjects,
        ...discovered.filter((root): root is string => root !== null),
      ]),
    ].slice(0, 30)
    if (recentProjects.length !== preferences.recentProjects.length)
      await savePreferences({ recentProjects })
    return result
  })
  handle('create', async (project, modelId, options) => {
    const root = await knownProject(project)
    await trustProject(root)
    const { worktree } =
      z.object({ worktree: z.boolean().optional() }).optional().parse(options) ?? {}
    // Muse's worktree methods need the repository recorded in its own trust.json.
    if (worktree) await recordMuseTrust(muse.configDir(), projectRoot(root))
    return muse.create(worktree ? projectRoot(root) : root, z.string().optional().parse(modelId), {
      worktree,
    })
  })
  const mcpFile = () => settingsFile(muse.configDir())
  const mcpName = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/)
  handle('mcp-list', async (): Promise<{ file: string; servers: McpServerView[] }> => ({
    file: mcpFile(),
    servers: (await listServers(mcpFile())).map((server) =>
      server.transport === 'stdio'
        ? {
            name: server.name,
            transport: server.transport,
            enabled: server.enabled,
            command: server.command,
            args: server.args,
            envNames: Object.keys(server.env),
          }
        : {
            name: server.name,
            transport: server.transport,
            enabled: server.enabled,
            url: server.url,
            headerNames: Object.keys(server.headers),
          },
    ),
  }))
  handle('mcp-add', (server) => addServer(mcpFile(), mcpServerSchema.parse(server)))
  handle('mcp-enabled', (name, enabled) =>
    setServerEnabled(mcpFile(), mcpName.parse(name), z.boolean().parse(enabled)),
  )
  handle('mcp-remove', (name) => removeServer(mcpFile(), mcpName.parse(name)))
  handle('mcp-login', async (name, logout) => {
    const server = (await listServers(mcpFile())).find(
      (entry) => entry.name === mcpName.parse(name),
    )
    if (server?.transport !== 'http') throw new Error('Only remote MCP servers use sign-in.')
    await openProjectTerminal(homedir(), ['mcp', logout === true ? 'logout' : 'login', server.name])
  })
  handle('mcp-reveal', () => shell.showItemInFolder(mcpFile()))
  handle('bridge-status', () => bridgeStatus())
  handle('bridge-reveal', async () => {
    await mkdir(bridgeRoot, { recursive: true, mode: 0o700 })
    const error = await shell.openPath(bridgeRoot)
    if (error) throw new Error(error)
  })
  handle('bridge-token', async () => {
    const token = await regenerateToken(tokenPath, tokenCipher)
    await syncBridges() // A running MCP bridge restarts so the old token stops working.
    return token
  })
  handle('bridge-copy-token', async () => {
    const token = await readToken(tokenPath, tokenCipher)
    if (!token) throw new Error('Make a token first.')
    clipboard.writeText(token)
  })
  handle('worktrees', async (project) => muse.listWorktrees(await knownProject(project)))
  handle('worktree-merge', async (project, path) =>
    mergeWorktree(projectRoot(await knownProject(project)), pathSchema.parse(path)),
  )
  handle('worktree-remove', async (project, path) => {
    const root = projectRoot(await knownProject(project))
    const target = await realpath(pathSchema.parse(path))
    const entry = (await muse.listWorktrees(root)).find((worktree) => worktree.path === target)
    const busy = entry?.sessionIds.some((sessionId) => {
      try {
        return muse.getSession(sessionId).status === 'running'
      } catch {
        return false
      }
    })
    if (busy) throw new Error('A conversation is still working in this worktree.')
    await removeWorktree(root, target)
  })
  handle('open', async (value) => {
    const view = await muse.open(id.parse(value))
    // Record a worktree session's parent project, not each worktree folder.
    const root = view.session.workspaceRoot && projectRoot(view.session.workspaceRoot)
    if (root && !preferences.recentProjects.includes(root)) {
      await savePreferences({
        recentProjects: [root, ...preferences.recentProjects].slice(0, 30),
      })
    }
    return view
  })
  handle('compact', async (value) => {
    const sessionId = id.parse(value)
    await sessionProject(sessionId)
    return muse.compact(sessionId)
  })
  handle('send', async (value) => {
    const input = z
      .object({
        sessionId: id,
        text: z.string().max(200000),
        attachments: z.array(id).max(5),
        effort: effortSchema,
        mode: z.enum(['queue', 'steer']),
      })
      .parse(value)
    if (!input.text.trim() && !input.attachments.length)
      throw new Error('Write a message or attach a file first.')
    await sessionProject(input.sessionId)
    const parts: Record<string, unknown>[] = [{ type: 'text', text: input.text }]
    let bytes = Buffer.byteLength(input.text)
    for (const attachmentId of input.attachments) {
      const chosen = selectedFiles.get(attachmentId)
      if (!chosen) throw new Error('An attachment expired. Select it again.')
      const info = await stat(chosen.path)
      if (info.size > 2 * 1024 * 1024) throw new Error('Attachments must be 2 MB or smaller.')
      const data = await readFile(chosen.path)
      bytes += data.length * 1.4
      if (bytes > 4 * 1024 * 1024)
        throw new Error('This message exceeds the 4 MB attachment limit.')
      if (chosen.attachment.kind === 'image') {
        const mediaTypes: Record<string, string> = {
          '.png': 'image/png',
          '.jpg': 'image/jpeg',
          '.jpeg': 'image/jpeg',
          '.webp': 'image/webp',
          '.gif': 'image/gif',
        }
        parts.push({
          type: 'image',
          mediaType: mediaTypes[extname(chosen.path).toLowerCase()],
          base64Data: data.toString('base64'),
        })
      } else {
        if (data.includes(0))
          throw new Error(
            `${chosen.attachment.name} is a binary file. Attach an image or a text file.`,
          )
        if (data.length > 200 * 1024) throw new Error('Text attachments must be 200 KB or smaller.')
        parts.push({
          type: 'text',
          text: `Attached file: ${chosen.attachment.name}\n\n${data.toString('utf8')}`,
        })
      }
    }
    const display = [
      input.text,
      ...input.attachments.map(
        (attachmentId) => `[Attached: ${selectedFiles.get(attachmentId)!.attachment.name}]`,
      ),
    ].join('\n')
    await muse.send(input.sessionId, parts, input.effort, input.mode, display)
    for (const attachmentId of input.attachments) selectedFiles.delete(attachmentId)
  })
  handle('cancel', (value) => muse.cancel(id.parse(value)))
  handle('rename', async (session, name) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.rename(sessionId, z.string().trim().min(1).max(200).parse(name))
  })
  handle('models', (session) => muse.models(z.string().optional().parse(session)))
  handle('set-model', async (session, model) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.setModel(sessionId, id.parse(model))
  })
  handle('approve', async (session, approval, choice) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.approve(sessionId, id.parse(approval), id.parse(choice))
  })
  handle('answer', async (session, question, answers) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.answer(sessionId, id.parse(question), z.array(answerSchema).parse(answers))
  })
  handle('cancel-question', async (session, question) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.cancelQuestion(sessionId, id.parse(question))
  })
  handle('attachments', async () => {
    const result = await dialog.showOpenDialog(window!, {
      title: 'Add context to your message',
      properties: ['openFile', 'multiSelections'],
    })
    if (result.canceled) return []
    if (result.filePaths.length > 5) throw new Error('Select up to five files at a time.')
    const attachments: Attachment[] = []
    for (const path of result.filePaths) {
      const info = await stat(path)
      if (!info.isFile() || info.size > 2 * 1024 * 1024)
        throw new Error(`${basename(path)} must be a file smaller than 2 MB.`)
      const attachment: Attachment = {
        id: randomUUID(),
        name: basename(path),
        kind: /\.(png|jpe?g|webp|gif)$/i.test(path) ? 'image' : 'text',
        size: info.size,
      }
      selectedFiles.set(attachment.id, { path, attachment })
      attachments.push(attachment)
    }
    return attachments
  })
  handle('remove-attachment', (value) => {
    selectedFiles.delete(id.parse(value))
  })
  handle('git-status', async (project) => getGitStatus(await knownProject(project)))
  handle('git-diff', async (project, path) =>
    getGitDiff(await knownProject(project), pathSchema.parse(path)),
  )
  handle('git-raw-diff', async (project, path) =>
    getRawDiff(await knownProject(project), pathSchema.parse(path)),
  )
  handle('git-revert-file', async (project, path) =>
    revertFile(await knownProject(project), pathSchema.parse(path)),
  )
  handle('git-revert-hunk', async (project, path, index) =>
    revertHunk(
      await knownProject(project),
      pathSchema.parse(path),
      z.number().int().min(0).parse(index),
    ),
  )
  handle('git-stage-file', async (project, path) =>
    stageFile(await knownProject(project), pathSchema.parse(path)),
  )
  handle('files', async (project, directory) =>
    listProjectFiles(await knownProject(project), z.string().max(4096).parse(directory)),
  )
  handle('read-file', async (project, path) =>
    readProjectFile(await knownProject(project), pathSchema.parse(path)),
  )
  handle('reveal-project', async (project) => {
    const error = await shell.openPath(await knownProject(project))
    if (error) throw new Error(error)
  })
  handle('terminal', async (projectValue, loginValue) => {
    const project = await knownProject(projectValue)
    const login = z.boolean().optional().parse(loginValue)
    await openProjectTerminal(project, login ? ['login'] : undefined)
  })
  handle('cli-terminal', async (value) => {
    const project = await knownProject(value)
    await openProjectTerminal(project, [])
  })

  handle('export', async (value) => {
    const view = muse.getView(id.parse(value))
    const title = view.session.name || view.session.title || 'Muse conversation'
    const result = await dialog.showSaveDialog(window!, {
      title: 'Export conversation',
      defaultPath: `${title.replace(/[^\p{L}\p{N} _-]/gu, '').slice(0, 80)}.md`,
      filters: [{ name: 'Markdown', extensions: ['md'] }],
    })
    if (result.canceled || !result.filePath) return null
    const content = [
      `# ${title}`,
      `Project: ${view.session.workspaceRoot || 'None'}`,
      ...view.items.map(
        (item) =>
          `## ${item.kind === 'userMessage' ? 'You' : item.kind === 'agentMessage' ? 'Muse' : item.tool || item.kind}\n\n${item.displayText || item.text || item.visibleOutput || item.fallbackText || item.summary?.join('\n') || item.objective || ''}`,
      ),
    ].join('\n\n')
    await writeFile(result.filePath, `${content}\n`, { mode: 0o600 })
    return result.filePath
  })
  handle('output', (session, item) => muse.readOutput(id.parse(session), id.parse(item)))
  handle('external', async (value) => {
    const url = new URL(z.string().max(4096).parse(value))
    if (!['https:', 'http:'].includes(url.protocol))
      throw new Error('Only web links can be opened.')
    await shell.openExternal(url.toString())
  })
  handle('window-action', (value) => {
    const action = z.enum(['minimize', 'maximize', 'close']).parse(value)
    if (!window) return
    if (action === 'minimize') window.minimize()
    else if (action === 'maximize') {
      if (window.isMaximized()) window.unmaximize()
      else window.maximize()
    } else window.close()
  })
}

function createWindow(iconPath: string) {
  const isMac = runtimePlatform === 'darwin'
  window = new BrowserWindow({
    width: 1340,
    height: 880,
    minWidth: 840,
    minHeight: 600,
    title: 'Muse Desktop',
    icon: iconPath,
    ...(isMac
      ? {
          titleBarStyle: 'hiddenInset' as const,
          trafficLightPosition: { x: 20, y: 22 },
          vibrancy: 'sidebar' as const,
          visualEffectState: 'active' as const,
        }
      : {
          frame: false,
          autoHideMenuBar: true,
        }),
    backgroundColor:
      preferences.theme === 'muse'
        ? '#052467'
        : preferences.theme === 'moonlight'
          ? '#161a22'
          : '#f8f7f4',
    show: false,
    webPreferences: {
      preload: join(directory, '../preload/index.cjs'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      webSecurity: true,
      spellcheck: true,
    },
  })
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  window.webContents.on('will-navigate', (event) => event.preventDefault())
  window.webContents.on('will-attach-webview', (event) => event.preventDefault())
  window.webContents.session.setPermissionRequestHandler(
    (contents, permission, callback, details) => {
      callback(
        microphoneEnabled &&
          contents === window?.webContents &&
          permission === 'media' &&
          details.isMainFrame &&
          'mediaTypes' in details &&
          details.mediaTypes?.length === 1 &&
          details.mediaTypes[0] === 'audio',
      )
    },
  )
  window.webContents.session.setPermissionCheckHandler(
    (contents, permission, _origin, details) =>
      microphoneEnabled &&
      contents === window?.webContents &&
      permission === 'media' &&
      details.isMainFrame &&
      details.mediaType === 'audio',
  )
  window.once('ready-to-show', () => window?.show())
  window.on('close', (event) => {
    if (!quitting && process.platform === 'darwin') {
      event.preventDefault()
      window?.hide()
    }
  })
  window.on('closed', () => {
    window = undefined
  })
  if (process.env.ELECTRON_RENDERER_URL && !app.isPackaged)
    void window.loadURL(process.env.ELECTRON_RENDERER_URL)
  else void window.loadFile(rendererPath)
}

function setupMenu() {
  const action = (name: 'new' | 'open' | 'search' | 'settings' | 'sidebar') => () =>
    emit({ type: 'menu', action: name })
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      {
        label: 'Muse Desktop',
        submenu: [
          { role: 'about' },
          {
            label: 'Check for Updates…',
            enabled: updateStatus().available,
            click: () => {
              void Promise.resolve()
                .then(() => checkForUpdates())
                .catch((error: unknown) => {
                  dialog.showErrorBox('Software updates', messageOf(error))
                })
            },
          },
          { type: 'separator' },
          { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: action('settings') },
          ...(process.platform === 'darwin'
            ? ([
                { type: 'separator' },
                { role: 'services' },
                { type: 'separator' },
                { role: 'hide' },
                { role: 'hideOthers' },
                { role: 'unhide' },
              ] as const)
            : []),
          { type: 'separator' },
          { role: 'quit' },
        ],
      },
      {
        label: 'File',
        submenu: [
          { label: 'New conversation', accelerator: 'CmdOrCtrl+N', click: action('new') },
          { label: 'Open project…', accelerator: 'CmdOrCtrl+O', click: action('open') },
          { type: 'separator' },
          { role: 'close' },
        ],
      },
      { role: 'editMenu' },
      {
        label: 'View',
        submenu: [
          { label: 'Command menu', accelerator: 'CmdOrCtrl+K', click: action('search') },
          { label: 'Toggle sidebar', accelerator: 'CmdOrCtrl+B', click: action('sidebar') },
          { type: 'separator' },
          { role: 'resetZoom' },
          { role: 'zoomIn' },
          { role: 'zoomOut' },
          { type: 'separator' },
          { role: 'togglefullscreen' },
          ...(!app.isPackaged ? [{ role: 'toggleDevTools' as const }] : []),
        ],
      },
      { role: 'windowMenu' },
      {
        role: 'help',
        submenu: [
          {
            label: 'Muse Desktop on GitHub (unofficial)',
            click: () => {
              void shell.openExternal('https://github.com/robzilla1738/muse-desktop')
            },
          },
          {
            label: 'Muse Code documentation',
            click: () => {
              void shell.openExternal('https://dev.meta.ai/docs/muse-code')
            },
          },
        ],
      },
    ]),
  )
}

if (!app.requestSingleInstanceLock()) app.quit()
else {
  app.on('second-instance', () => {
    window?.show()
    window?.focus()
  })
  app.on('activate', () => {
    if (window) window.show()
    else {
      const iconPath = app.isPackaged
        ? join(process.resourcesPath, 'app.asar/resources/icon.png')
        : resolve(directory, '../../resources/icon.png')
      createWindow(iconPath)
    }
  })
  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit()
  })
  app.on('before-quit', (event) => {
    if (quitting) return
    event.preventDefault()
    if (muse.hasActiveTurns() && window) {
      const response = dialog.showMessageBoxSync(window, {
        type: 'question',
        message: 'Quit while Muse is working?',
        detail:
          'Quitting interrupts active turns. Close the window to keep Muse working in the background.',
        buttons: ['Quit', 'Keep working'],
        defaultId: 1,
        cancelId: 1,
      })
      if (response !== 0) return
    }
    quitting = true
    void Promise.all([syncBridges(), muse.close(), preferenceWrites, voice.cancel()]).then(
      () => app.quit(),
      (error: unknown) => {
        dialog.showErrorBox('Muse could not shut down cleanly', messageOf(error))
        app.quit()
      },
    )
  })
  void app
    .whenReady()
    .then(async () => {
      app.setName('Muse Desktop')
      await mkdir(app.getPath('userData'), { recursive: true })
      preferences = await readPreferences(preferencePath)
      nativeTheme.themeSource =
        preferences.theme === 'system'
          ? 'system'
          : ['moonlight', 'muse', 'plush'].includes(preferences.theme)
            ? 'dark'
            : 'light'
      const iconPath = app.isPackaged
        ? join(process.resourcesPath, 'app.asar/resources/icon.png')
        : resolve(directory, '../../resources/icon.png')
      if (process.platform === 'darwin') app.dock?.setIcon(nativeImage.createFromPath(iconPath))
      app.setAboutPanelOptions({
        applicationName: 'Muse Desktop',
        applicationVersion: app.getVersion(),
        copyright:
          '© 2026 Robert Courson. Unofficial community app. Not affiliated with, endorsed by, or sponsored by Meta.',
      })
      setupIPC()
      initializeUpdates()
      setupMenu()
      createWindow(iconPath)
      await muse.connect(preferences.cliPath)
      await syncBridges()
    })
    .catch((error: unknown) => {
      dialog.showErrorBox('Could not start Muse Desktop', messageOf(error))
      app.quit()
    })
}
