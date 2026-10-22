import { randomBytes } from 'node:crypto'
import { mkdir, realpath, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import { z } from 'zod'
import {
  answerSchema,
  effortSchema,
  preferencesPatchSchema,
  preferencesSchema,
  type AppEvent,
  type McpServerView,
  type Preferences,
} from '../shared/protocol'
import { listProjectFiles, readProjectFile } from '../main/files'
import {
  getGitDiff,
  getGitStatus,
  getRawDiff,
  revertFile,
  revertHunk,
  stageFile,
} from '../main/git'
import {
  addServer,
  listServers,
  mcpServerSchema,
  removeServer,
  setServerEnabled,
  settingsFile,
} from '../main/mcp-config'
import type { AgentApi, AgentPolicy } from '../main/agent-api'
import type { MuseHost } from '../main/muse-host'
import { readPreferences, writePreferences } from '../main/preferences'
import { mergeWorktree, removeWorktree } from '../main/worktrees'
import { projectRoot, worktreeParent } from '../shared/worktree'
import { Bridges, type BridgeFactories } from './bridges'
import { openInTerminal, terminalCommand } from './terminal'
import { HEADLESS_PROTOCOL, type Ask, type Method } from './wire'

// mMac's backend methods and the state they share. src/headless/server.ts owns
// stdin, stdout and the quit path, so unit tests can drive these methods with a
// fake MuseHost (tests/unit/headless-backend.test.ts). This repeats the wiring of
// src/main/index.ts instead of sharing it, so upstream syncs of index.ts stay
// clean; tests/unit/headless-parity.test.ts catches drift between the two.

/** The parts of MuseHost the methods use. */
export type Muse = Pick<
  MuseHost,
  | 'status'
  | 'connect'
  | 'list'
  | 'create'
  | 'open'
  | 'send'
  | 'cancel'
  | 'getSession'
  | 'hasActiveTurns'
  | 'rename'
  | 'models'
  | 'setModel'
  | 'approve'
  | 'answer'
  | 'cancelQuestion'
  | 'readOutput'
  | 'listWorktrees'
  | 'configDir'
>

export type BackendDeps = {
  muse: Muse
  /** Shows a native alert in mMac and resolves with the chosen button's index, or -1. */
  ask: (ask: Ask) => Promise<number>
  emit: (event: AppEvent) => void
  version: string
  /** True once the quit path has started. */
  quitting: () => boolean
  /** Starts the quit path. The server runs it after the current Reply is written. */
  quit: (code: number) => void
  /** Opens Terminal and runs one command line. Tests record it instead. */
  openTerminal?: (command: string) => Promise<void>
  /** Builds the AgentApi behind both bridges. Without it, the backend runs no bridges. */
  agent?: (policy: AgentPolicy) => AgentApi
  /** The bridges to run. Tests pass fakes; the default is the real FileBridge and McpBridge. */
  bridgeFactories?: BridgeFactories
}

export function createBackend({
  muse,
  ask,
  emit,
  version,
  quitting,
  quit,
  openTerminal = openInTerminal,
  agent,
  bridgeFactories,
}: BackendDeps) {
  const id = z.string().min(1).max(200)
  const pathSchema = z.string().min(1).max(4096)
  const methods = new Map<string, Method>()
  let greeted = false
  let starting = false
  let preferences: Preferences | undefined
  let preferencePath = ''
  let preferenceWrites: Promise<void> = Promise.resolve()
  let bridges: Bridges | undefined

  // Register every method with a literal call to method, name in quotes as the first argument:
  // tests/unit/headless-parity.test.ts finds them by that pattern.
  function method(name: string, action: Method) {
    methods.set(name, async (...args: unknown[]) => {
      if (name !== 'hello' && !greeted) throw new Error('Send hello first.')
      if (!['hello', 'start', 'shutdown'].includes(name) && !preferences)
        throw new Error('Send start first.')
      return action(...args)
    })
  }

  function current() {
    if (!preferences) throw new Error('Send start first.')
    return preferences
  }

  async function savePreferences(patch: Partial<Preferences>) {
    const write = preferenceWrites.then(async () => {
      const snapshot = preferencesSchema.parse({ ...current(), ...patch })
      await writePreferences(preferencePath, snapshot)
      preferences = snapshot
      emit({ type: 'preferences', preferences: snapshot })
      if (Object.keys(patch).some((key) => key.startsWith('bridge'))) void bridges?.sync()
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
      current().recentProjects.map(async (entry) => {
        try {
          return await realpath(entry)
        } catch {
          return entry
        }
      }),
    )
    // A Muse-created worktree (`<project>/.muse/worktrees/<name>`) belongs to its project.
    const candidates = [project, worktreeParent(project)].filter((entry) => entry !== null)
    if (!resolvedRecent.some((entry) => candidates.includes(entry)))
      throw new Error('Choose this project using Open project first.')
    return project
  }

  async function trustProject(project: string) {
    const { trustedProjects } = current()
    if (trustedProjects.includes(project)) return
    const parent = worktreeParent(project)
    if (parent && trustedProjects.includes(parent)) return
    const choice = await ask({
      kind: 'confirm',
      title: 'Trust this project?',
      message: `Work with Muse in “${basename(project)}”?`,
      detail: `Muse can read and edit this project and use its skills, instructions, and hooks. Its existing sandbox and tool approval settings remain active.\n\n${project}\n\nOnly continue with a project you trust.`,
      buttons: ['Trust project', 'Cancel'],
    })
    if (choice !== 0) throw new Error('Project trust was cancelled. No session was started.')
    await savePreferences({ trustedProjects: [...current().trustedProjects, project] })
  }

  async function sessionProject(sessionId: string) {
    const session = muse.getSession(sessionId)
    if (!session.workspaceRoot) throw new Error('This conversation has no project folder.')
    const project = await realpath(session.workspaceRoot)
    await trustProject(project)
    return project
  }

  method('hello', (value) => {
    const theirs = z.number().int().parse(value)
    if (theirs !== HEADLESS_PROTOCOL) {
      quit(2)
      throw new Error(
        `mMac speaks backend protocol ${theirs}, but this backend speaks ${HEADLESS_PROTOCOL}. Build mMac and the backend from the same checkout.`,
      )
    }
    greeted = true
    return { protocol: HEADLESS_PROTOCOL, version }
  })

  method('start', async (value) => {
    if (quitting()) throw new Error('The backend is quitting.')
    if (starting || preferences) throw new Error('The backend has already started.')
    starting = true
    try {
      // The bridge token comes from mMac's login Keychain. It stays in memory, in Bridges, only.
      const { dataFolder, bridgeToken } = z
        .object({ dataFolder: pathSchema, bridgeToken: z.string().max(256).optional() })
        .parse(value)
      await mkdir(dataFolder, { recursive: true, mode: 0o700 })
      preferencePath = join(dataFolder, 'preferences.json')
      preferences = await readPreferences(preferencePath)
      if (agent) {
        // Bridges: other agents drive Muse Code through mMac, limited to projects mMac
        // already knows and trusts, as in src/main/index.ts.
        const api = agent({
          resolveProject: async (path) => {
            const project = await knownProject(path)
            const trusted = current().trustedProjects
            if (!trusted.includes(project) && !trusted.includes(projectRoot(project)))
              throw new Error('That project is not trusted in mMac. Open it there first.')
            return project
          },
        })
        bridges = new Bridges({
          root: join(dataFolder, 'bridge'),
          token: bridgeToken ?? '',
          api,
          preferences: current,
          factories: bridgeFactories,
        })
      }
    } catch (error) {
      starting = false
      throw error
    }
    if (quitting()) throw new Error('The backend is quitting.')
    const status = await muse.connect(preferences.cliPath)
    await bridges?.sync() // As Electron does, after the first connect.
    return { preferences, status }
  })

  method('connect', async () => {
    if (quitting()) throw new Error('The backend is quitting.')
    if (muse.hasActiveTurns()) {
      const choice = await ask({
        kind: 'confirm',
        title: 'Reconnect while Muse is working?',
        message:
          'Reconnecting closes the current CLI host and interrupts its active turns. Saved conversations can be resumed afterward.',
        buttons: ['Reconnect', 'Cancel'],
      })
      if (choice !== 0) return muse.status
    }
    if (quitting()) throw new Error('The backend is quitting.')
    return muse.connect(current().cliPath)
  })

  method('add-project', async (value) => {
    const project = await realpath(pathSchema.parse(value))
    if (!(await stat(project)).isDirectory()) throw new Error('Choose a folder, not a file.')
    await savePreferences({
      recentProjects: [
        project,
        ...current().recentProjects.filter((entry) => entry !== project),
      ].slice(0, 30),
    })
    return project
  })

  method('sessions', async (cursor) => {
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
        ...current().recentProjects,
        ...discovered.filter((root): root is string => root !== null),
      ]),
    ].slice(0, 30)
    if (recentProjects.length !== current().recentProjects.length)
      await savePreferences({ recentProjects })
    return result
  })

  method('create', async (project, modelId, options) => {
    const root = await knownProject(project)
    await trustProject(root)
    const { worktree } =
      z.object({ worktree: z.boolean().optional() }).optional().parse(options) ?? {}
    return muse.create(root, z.string().nullish().parse(modelId) ?? undefined, { worktree })
  })

  method('open', async (value) => {
    const view = await muse.open(id.parse(value))
    // Record a worktree session's parent project, not each worktree folder.
    const root = view.session.workspaceRoot && projectRoot(view.session.workspaceRoot)
    if (root && !current().recentProjects.includes(root))
      await savePreferences({ recentProjects: [root, ...current().recentProjects].slice(0, 30) })
    return view
  })

  method('send', async (value) => {
    // Text only. Attachments come with the attachment methods in M4.
    const input = z
      .object({
        sessionId: id,
        text: z.string().max(200000),
        attachments: z.array(id).max(0),
        effort: effortSchema,
        mode: z.enum(['queue', 'steer']),
      })
      .parse(value)
    if (!input.text.trim()) throw new Error('Write a message first.')
    await sessionProject(input.sessionId)
    await muse.send(
      input.sessionId,
      [{ type: 'text', text: input.text }],
      input.effort,
      input.mode,
      input.text,
    )
  })

  method('cancel', (value) => muse.cancel(id.parse(value)))

  method('preferences', (value) => savePreferences(preferencesPatchSchema.parse(value)))

  method('rename', async (session, name) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.rename(sessionId, z.string().trim().min(1).max(200).parse(name))
  })

  method('models', (session) => muse.models(z.string().optional().parse(session)))

  method('set-model', async (session, model) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.setModel(sessionId, id.parse(model))
  })

  method('approve', async (session, approval, choice) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.approve(sessionId, id.parse(approval), id.parse(choice))
  })

  method('answer', async (session, question, answers) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.answer(sessionId, id.parse(question), z.array(answerSchema).parse(answers))
  })

  method('cancel-question', async (session, question) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.cancelQuestion(sessionId, id.parse(question))
  })

  method('output', (session, item) => muse.readOutput(id.parse(session), id.parse(item)))

  // The inspector, as src/main/index.ts registers it. Like Electron, these check that the
  // project is known but do not ask to trust it.
  method('git-status', async (project) => getGitStatus(await knownProject(project)))

  method('git-diff', async (project, path) =>
    getGitDiff(await knownProject(project), pathSchema.parse(path)),
  )

  method('git-raw-diff', async (project, path) =>
    getRawDiff(await knownProject(project), pathSchema.parse(path)),
  )

  method('git-revert-file', async (project, path) =>
    revertFile(await knownProject(project), pathSchema.parse(path)),
  )

  method('git-revert-hunk', async (project, path, index) =>
    revertHunk(
      await knownProject(project),
      pathSchema.parse(path),
      z.number().int().min(0).parse(index),
    ),
  )

  method('git-stage-file', async (project, path) =>
    stageFile(await knownProject(project), pathSchema.parse(path)),
  )

  method('files', async (project, directory) =>
    listProjectFiles(await knownProject(project), z.string().max(4096).parse(directory)),
  )

  method('read-file', async (project, path) =>
    readProjectFile(await knownProject(project), pathSchema.parse(path)),
  )

  method('worktrees', async (project) => muse.listWorktrees(await knownProject(project)))

  method('worktree-merge', async (project, path) =>
    mergeWorktree(projectRoot(await knownProject(project)), pathSchema.parse(path)),
  )

  method('worktree-remove', async (project, path) => {
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

  // MCP servers, as src/main/index.ts registers them: direct edits of Muse's settings.json.
  const mcpFile = () => settingsFile(muse.configDir())
  const mcpName = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/)

  method('mcp-list', async (): Promise<{ file: string; servers: McpServerView[] }> => ({
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

  method('mcp-add', (server) => addServer(mcpFile(), mcpServerSchema.parse(server)))

  method('mcp-enabled', (name, enabled) =>
    setServerEnabled(mcpFile(), mcpName.parse(name), z.boolean().parse(enabled)),
  )

  method('mcp-remove', (name) => removeServer(mcpFile(), mcpName.parse(name)))

  method('mcp-login', async (name, logout) => {
    const server = (await listServers(mcpFile())).find(
      (entry) => entry.name === mcpName.parse(name),
    )
    if (server?.transport !== 'http') throw new Error('Only remote MCP servers use sign-in.')
    await openTerminal(
      terminalCommand(homedir(), muse.status.path || 'muse', [
        'mcp',
        logout === true ? 'logout' : 'login',
        server.name,
      ]),
    )
  })

  // The bridges, as src/main/index.ts registers them. mMac reveals the folder and copies the
  // token itself; the token goes back to mMac, which stores it in the login Keychain.
  function running() {
    if (!bridges) throw new Error('This backend has no bridges.')
    return bridges
  }

  method('bridge-status', () => running().status())

  method('bridge-token', async () => {
    const token = randomBytes(24).toString('base64url')
    running().setToken(token)
    await running().sync() // A running MCP bridge restarts, so the old token stops working.
    return token
  })

  method('shutdown', async () => {
    if (muse.hasActiveTurns()) {
      const choice = await ask({
        kind: 'confirm',
        title: 'Quit while Muse is working?',
        message: 'Quitting interrupts active turns.',
        buttons: ['Quit', 'Keep working'],
      })
      if (choice !== 0) return false
    }
    quit(0)
    return true
  })

  return {
    methods,
    /** Settles after every preference write queued so far. */
    preferenceWrites: () => preferenceWrites,
    /** Stops both bridges for good: the quit path. */
    stopBridges: () => bridges?.stop() ?? Promise.resolve(),
  }
}
