import { z } from 'zod'
import type { AppEvent } from '../shared/protocol'
import { messageOf } from '../main/muse-host'

// mMac and this backend speak one JSON object per line over stdin and stdout.
// Request (app → backend), Reply and Event (backend → app), and Ask (backend →
// app, then answered). See docs/superpowers/specs/2026-10-21-mac-app-design.md.

/** Change this, and `backendProtocol` in mMac's `Messages.swift`, when a message shape changes. */
export const HEADLESS_PROTOCOL = 3

const requestSchema = z.object({
  id: z.number().int().nonnegative(),
  method: z.string().min(1).max(100),
  args: z.array(z.unknown()).max(10).default([]),
})
const askAnswerSchema = z.object({
  answer: z.number().int().positive(),
  choice: z.number().int().min(-1),
})

const BAD_REQUEST = 'mMac sent a request the backend could not read.'

export type Method = (...args: unknown[]) => unknown

/** A native alert in mMac. The last button cancels. */
export type Ask = {
  kind: 'confirm'
  title: string
  message: string
  detail?: string
  buttons: string[]
}

type Outgoing =
  | { id: number; ok: true; value: unknown }
  | { id: number; ok: false; error: string }
  | { event: AppEvent }
  | ({ ask: number } & Ask)

function encode(message: Outgoing) {
  return `${JSON.stringify(message)}\n`
}

export class Wire {
  private asks = new Map<number, (choice: number) => void>()
  private nextAsk = 1
  private closed = false
  private inFlight = new Set<Promise<void>>()

  constructor(
    private write: (line: string) => void,
    private methods: Map<string, Method>,
  ) {}

  emit(event: AppEvent) {
    this.write(encode({ event }))
  }

  /** Shows a native alert in mMac and resolves with the chosen button's index. */
  ask(ask: Ask): Promise<number> {
    if (this.closed) return Promise.resolve(-1)
    const id = this.nextAsk++
    return new Promise((resolve) => {
      this.asks.set(id, resolve)
      this.write(encode({ ask: id, ...ask }))
    })
  }

  /**
   * Answers every open Ask with -1, the cancel choice. Used on quit. Every later
   * Ask also resolves with -1 at once, without writing a line.
   */
  cancelAsks() {
    this.closed = true
    for (const [id, resolve] of this.asks) {
      this.asks.delete(id)
      resolve(-1)
    }
  }

  /** Handles one line from mMac. Never rejects. */
  receive(line: string): Promise<void> {
    const work = this.handle(line).catch(() => {})
    this.inFlight.add(work)
    void work.finally(() => this.inFlight.delete(work))
    return work
  }

  /** Resolves when every request received so far has written its Reply. */
  async drain() {
    await Promise.allSettled([...this.inFlight])
  }

  private async handle(line: string) {
    if (!line.trim()) return
    let value: unknown
    try {
      value = JSON.parse(line)
    } catch {
      this.emit({ type: 'error', message: 'mMac sent a line that is not JSON.' })
      return
    }
    if (value !== null && typeof value === 'object' && 'answer' in value) {
      const answer = askAnswerSchema.safeParse(value)
      if (!answer.success) {
        this.emit({ type: 'error', message: 'mMac sent an Ask answer the backend could not read.' })
        return
      }
      const resolve = this.asks.get(answer.data.answer)
      this.asks.delete(answer.data.answer)
      resolve?.(answer.data.choice)
      return
    }
    const request = requestSchema.safeParse(value)
    if (!request.success) {
      const id = (value as { id?: unknown } | null)?.id
      if (typeof id === 'number' && Number.isInteger(id) && id >= 0) {
        this.write(encode({ id, ok: false, error: BAD_REQUEST }))
        return
      }
      this.emit({ type: 'error', message: BAD_REQUEST })
      return
    }
    const { id, method, args } = request.data
    try {
      const action = this.methods.get(method)
      if (!action) throw new Error(`Unknown method: ${method}`)
      this.write(encode({ id, ok: true, value: (await action(...args)) ?? null }))
    } catch (error) {
      this.write(encode({ id, ok: false, error: messageOf(error) }))
    }
  }
}
