import assert from 'node:assert/strict'
import { execFileSync, spawn } from 'node:child_process'
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
  MUSE_HOME: join(temporary, 'muse'),
  XDG_CONFIG_HOME: join(temporary, 'config'),
  XDG_DATA_HOME: join(temporary, 'data'),
  XDG_STATE_HOME: join(temporary, 'state'),
  MUSE_DESKTOP_TEST_PROVIDER: 'echo',
}

type Line = Record<string, unknown>

/** The process IDs of every echo-provider `muse serve` on this Mac. */
function serveProcesses() {
  try {
    return execFileSync('pgrep', ['-f', 'serve --trust-workspace --provider echo'], {
      encoding: 'utf8',
    })
      .split('\n')
      .filter(Boolean)
  } catch {
    return [] // pgrep exits 1 when nothing matches.
  }
}

async function until(check: () => boolean, what: string, milliseconds = 15000) {
  const deadline = Date.now() + milliseconds
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}.`)
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
}

function launch() {
  const child = spawn(process.execPath, ['--import', 'tsx', 'src/headless/server.ts'], {
    cwd: root,
    env: environment,
    stdio: ['pipe', 'pipe', 'inherit'],
  })
  const exited = new Promise<number | null>((resolve) => child.on('exit', resolve))
  const replies = new Map<number, (line: Line) => void>()
  const events: Line[] = []
  const asks: Line[] = []
  let nextId = 1
  const send = (message: unknown) => child.stdin.write(`${JSON.stringify(message)}\n`)
  createInterface({ input: child.stdout }).on('line', (text) => {
    const line = JSON.parse(text) as Line // A stray non-JSON line on stdout fails the run here.
    if (typeof line.id === 'number') replies.get(line.id)?.(line)
    else if ('event' in line) events.push(line.event as Line)
    else if ('ask' in line) {
      asks.push(line)
      send({ answer: line.ask, choice: 0 })
    } else throw new Error(`The backend wrote a line of no known kind: ${text}`)
  })
  function request(method: string, ...args: unknown[]) {
    const requestId = nextId++
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} got no reply.`)), 30000)
      replies.set(requestId, (line) => {
        clearTimeout(timer)
        replies.delete(requestId)
        if (line.ok) resolve(line.value)
        else reject(new Error(String(line.error)))
      })
      send({ id: requestId, method, args })
    })
  }
  return { child, exited, events, asks, request }
}

const before = serveProcesses()
const noNewServe = () => serveProcesses().every((pid) => before.includes(pid))
const backends: ReturnType<typeof launch>[] = []
try {
  const backend = launch()
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
  assert(!noNewServe(), 'The backend should start its own muse serve.')
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

  assert.equal(await backend.request('shutdown'), true)
  assert.equal(await backend.exited, 0)
  await until(noNewServe, 'muse serve to stop after shutdown')
  console.log('PASS · shutdown exits 0 and leaves no muse process')

  const closing = launch()
  backends.push(closing)
  await closing.request('hello', HEADLESS_PROTOCOL)
  await closing.request('start', { dataFolder })
  assert(!noNewServe(), 'The second backend should start its own muse serve.')
  closing.child.stdin.end()
  assert.equal(await closing.exited, 0)
  await until(noNewServe, 'muse serve to stop after stdin closed')

  // Closing stdin while start is still connecting must not leave a muse serve behind.
  const connecting = launch()
  backends.push(connecting)
  await connecting.request('hello', HEADLESS_PROTOCOL)
  connecting.request('start', { dataFolder }).catch(() => {}) // It may reject once the backend quits.
  const waitUntil = Date.now() + 300
  while (noNewServe() && Date.now() < waitUntil)
    await new Promise((resolve) => setTimeout(resolve, 20))
  connecting.child.stdin.end()
  assert.equal(await connecting.exited, 0)
  await until(noNewServe, 'muse serve to stop after stdin closed mid-connect', 20000)

  const mismatched = launch()
  backends.push(mismatched)
  await assert.rejects(mismatched.request('hello', HEADLESS_PROTOCOL + 1), /backend protocol/)
  assert.equal(await mismatched.exited, 2)
  console.log('PASS · Closing stdin (idle or mid-connect) exits 0; a mismatched hello exits 2')
} finally {
  for (const backend of backends) backend.child.kill()
  await rm(temporary, { recursive: true, force: true })
}
