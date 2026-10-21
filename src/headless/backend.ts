import { mkdir, realpath, stat } from 'node:fs/promises'
import { basename, join } from 'node:path'
import { z } from 'zod'
import {
  answerSchema,
  effortSchema,
  preferencesPatchSchema,
  preferencesSchema,
  type AppEvent,
  type Preferences,
} from '../shared/protocol'
import type { MuseHost } from '../main/muse-host'
import { readPreferences, writePreferences } from '../main/preferences'
import { projectRoot, worktreeParent } from '../shared/worktree'
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
}

export function createBackend({ muse, ask, emit, version, quitting, quit }: BackendDeps) {
  const id = z.string().min(1).max(200)
  const pathSchema = z.string().min(1).max(4096)
  const methods = new Map<string, Method>()
  let greeted = false
  let starting = false
  let preferences: Preferences | undefined
  let preferencePath = ''
  let preferenceWrites: Promise<void> = Promise.resolve()

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
      const { dataFolder } = z.object({ dataFolder: pathSchema }).parse(value)
      await mkdir(dataFolder, { recursive: true, mode: 0o700 })
      preferencePath = join(dataFolder, 'preferences.json')
      preferences = await readPreferences(preferencePath)
    } catch (error) {
      starting = false
      throw error
    }
    if (quitting()) throw new Error('The backend is quitting.')
    const status = await muse.connect(preferences.cliPath)
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
    return muse.create(root, z.string().optional().parse(modelId), { worktree })
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

  // Electron also restarts the bridges when a bridge* key changes; mMac adds that with the bridges in M3.
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
  }
}
