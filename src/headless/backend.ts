import { randomBytes } from 'node:crypto'
import { constants } from 'node:fs'
import { mkdir, open, realpath, rm, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, isAbsolute, join } from 'node:path'
import { z } from 'zod'
import {
  answerSchema,
  approvalModeSchema,
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
  splitHunks,
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
import { validateVoiceAudio, VoiceTranscriber } from '../main/voice'
import { mergeWorktree, removeWorktree } from '../main/worktrees'
import { MAX_VOICE_BYTES } from '../shared/voice'
import { projectRoot, worktreeParent } from '../shared/worktree'
import { Attachments } from './attachments'
import { Bridges, type BridgeFactories } from './bridges'
import { exportMarkdown, exportTitle } from './export'
import { MissingFolder, plainError, realFolder } from './plain-errors'
import { prList, prMerge, prMergeWhenReady, prStatus } from './pull-request'
import { revertExpectedHunk, STALE_HUNK } from './revert-hunk'
import { Scheduler } from './schedule'
import type { Schedule } from './schedule-rules'
import { folderCommand, openInTerminal, terminalCommand } from './terminal'
import { HEADLESS_PROTOCOL, type Ask, type Method } from './wire'

// mMac's backend methods and the state they share. src/headless/server.ts owns
// stdin, stdout and the quit path, so unit tests can drive these methods with a
// fake MuseHost (tests/unit/headless-backend.test.ts). The wiring began as a copy
// of Electron's src/main/index.ts, which M4a removed; docs/decisions.md names the
// last commit that has it. tests/unit/headless-parity.test.ts pins the method list.

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
  | 'compact'
  | 'getSession'
  | 'getView'
  | 'hasActiveTurns'
  | 'rename'
  | 'models'
  | 'setModel'
  | 'setApprovalMode'
  | 'sideChat'
  | 'runShell'
  | 'approve'
  | 'answer'
  | 'cancelQuestion'
  | 'readOutput'
  | 'listWorktrees'
  | 'configDir'
  | 'limits'
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
  /** Runs `muse voice transcribe`. Tests pass a fake; the default is src/main/voice.ts's. */
  voice?: { transcribe(data: Buffer, cliPath: string): Promise<string>; cancel(): Promise<void> }
  /** Scheduled tasks. Tests pass `{ timer: false }` and call the methods; the default ticks every minute. */
  scheduler?: { timer?: boolean; now?: () => number; tz?: string }
  /** The environment gh runs in. Tests point PATH at a fake gh; the default is the backend's. */
  ghEnv?: NodeJS.ProcessEnv
  /** Folders added to gh's PATH. Tests pass [] so the real gh is never found; the default is Homebrew's. */
  ghFolders?: string[]
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
  voice = new VoiceTranscriber(),
  scheduler: schedulerOptions = {},
  ghEnv,
  ghFolders,
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
  let scheduler: Scheduler | undefined
  // Files chosen for the next message. Memory only, as in Electron.
  const attachments = new Attachments()

  // Register every method with a literal call to method, name in quotes as the first argument:
  // tests/unit/headless-parity.test.ts finds them by that pattern.
  function method(name: string, action: Method) {
    methods.set(name, async (...args: unknown[]) => {
      if (name !== 'hello' && !greeted) throw new Error('Send hello first.')
      if (!['hello', 'start', 'shutdown'].includes(name) && !preferences)
        throw new Error('Send start first.')
      try {
        return await action(...args)
      } catch (error) {
        // Raw fs text and Muse's rejection codes become plain sentences: ./plain-errors.ts.
        throw plainError(error)
      }
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
    const project = await realFolder(pathSchema.parse(value))
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
    const project = await realFolder(session.workspaceRoot)
    await trustProject(project)
    return project
  }

  // Scheduled runs whose turn mMac has not yet seen start: send returns before turn/started
  // arrives, and the Scheduler asks isRunning right after start returns. Each entry keeps the
  // session's updatedAt from before the send (turn/completed moves it) and when it started.
  const scheduledTurns = new Map<string, { updatedAt: string; since: number }>()
  const TURN_START_LIMIT = 10 * 60_000
  const schedulerNow = () => (schedulerOptions.now ?? Date.now)()
  /** A Node file error (it would name a path) rather than a sentence for the person. */
  const systemError = (error: unknown) =>
    typeof (error as { code?: unknown } | null)?.code === 'string' &&
    /^E[A-Z]+$/.test((error as { code: string }).code)

  const START_FAILED = 'mMac could not start this scheduled task.'
  /** A reason the person can act on, shown after START_FAILED. */
  class StartProblem extends Error {}

  /**
   * A scheduled run: no Ask, so the folder must already be trusted. History shows START_FAILED,
   * with a plain reason where one is known; Muse's own text goes to stderr only.
   */
  async function startScheduled(schedule: Schedule) {
    try {
      return await startScheduledRun(schedule)
    } catch (error) {
      if (error instanceof StartProblem) throw new Error(`${START_FAILED} ${error.message}`)
      console.error(
        `mMac could not start scheduled task ${schedule.id}: ${error instanceof Error ? error.message : String(error)}`,
      )
      throw new Error(START_FAILED)
    }
  }

  async function startScheduledRun(schedule: Schedule) {
    if (quitting()) throw new StartProblem('mMac is quitting.')
    const folder = await knownProject(schedule.folder).catch((error: unknown) => {
      // knownProject's own refusal is already a sentence; a Node error would name a path. A
      // missing folder keeps this task's own sentence, not realFolder's general one.
      throw new StartProblem(
        systemError(error) || error instanceof MissingFolder
          ? 'The folder for this task no longer exists, or mMac cannot open it.'
          : error instanceof Error
            ? error.message
            : String(error),
      )
    })
    const trusted = current().trustedProjects
    if (!trusted.includes(folder) && !trusted.includes(projectRoot(folder)))
      throw new StartProblem(
        'The folder is not trusted in mMac. Open it and send a message there first.',
      )
    const view = await muse.create(folder, schedule.modelId ?? undefined, {
      worktree: schedule.worktree,
    })
    const sessionId = view.session.sessionId
    await muse.setApprovalMode(sessionId, schedule.approvalMode)
    scheduledTurns.set(sessionId, { updatedAt: view.session.updatedAt, since: schedulerNow() })
    try {
      await muse.send(
        sessionId,
        [{ type: 'text', text: schedule.prompt }],
        current().reasoningEffort,
        'queue',
        schedule.prompt,
      )
    } catch (error) {
      scheduledTurns.delete(sessionId)
      throw error
    }
    return sessionId
  }

  /** True while the session waits for the person: a tool approval or a question. */
  function scheduledWaiting(sessionId: string) {
    try {
      const view = muse.getView(sessionId)
      return view.approvals.length > 0 || view.questions.length > 0
    } catch {
      return false
    }
  }

  /** True while the turn runs, or was sent and has not yet started. A gone session is not. */
  function scheduledRunning(sessionId: string) {
    let session
    try {
      session = muse.getSession(sessionId)
    } catch {
      scheduledTurns.delete(sessionId)
      return false
    }
    if (session.activeTurnId != null || session.status === 'running') {
      scheduledTurns.delete(sessionId)
      return true
    }
    const waiting = scheduledTurns.get(sessionId)
    // A clock that stepped back makes the wait negative: count that as expired too.
    const waited = waiting ? schedulerNow() - waiting.since : -1
    if (
      waiting &&
      session.updatedAt === waiting.updatedAt &&
      waited >= 0 &&
      waited < TURN_START_LIMIT
    )
      return true
    scheduledTurns.delete(sessionId)
    return false
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
      scheduler = new Scheduler({
        file: join(dataFolder, 'schedules.json'),
        now: schedulerOptions.now,
        tz: schedulerOptions.tz,
        start: startScheduled,
        isRunning: scheduledRunning,
        isWaiting: scheduledWaiting,
        emit,
      })
      await scheduler.load()
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
    if (schedulerOptions.timer !== false && !quitting()) scheduler?.start()
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
    const project = await realFolder(pathSchema.parse(value))
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
    const input = z
      .object({
        sessionId: id,
        text: z.string().max(200000),
        attachments: z.array(id),
        effort: effortSchema,
        mode: z.enum(['queue', 'steer']),
      })
      .parse(value)
    if (input.attachments.length > 5)
      throw new Error('You can attach up to five files per message.')
    if (!input.text.trim() && !input.attachments.length)
      throw new Error('Write a message or attach a file first.')
    await sessionProject(input.sessionId)
    const { parts, display } = await attachments.build(input.text, input.attachments)
    await muse.send(input.sessionId, parts, input.effort, input.mode, display)
    // Only now: after any failure the ids stay valid, so mMac can send them again.
    attachments.forget(input.attachments)
  })

  // Attachments, as src/main/index.ts registers them. mMac shows the panel and sends the paths.
  method('attachments', (value) => {
    const paths = z.array(pathSchema).parse(value)
    if (paths.some((path) => !isAbsolute(path)))
      throw new Error('Choose files by their full paths.')
    return attachments.register(paths)
  })

  method('remove-attachment', (value) => {
    attachments.remove(id.parse(value))
  })

  method('cancel', (value) => muse.cancel(id.parse(value)))

  method('compact', async (value) => {
    const sessionId = id.parse(value)
    await sessionProject(sessionId)
    return muse.compact(sessionId)
  })

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

  // Muse's approval mode for one conversation. It applies to Muse's next action.
  method('set-approval-mode', async (session, mode) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.setApprovalMode(sessionId, approvalModeSchema.parse(mode))
  })

  // A side session seeded from the conversation. mMac shows it in a sheet; it never joins the sidebar.
  method('side-chat', async (session) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.sideChat(sessionId)
  })

  // The composer's `!` escape: a shell command in the conversation's folder.
  method('shell', async (session, command) => {
    const sessionId = id.parse(session)
    await sessionProject(sessionId)
    return muse.runShell(sessionId, z.string().min(1).max(10000).parse(command))
  })

  // The subscription's limits as Muse last observed them; `usage-changed` carries each new value.
  method('usage', () => muse.limits)

  // Scheduled tasks, as Desktop's Scheduled page. src/headless/schedule.ts keeps them.
  function schedules() {
    if (!scheduler) throw new Error('Send start first.')
    return scheduler
  }
  /** A failed store write names a temporary file; the person sees a sentence instead. */
  async function plainly<T>(action: () => Promise<T>) {
    try {
      return await action()
    } catch (error) {
      if (systemError(error)) throw new Error('mMac could not save scheduled tasks.')
      throw error
    }
  }

  method('schedule-list', () => schedules().list())

  method('schedule-save', async (value) => {
    const input = z.object({ folder: pathSchema }).passthrough().parse(value)
    await knownProject(input.folder)
    return plainly(() => schedules().save(value))
  })

  method('schedule-remove', (value) => plainly(() => schedules().remove(id.parse(value))))

  method('schedule-run', (value) => plainly(() => schedules().runNow(id.parse(value))))

  method('schedule-enabled', (value, enabled) =>
    plainly(() => schedules().setEnabled(id.parse(value), z.boolean().parse(enabled))),
  )

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

  // Markdown export, as src/main/index.ts's `export` handler writes it. mMac shows the save
  // panel and sends the path; like Electron, this needs the conversation open, not trusted.
  method('export', async (session, path, fallback) => {
    const view = muse.getView(id.parse(session))
    const file = pathSchema.parse(path)
    if (!isAbsolute(file)) throw new Error('Choose a full path for the exported file.')
    // A long sidebar title is shortened, by code points so an emoji stays whole, not a reason
    // to refuse the export.
    const long = z.string().nullish().parse(fallback)
    const title = exportTitle(
      view.session,
      long ? Array.from(long).slice(0, 200).join('') : undefined,
    )
    // The open call sets 0600 on a new file; a file the person replaced would keep its old mode,
    // as in Electron, so mMac sets it on the open handle before any content lands.
    const handle = await open(file, 'w', 0o600)
    try {
      await handle.chmod(0o600)
      await handle.writeFile(exportMarkdown(view, title))
    } finally {
      await handle.close()
    }
    return file
  })

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

  method('git-revert-hunk', async (project, path, index, expected) => {
    const root = await knownProject(project)
    const file = pathSchema.parse(path)
    const at = z.number().int().min(0).parse(index)
    const text = z.string().max(5_000_000).optional().parse(expected)
    if (text === undefined) return revertHunk(root, file, at)
    // mMac sends the hunk it showed. An outside edit may have moved the hunks since, so check
    // first, then reverse that exact text: git refuses it if the file changes in between.
    const { header, hunks } = splitHunks(await getRawDiff(root, file))
    if (hunks[at] !== text) throw new Error(STALE_HUNK)
    return revertExpectedHunk(root, header, text)
  })

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
    const target = await realFolder(pathSchema.parse(path))
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

  // The inspector's footer, as src/main/index.ts's `terminal` and `cli-terminal` open it. mMac
  // reveals the folder in Finder itself.
  // Electron's unused `login` argument is left out on purpose.
  method('terminal', async (project) => openTerminal(folderCommand(await knownProject(project))))

  // Opens the CLI without a trust check, as Electron does.
  method('cli-terminal', async (project) =>
    openTerminal(terminalCommand(await knownProject(project), muse.status.path || 'muse', [])),
  )

  // The PR monitor and the change cards, through gh. Reads need no trust Ask; merges ask first.
  const gh = { env: ghEnv, folders: ghFolders }
  const prNumber = z.number().int().positive().max(Number.MAX_SAFE_INTEGER)

  async function conversationFolder(sessionId: string) {
    const root = muse.getSession(sessionId).workspaceRoot
    if (!root) throw new Error('This conversation has no project folder.')
    return knownProject(root)
  }

  method('pr-status', async (session) => prStatus(await conversationFolder(id.parse(session)), gh))

  method('pr-list', async (project) => prList(await knownProject(project), gh))

  method('pr-merge', async (project, value) => {
    const folder = await knownProject(project)
    const number = prNumber.parse(value)
    const choice = await ask({
      kind: 'confirm',
      title: `Accept pull request ${number}?`,
      message:
        'mMac merges it into its base branch with gh, as one squashed commit. GitHub keeps the branch.',
      buttons: ['Accept', 'Cancel'],
    })
    if (choice !== 0) return false
    await prMerge(folder, number, gh)
    return true
  })

  method('pr-merge-when-ready', async (session, value) => {
    const folder = await conversationFolder(id.parse(session))
    const number = prNumber.parse(value)
    const choice = await ask({
      kind: 'confirm',
      title: `Merge pull request ${number} when its checks pass?`,
      message: 'GitHub merges it as one squashed commit once every required check passes.',
      buttons: ['Merge when ready', 'Cancel'],
    })
    if (choice !== 0) return false
    await prMergeWhenReady(folder, number, gh)
    return true
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

  // Voice, as src/main/index.ts registers it, with the audio as a file instead of bytes: the
  // longest clip is about 3.8 MB, too much for one JSON line. mMac writes the WAV to its own
  // temp folder; the backend checks it, reads it and deletes it before transcribing.
  const NOT_A_CLIP = 'The recording is not a supported PCM audio clip. Please record it again.'
  const TOO_LONG = 'Record between a moment and two minutes of speech.'

  /**
   * Opens the recording once and checks and reads through that handle. O_NOFOLLOW refuses a
   * symlink, O_NONBLOCK keeps a FIFO from blocking the open. Nothing is deleted unless the path
   * opened as a regular file; after that the file is deleted whatever the checks say. A raw fs
   * error (it would name the temp path) never reaches the person.
   */
  async function takeRecording(value: unknown) {
    const path = pathSchema.parse(value)
    if (!isAbsolute(path)) throw new Error('Choose a full path for the recording.')
    if (!/\.wav$/i.test(path)) throw new Error(NOT_A_CLIP)
    const coded = (error: unknown) => typeof (error as { code?: unknown } | null)?.code === 'string'
    const handle = await open(
      path,
      constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW,
    ).catch((error) => {
      throw coded(error) ? new Error(NOT_A_CLIP) : error
    })
    try {
      const info = await handle.stat().catch((error) => {
        throw coded(error) ? new Error(NOT_A_CLIP) : error
      })
      if (!info.isFile()) throw new Error(NOT_A_CLIP)
      try {
        if (info.size > MAX_VOICE_BYTES) throw new Error(TOO_LONG)
        // At most one byte past the limit, so a file that grew after the stat cannot fill memory.
        const buffer = Buffer.alloc(Math.min(info.size, MAX_VOICE_BYTES) + 1)
        let length = 0
        while (length < buffer.length) {
          const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length)
          if (!bytesRead) break
          length += bytesRead
        }
        if (length > MAX_VOICE_BYTES) throw new Error(TOO_LONG)
        return validateVoiceAudio(buffer.subarray(0, length))
      } catch (error) {
        throw coded(error) ? new Error(NOT_A_CLIP) : error
      } finally {
        await rm(path, { force: true }).catch(() => {})
      }
    } finally {
      await handle.close()
    }
  }

  // Raised by every cancel. A cancel that lands while takeRecording still reads finds no active
  // transcription to abort, so voice compares this count before and after the read.
  let voiceCancels = 0
  const cancelVoice = () => {
    voiceCancels += 1
    return voice.cancel()
  }

  method('voice', async (value) => {
    const cancels = voiceCancels
    const data = await takeRecording(value)
    if (cancels !== voiceCancels) throw new Error('Voice transcription cancelled.')
    try {
      return await voice.transcribe(data, current().cliPath)
    } catch (error) {
      // A CLI that fails with no stderr gives execFile's own text, which names the temp file.
      if (error instanceof Error && error.message.startsWith('Command failed'))
        throw new Error(
          'Muse Code could not transcribe this recording. Check your connection and CLI voice setup, then try again.',
        )
      throw error
    }
  })

  method('cancel-voice', () => cancelVoice())

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
    /** Cancels a transcription in progress: the quit path. */
    stopVoice: () => cancelVoice(),
    /** Stops the scheduled tasks' timer and settles after the check and write in progress: the quit path. */
    stopScheduler: () => {
      scheduler?.stop()
      return scheduler?.idle() ?? Promise.resolve()
    },
  }
}
