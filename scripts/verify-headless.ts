import assert from 'node:assert/strict'
import { execFileSync, spawn, type ChildProcess } from 'node:child_process'
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import type { SessionView } from '../src/shared/protocol'
import { HEADLESS_PROTOCOL } from '../src/headless/wire'

// Drives src/headless/server.ts the way mMac does, against the real CLI and the
// echo provider. Run: MUSE_BIN="$(command -v muse)" npm run test:headless

assert(process.env.MUSE_BIN, 'Set MUSE_BIN: MUSE_BIN="$(command -v muse)" npm run test:headless')
const root = fileURLToPath(new URL('..', import.meta.url))
const temporary = await realpath(await mkdtemp(join(tmpdir(), 'mmac-headless-')))
const project = join(temporary, 'project')
const dataFolder = join(temporary, 'app-data')
await mkdir(project)
await mkdir(dataFolder)
await writeFile(
  join(dataFolder, 'preferences.json'),
  JSON.stringify({ cliPath: process.env.MUSE_BIN }),
)
const environment = {
  ...process.env,
  HOME: temporary,
  ZDOTDIR: temporary, // A login shell started under HOME must not read the real dotfiles.
  MUSE_HOME: join(temporary, 'muse'),
  XDG_CONFIG_HOME: join(temporary, 'config'),
  XDG_DATA_HOME: join(temporary, 'data'),
  XDG_STATE_HOME: join(temporary, 'state'),
  MUSE_DESKTOP_TEST_PROVIDER: 'echo',
  MUSE_NO_AUTO_UPDATE: '1', // The muse launcher script skips its background update check.
}

type Line = Record<string, unknown>
type Backend = ReturnType<typeof launch>

const servePattern = 'serve --trust-workspace --provider echo'

function pgrep(args: string[]) {
  try {
    return execFileSync('pgrep', args, { encoding: 'utf8' }).split('\n').filter(Boolean).map(Number)
  } catch {
    return [] // pgrep exits 1 when nothing matches.
  }
}

/** The echo-provider `muse serve` processes this child started: its children and grandchildren. */
function ownedServe(child: ChildProcess) {
  const parent = child.pid
  if (parent === undefined) return []
  const direct = pgrep(['-P', String(parent)])
  return [
    ...pgrep(['-P', String(parent), '-f', servePattern]),
    ...direct.flatMap((pid) => pgrep(['-P', String(pid), '-f', servePattern])),
  ]
}

function alive(pid: number) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== 'ESRCH'
  }
}

async function until(check: () => boolean, what: string, milliseconds = 15000) {
  const deadline = Date.now() + milliseconds
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}.`)
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
}

function launch(label: string, extraEnvironment: Record<string, string | undefined> = {}) {
  const child = spawn(process.execPath, ['--import', 'tsx', 'src/headless/server.ts'], {
    cwd: root,
    env: { ...environment, ...extraEnvironment },
    stdio: ['pipe', 'pipe', 'inherit'],
  })
  const exited = new Promise<number | null>((resolve) => child.on('exit', resolve))
  const pending = new Map<
    number,
    { reply: (line: Line) => void; fail: (error: Error) => void; timer: NodeJS.Timeout }
  >()
  const events: Line[] = []
  const asks: Line[] = []
  const serves = new Set<number>() // Every serve PID seen, so a leak is checked by PID.
  let fault: Error | undefined
  let nextId = 1
  const send = (message: unknown) => child.stdin.write(`${JSON.stringify(message)}\n`)
  function failPending(error: Error) {
    for (const entry of pending.values()) {
      clearTimeout(entry.timer)
      entry.fail(error)
    }
    pending.clear()
  }
  createInterface({ input: child.stdout }).on('line', (text) => {
    try {
      const line = JSON.parse(text) as Line // A stray non-JSON line on stdout fails the run.
      if (typeof line.id === 'number') pending.get(line.id)?.reply(line)
      else if ('event' in line) events.push(line.event as Line)
      else if ('ask' in line) {
        asks.push(line)
        send({ answer: line.ask, choice: 0 })
      } else throw new Error('a line of no known kind')
    } catch (error) {
      fault = new Error(`${label} wrote a bad line (${(error as Error).message}): ${text}`)
      failPending(fault)
    }
  })
  child.on('close', (code, signal) =>
    failPending(new Error(`backend exited with code ${code ?? signal}`)),
  )
  function request(method: string, ...args: unknown[]) {
    const requestId = nextId++
    return new Promise<unknown>((resolve, reject) => {
      if (fault) return reject(fault)
      const timer = setTimeout(() => {
        pending.delete(requestId)
        reject(new Error(`${method} got no reply.`))
      }, 30000)
      pending.set(requestId, {
        timer,
        fail: reject,
        reply(line) {
          clearTimeout(timer)
          pending.delete(requestId)
          if (line.ok) resolve(line.value)
          else reject(new Error(String(line.error)))
        },
      })
      send({ id: requestId, method, args })
    })
  }
  const recordServes = () => {
    for (const pid of ownedServe(child)) serves.add(pid)
    return serves.size
  }
  return {
    label,
    child,
    exited,
    events,
    asks,
    serves,
    request,
    recordServes,
    fault: () => fault,
  }
}

/** The backend's exit code, or a failure if it hangs. */
async function exitWithin(backend: Backend, milliseconds = 10000) {
  let timer: NodeJS.Timeout | undefined
  const hung = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () =>
        reject(new Error(`${backend.label} did not exit within ${milliseconds / 1000} seconds`)),
      milliseconds,
    )
  })
  try {
    return await Promise.race([backend.exited, hung])
  } finally {
    clearTimeout(timer)
  }
}

/** True when every muse serve this backend started is dead. */
const ownedGone = (backend: Backend) => [...backend.serves].every((pid) => !alive(pid))

/** Proves the backend started its own muse serve, so the leak checks cannot pass vacuously. */
function assertOwnsServe(backend: Backend) {
  assert(backend.recordServes() > 0, `${backend.label} should start its own muse serve.`)
}

const backends: Backend[] = []
try {
  const backend = launch('The first backend')
  backends.push(backend)
  await assert.rejects(backend.request('sessions'), /Send hello first/)
  const hello = (await backend.request('hello', HEADLESS_PROTOCOL)) as { protocol: number }
  assert.equal(hello.protocol, HEADLESS_PROTOCOL)
  const started = (await backend.request('start', { dataFolder })) as {
    status: { state: string; version?: string; message?: string }
  }
  assert.equal(
    started.status.state,
    'ready',
    started.status.message ?? 'The backend did not reach ready.',
  )
  assertOwnsServe(backend)
  console.log(`PASS · Hello and start; connected to Muse Code ${started.status.version}`)

  assert.equal(await backend.request('add-project', project), project)
  const created = (await backend.request('create', project)) as SessionView
  assert.equal(backend.asks.length, 1)
  assert.equal(backend.asks[0].title, 'Trust this project?')
  const sessionId = created.session.sessionId
  console.log('PASS · Add a project, answer the trust Ask, create a conversation')

  await backend.request('send', {
    sessionId,
    text: 'Hello, mMac.',
    attachments: [],
    effort: 'high',
    mode: 'queue',
  })
  await until(
    () =>
      backend.events.some((event) => {
        if (event.type !== 'session') return false
        const view = event.view as SessionView
        return (
          view.session.sessionId === sessionId &&
          view.session.status === 'idle' &&
          view.items.some(
            (item) =>
              item.kind === 'agentMessage' &&
              item.status === 'completed' &&
              item.text?.includes('Hello'),
          )
        )
      }),
    'the echo reply',
  )
  console.log('PASS · One echo turn streamed as session events')

  const listed = (await backend.request('sessions')) as { sessions: { sessionId: string }[] }
  assert(listed.sessions.some((session) => session.sessionId === sessionId))
  console.log('PASS · The new conversation is in the session list')

  // M1 methods against the real CLI. The echo provider has no models and no stored output.
  // session/list does not carry a session's name, and the CLI normalizes it (the name comes
  // back lowercased), so the rename shows in the pushed session event and in open.
  const models = await backend.request('models', sessionId)
  assert(Array.isArray(models), 'models should reply with a list')
  await backend.request('rename', sessionId, '  mMac check  ')
  const renamedTo = (name?: string) => name?.trim().toLowerCase() === 'mmac check'
  await until(
    () =>
      backend.events.some(
        (event) => event.type === 'session' && renamedTo((event.view as SessionView).session.name),
      ),
    'the new name in a session event',
  )
  const reopened = (await backend.request('open', sessionId)) as SessionView
  assert(
    renamedTo(reopened.session.name),
    `open should show the new name: ${reopened.session.name}`,
  )
  const saved = (await backend.request('preferences', { reasoningEffort: 'low' })) as {
    reasoningEffort: string
  }
  assert.equal(saved.reasoningEffort, 'low')
  await assert.rejects(backend.request('preferences', { trustedProjects: [] }))
  const replyItem = backend.events
    .filter((event) => event.type === 'session')
    .map((event) => event.view as SessionView)
    .at(-1)
    ?.items.find((item) => item.kind === 'agentMessage')?.itemId
  assert(replyItem, 'the echo reply should have an item id')
  await assert.rejects(backend.request('output', sessionId, replyItem), /no stored output/)
  console.log('PASS · Rename, models, preferences and the stored-output error')

  // Only the trust Ask, before and after shutdown: an unexpected Ask must not be quietly confirmed.
  assert.equal(backend.asks.length, 1, 'Only the trust Ask was expected before shutdown.')
  backend.recordServes()
  assert.equal(await backend.request('shutdown'), true)
  assert.equal(await exitWithin(backend), 0)
  assert.equal(backend.asks.length, 1, 'Shutdown should not raise an Ask.')
  await until(() => ownedGone(backend), 'muse serve to stop after shutdown')
  console.log('PASS · shutdown exits 0 and leaves no muse process')

  const closing = launch('The stdin-closing backend')
  backends.push(closing)
  await closing.request('hello', HEADLESS_PROTOCOL)
  await closing.request('start', { dataFolder })
  assertOwnsServe(closing)
  closing.child.stdin.end()
  assert.equal(await exitWithin(closing), 0)
  await until(() => ownedGone(closing), 'muse serve to stop after stdin closed')

  // Closing stdin while start is still connecting must not leave a muse serve behind.
  // A wrapper makes the connect slow, so the close lands while muse serve is starting.
  const slowFolder = join(temporary, 'slow-app-data')
  const wrapper = join(temporary, 'slow-muse.sh')
  await mkdir(slowFolder)
  await writeFile(join(slowFolder, 'preferences.json'), JSON.stringify({ cliPath: wrapper }))
  await writeFile(
    wrapper,
    '#!/bin/sh\nif [ "$1" = serve ]; then sleep 2; fi\nexec "$MUSE_BIN_REAL" "$@"\n',
    { mode: 0o755 },
  )
  const connecting = launch('The mid-connect backend', { MUSE_BIN_REAL: process.env.MUSE_BIN })
  backends.push(connecting)
  await connecting.request('hello', HEADLESS_PROTOCOL)
  let startReplied = false
  connecting.request('start', { dataFolder: slowFolder }).then(
    () => (startReplied = true),
    () => (startReplied = true), // It may reject once the backend quits.
  )
  await until(() => connecting.recordServes() > 0, 'the slow muse serve to appear')
  assert(!startReplied, 'start should still be connecting when stdin closes.')
  connecting.child.stdin.end()
  assert.equal(await exitWithin(connecting), 0)
  await until(
    () => ownedGone(connecting),
    'muse serve to stop after stdin closed mid-connect',
    20000,
  )

  // A backend that crashes (SIGKILL, no quit path) must not leave its muse serve behind.
  const crashed = launch('The crashed backend')
  backends.push(crashed)
  await crashed.request('hello', HEADLESS_PROTOCOL)
  await crashed.request('start', { dataFolder })
  assertOwnsServe(crashed)
  crashed.child.kill('SIGKILL')
  await exitWithin(crashed)
  await until(() => ownedGone(crashed), 'muse serve to stop after the backend crashed', 20000)

  const mismatched = launch('The mismatched backend')
  backends.push(mismatched)
  await assert.rejects(mismatched.request('hello', HEADLESS_PROTOCOL + 1), /backend protocol/)
  assert.equal(await exitWithin(mismatched), 2)
  for (const each of backends) assert(!each.fault(), String(each.fault()))
  console.log(
    'PASS · Closing stdin (idle or mid-connect) or a crash leaves no muse process; a mismatched hello exits 2',
  )
} finally {
  // Whatever happened, leave no backend and no muse serve of ours running.
  for (const each of backends) {
    if (each.child.exitCode === null && each.child.signalCode === null) {
      each.recordServes()
      each.child.kill('SIGKILL')
    }
    // Kill a recorded PID only while it still runs a serve command, so a PID that
    // macOS reused for another process is left alone.
    const running = pgrep(['-f', servePattern])
    for (const pid of each.serves) {
      if (!alive(pid) || !running.includes(pid)) continue
      try {
        process.kill(pid, 'SIGKILL')
      } catch {} // Gone since the check.
    }
    await exitWithin(each, 5000).catch(() => {})
  }
  await rm(temporary, { recursive: true, force: true })
}
