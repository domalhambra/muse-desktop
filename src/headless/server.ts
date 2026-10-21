import { readFile } from 'node:fs/promises'
import { createInterface } from 'node:readline'
import type { AppEvent } from '../shared/protocol'
import { MuseHost, messageOf } from '../main/muse-host'
import { publish } from '../main/event-bus'
import { createBackend } from './backend'
import { Wire } from './wire'

// mMac's backend process: the fork's core in one plain Node process, driven over
// stdin and stdout. The methods live in ./backend.ts; this file owns the process.

// stdout carries only protocol lines. Anything a library logs goes to stderr.
const writeOut = process.stdout.write.bind(process.stdout)
for (const name of ['log', 'info', 'debug', 'warn'] as const) console[name] = console.error
console.dir = (value: unknown) => console.error(value)

const { version } = JSON.parse(
  await readFile(new URL('../../package.json', import.meta.url), 'utf8'),
) as { version: string }
// Set when stdout fails (mMac died). Later writes are skipped, so nothing throws.
let stdoutBroken = false
let quitting = false

// emit and ask use wire, which is built below; nothing emits before the first stdin line, so this is safe.
function emit(event: AppEvent) {
  publish(event)
  wire.emit(event)
}
const muse = new MuseHost(emit)
const backend = createBackend({
  muse,
  ask: (value) => wire.ask(value),
  emit,
  version,
  quitting: () => quitting,
  // Run the quit path after the current Reply is written, so mMac reads it.
  quit: (code) => setImmediate(() => void quit(code)),
})
const wire = new Wire((line) => {
  if (!stdoutBroken) writeOut(line)
}, backend.methods)

/** Waits for every queued stdout write, then exits. */
function exit(code: number) {
  process.exitCode = code
  if (stdoutBroken) process.exit(code)
  // A stdout that breaks while this write waits may never call back. Do not hang on it.
  setTimeout(() => process.exit(code), 2000).unref()
  process.stdout.write('', () => process.exit(code))
}

async function quit(code: number) {
  if (quitting) return
  quitting = true
  wire.cancelAsks()
  const failed = (error: unknown) => {
    console.error(`The mMac backend did not shut down cleanly: ${messageOf(error)}`)
    code ||= 1
  }
  // Closing Muse makes waiting requests fail, so drain() cannot wait forever.
  const results = await Promise.allSettled([muse.close(), backend.preferenceWrites(), wire.drain()])
  for (const result of results) if (result.status === 'rejected') failed(result.reason)
  try {
    // A connect that was in progress during the first close has finished by now,
    // and only then does MuseHost hold a host to close.
    await muse.close()
  } catch (error) {
    failed(error)
  }
  exit(code)
}

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity })
lines.on('line', (line) => {
  if (!quitting) void wire.receive(line)
})
// mMac closed stdin, quit or crashed.
lines.on('close', () => void quit(0))
process.on('SIGTERM', () => void quit(0))
process.stdout.on('error', () => {
  stdoutBroken = true
  void quit(0)
})
