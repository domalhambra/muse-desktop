import { randomUUID } from 'node:crypto'
import { chmod, readFile, rename, writeFile } from 'node:fs/promises'
import { z } from 'zod'
import type { AppEvent } from '../shared/protocol'
import { checkCron, dueTime, nextRun, scheduleSchema, type Schedule } from './schedule-rules'

// Scheduled tasks, as Desktop's Scheduled page: checked every minute while mMac runs, one run at a
// time, with a capped history. Pure timing lives in schedule-rules.ts.

const runSchema = z.object({
  at: z.number(),
  scheduledFor: z.number().nullable(),
  outcome: z.enum(['started', 'skipped', 'failed']),
  reason: z.string().optional(),
  sessionId: z.string().optional(),
})
export type ScheduleRun = z.infer<typeof runSchema>
const storeSchema = z.object({
  schedules: z.array(scheduleSchema),
  history: z.record(z.string(), z.array(runSchema)),
  lastCheckedAt: z.number(),
})
type Store = z.infer<typeof storeSchema>
export const scheduleInputSchema = scheduleSchema
  .omit({ id: true, createdAt: true })
  .extend({ id: z.string().min(1).max(100).optional() })
export type ScheduleInput = z.infer<typeof scheduleInputSchema>
export type ScheduleEntry = { schedule: Schedule; nextRunAt: number | null; history: ScheduleRun[] }

const HISTORY = 50
const BUSY = 'Another scheduled task was running.'
const WAITING = 'Waiting for your approval.'

/** A start that failed after it made the conversation. The run's history entry keeps its id. */
export class StartFailed extends Error {
  constructor(
    message: string,
    readonly sessionId: string,
  ) {
    super(message)
  }
}

export type SchedulerDeps = {
  file: string
  now?: () => number
  /** IANA time zone for the cron rules; the Mac's own when omitted. Tests pass 'UTC'. */
  tz?: string
  /**
   * Creates the conversation, sets its mode and sends the prompt. Returns the session id. A
   * StartFailed rejection names the conversation it made.
   */
  start: (schedule: Schedule) => Promise<string>
  /** True while the session's turn runs. */
  isRunning: (sessionId: string) => boolean
  /**
   * True while the session waits for the person: a tool approval or a question. Such a run no
   * longer holds back other tasks. Never waiting when omitted.
   */
  isWaiting?: (sessionId: string) => boolean
  emit: (event: AppEvent) => void
}

export class Scheduler {
  private store: Store = { schedules: [], history: {}, lastCheckedAt: 0 }
  private active: { scheduleId: string; starting: boolean; sessionId?: string } | null = null
  /** Runs that waited for the person. Each counts as busy again while it runs and no longer waits. */
  private parked = new Set<string>()
  private timer?: ReturnType<typeof setInterval>
  private writes: Promise<void> = Promise.resolve()
  private ticking: Promise<void> | null = null

  constructor(private deps: SchedulerDeps) {}

  private now() {
    return (this.deps.now ?? Date.now)()
  }

  async load() {
    try {
      this.store = storeSchema.parse(JSON.parse(await readFile(this.deps.file, 'utf8')))
    } catch {
      this.store = { schedules: [], history: {}, lastCheckedAt: 0 }
    }
  }

  /** Checks now, then every minute. A failed check is logged; the next minute tries again. */
  start() {
    this.stop()
    this.timer = setInterval(() => this.timedTick(), 60_000)
    this.timedTick()
  }

  private timedTick() {
    this.tick().catch((error: unknown) => {
      console.error(
        `mMac could not check scheduled tasks: ${error instanceof Error ? error.message : String(error)}`,
      )
    })
  }

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = undefined
  }

  /**
   * Settles after the check in progress, if any, and the last store write: the quit path waits
   * for it so lastCheckedAt is saved. A failed check was already logged; a failed write rejects.
   */
  async idle() {
    await this.ticking?.catch(() => {})
    await this.writes
  }

  list(): ScheduleEntry[] {
    const now = this.now()
    return this.store.schedules.map((schedule) => ({
      schedule,
      nextRunAt: schedule.enabled ? this.safeNextRun(schedule, now) : null,
      history: [...(this.store.history[schedule.id] ?? [])].reverse(),
    }))
  }

  /** Null when the stored cron or the time zone cannot be read: one bad task never breaks the list. */
  private safeNextRun(schedule: Schedule, now: number): number | null {
    try {
      return nextRun(schedule, now, this.deps.tz)
    } catch {
      return null
    }
  }

  async save(value: unknown): Promise<ScheduleEntry> {
    const input = scheduleInputSchema.parse(value)
    if (input.preset === 'custom') {
      const problem = checkCron(input.cron ?? '')
      if (problem) throw new Error(problem)
    }
    const existing = this.store.schedules.find((schedule) => schedule.id === input.id)
    const schedule: Schedule = {
      ...input,
      id: existing?.id ?? randomUUID(),
      createdAt: existing?.createdAt ?? this.now(),
    }
    this.store.schedules = existing
      ? this.store.schedules.map((entry) => (entry.id === schedule.id ? schedule : entry))
      : [...this.store.schedules, schedule]
    await this.writeAndEmit()
    return this.list().find((entry) => entry.schedule.id === schedule.id)!
  }

  async remove(id: string) {
    this.store.schedules = this.store.schedules.filter((schedule) => schedule.id !== id)
    delete this.store.history[id]
    await this.writeAndEmit()
  }

  async setEnabled(id: string, enabled: boolean) {
    if (!this.store.schedules.some((schedule) => schedule.id === id))
      throw new Error('This scheduled task no longer exists.')
    this.store.schedules = this.store.schedules.map((schedule) =>
      schedule.id === id ? { ...schedule, enabled } : schedule,
    )
    await this.writeAndEmit()
  }

  async runNow(id: string) {
    const schedule = this.store.schedules.find((entry) => entry.id === id)
    if (!schedule) throw new Error('This scheduled task no longer exists.')
    this.settle()
    if (this.busy())
      throw new Error('Another scheduled task is running. Try again when it finishes.')
    await this.run(schedule, null)
  }

  /**
   * Not reentrant: a tick that starts while one runs (a start slower than a minute) waits for
   * that one instead of checking the tasks again before lastCheckedAt moves.
   */
  tick(): Promise<void> {
    this.ticking ??= this.check().finally(() => {
      this.ticking = null
    })
    return this.ticking
  }

  private async check() {
    const now = this.now()
    // Each minute, so a run that comes to wait for an approval says so then, not at the next due task.
    this.settle()
    for (const schedule of this.store.schedules) {
      const since = Math.max(this.store.lastCheckedAt, schedule.createdAt)
      let due: number | null
      try {
        due = dueTime(schedule, since, now, this.deps.tz)
      } catch (error) {
        // An unreadable stored cron or time zone: record it once, then go on to the others.
        this.recordProblem(schedule, now, error)
        continue
      }
      if (due === null) continue
      if (this.busy())
        this.record(schedule.id, { at: now, scheduledFor: due, outcome: 'skipped', reason: BUSY })
      else await this.run(schedule, due)
    }
    this.store.lastCheckedAt = now
    await this.write()
  }

  /**
   * Parks a run that waits for the person, with one history entry, and forgets finished runs.
   * check and runNow call it before busy.
   */
  private settle() {
    for (const sessionId of this.parked)
      if (!this.deps.isRunning(sessionId)) this.parked.delete(sessionId)
    if (!this.active || this.active.starting || !this.active.sessionId) return
    const { scheduleId, sessionId } = this.active
    if (this.deps.isWaiting?.(sessionId)) {
      // The run stays open in its conversation, but no longer holds back other tasks.
      this.record(scheduleId, {
        at: this.now(),
        scheduledFor: null,
        outcome: 'started',
        reason: WAITING,
        sessionId,
      })
      this.parked.add(sessionId)
      this.active = null
    } else if (!this.deps.isRunning(sessionId)) this.active = null
  }

  /** No side effects: settle keeps `active` and `parked` current. */
  private busy() {
    if (this.active?.starting) return true
    if (this.active?.sessionId && this.deps.isRunning(this.active.sessionId)) return true
    for (const sessionId of this.parked)
      if (this.deps.isRunning(sessionId) && !this.deps.isWaiting?.(sessionId)) return true
    return false
  }

  private async run(schedule: Schedule, scheduledFor: number | null) {
    this.active = { scheduleId: schedule.id, starting: true }
    try {
      const sessionId = await this.deps.start(schedule)
      this.active = { scheduleId: schedule.id, starting: false, sessionId }
      this.record(schedule.id, { at: this.now(), scheduledFor, outcome: 'started', sessionId })
      this.deps.emit({
        type: 'schedule-run-started',
        scheduleId: schedule.id,
        name: schedule.name,
        sessionId,
      })
    } catch (error) {
      this.active = null
      this.record(schedule.id, {
        at: this.now(),
        scheduledFor,
        outcome: 'failed',
        reason: error instanceof Error ? error.message : String(error),
        ...(error instanceof StartFailed ? { sessionId: error.sessionId } : {}),
      })
    }
    await this.write()
  }

  private recordProblem(schedule: Schedule, now: number, error: unknown) {
    // A stored custom cron the form would refuse gets the form's sentence; anything else (the
    // Mac's time zone, say) gets a general one. The raw text goes to stderr.
    const reason =
      (schedule.preset === 'custom' ? checkCron(schedule.cron ?? '') : undefined) ??
      'mMac could not work out when this task runs.'
    const last = this.store.history[schedule.id]?.at(-1)
    if (last?.outcome === 'failed' && last.reason === reason) return
    console.error(
      `mMac could not read scheduled task ${schedule.id}: ${error instanceof Error ? error.message : String(error)}`,
    )
    this.record(schedule.id, { at: now, scheduledFor: null, outcome: 'failed', reason })
  }

  private record(id: string, run: ScheduleRun) {
    // A task removed during a slow start keeps no orphan history.
    if (!this.store.schedules.some((schedule) => schedule.id === id)) return
    this.store.history[id] = [...(this.store.history[id] ?? []), run].slice(-HISTORY)
    this.deps.emit({ type: 'schedules-changed' })
  }

  /**
   * A failed write still emits: memory has the change but the file may not, and other windows
   * reload what is true now. The caller still sees the failure.
   */
  private async writeAndEmit() {
    try {
      await this.write()
    } finally {
      this.deps.emit({ type: 'schedules-changed' })
    }
  }

  /** A temporary file with mode 600, renamed over the store: no half-written file after a crash. */
  private write() {
    // Each write waits for the one before but not on its success, so one failure (a full disk, a
    // missing folder) does not fail every later write. The caller still sees its own failure.
    const data = JSON.stringify(this.store, null, 2)
    const next = this.writes
      .catch(() => {})
      .then(async () => {
        const temporary = `${this.deps.file}.${process.pid}.tmp`
        await writeFile(temporary, data, { mode: 0o600 })
        // The mode option applies only when the file is created; a leftover temporary keeps its own.
        await chmod(temporary, 0o600)
        await rename(temporary, this.deps.file)
      })
    this.writes = next
    return next
  }
}
