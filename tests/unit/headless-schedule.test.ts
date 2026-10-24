import { mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { Scheduler, type ScheduleInput } from '../../src/headless/schedule'
import type { AppEvent } from '../../src/shared/protocol'

const input: ScheduleInput = {
  name: 'Morning review',
  prompt: 'Review yesterday’s commits.',
  folder: '/p',
  preset: 'daily',
  minute: 0,
  hour: 9,
  weekday: 1,
  approvalMode: 'promptUnmatched',
  modelId: null,
  worktree: false,
  enabled: true,
}
let dir = ''
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'mmac-schedule-'))
})

function harness(start = vi.fn(async () => 'session-1')) {
  let now = Date.parse('2026-10-26T08:00:00Z')
  const events: AppEvent[] = []
  const running = new Set<string>()
  const scheduler = new Scheduler({
    file: join(dir, 'schedules.json'),
    now: () => now,
    tz: 'UTC',
    start,
    isRunning: (sessionId) => running.has(sessionId),
    emit: (event) => events.push(event),
  })
  return {
    scheduler,
    events,
    running,
    start,
    at: (iso: string) => {
      now = Date.parse(iso)
    },
  }
}

describe('Scheduler', () => {
  it('starts a missing or unreadable store empty, and writes mode 600 atomically', async () => {
    await writeFile(join(dir, 'schedules.json'), 'not json')
    const { scheduler } = harness()
    await scheduler.load()
    expect(scheduler.list()).toEqual([])
    await scheduler.save(input)
    expect((await stat(join(dir, 'schedules.json'))).mode & 0o777).toBe(0o600)
    expect(JSON.parse(await readFile(join(dir, 'schedules.json'), 'utf8')).schedules).toHaveLength(
      1,
    )
  })

  it('refuses a custom task more often than hourly', async () => {
    const { scheduler } = harness()
    await scheduler.load()
    await expect(
      scheduler.save({ ...input, preset: 'custom', cron: '*/5 * * * *' }),
    ).rejects.toThrow(/at most once an hour/)
  })

  it('runs a due task once, then skips another while it runs', async () => {
    const h = harness()
    await h.scheduler.load()
    const first = await h.scheduler.save(input)
    const second = await h.scheduler.save({ ...input, name: 'Second' })
    h.at('2026-10-26T09:00:30Z')
    h.running.add('session-1')
    await h.scheduler.tick()
    expect(h.start).toHaveBeenCalledTimes(1)
    const entries = h.scheduler.list()
    const ran = entries.find((entry) => entry.schedule.id === first.schedule.id)!
    const skipped = entries.find((entry) => entry.schedule.id === second.schedule.id)!
    expect(ran.history[0]).toMatchObject({ outcome: 'started', sessionId: 'session-1' })
    expect(skipped.history[0]).toMatchObject({
      outcome: 'skipped',
      reason: 'Another scheduled task was running.',
    })
    expect(h.events).toContainEqual({
      type: 'schedule-run-started',
      scheduleId: first.schedule.id,
      name: 'Morning review',
      sessionId: 'session-1',
    })
    expect(h.events).toContainEqual({ type: 'schedules-changed' })
    // The same minute again: nothing more comes due.
    await h.scheduler.tick()
    expect(h.start).toHaveBeenCalledTimes(1)
  })

  it('records a failed start with its reason', async () => {
    const h = harness(
      vi.fn(async () => {
        throw new Error('The folder is not trusted in mMac.')
      }),
    )
    await h.scheduler.load()
    await h.scheduler.save(input)
    h.at('2026-10-26T09:00:30Z')
    await h.scheduler.tick()
    expect(h.scheduler.list()[0].history[0]).toMatchObject({
      outcome: 'failed',
      reason: 'The folder is not trusted in mMac.',
    })
  })

  it('runs a paused task now, but not while another runs', async () => {
    const h = harness()
    await h.scheduler.load()
    const entry = await h.scheduler.save({ ...input, enabled: false })
    expect(h.scheduler.list()[0].nextRunAt).toBeNull()
    h.running.add('session-1')
    await h.scheduler.runNow(entry.schedule.id)
    expect(h.start).toHaveBeenCalledTimes(1)
    await expect(h.scheduler.runNow(entry.schedule.id)).rejects.toThrow(
      'Another scheduled task is running. Try again when it finishes.',
    )
  })

  it('keeps the newest 50 runs and drops history with the task', async () => {
    const h = harness(vi.fn(async () => `s-${Math.random()}`))
    await h.scheduler.load()
    const entry = await h.scheduler.save({ ...input, preset: 'manual' })
    for (let run = 0; run < 55; run++) await h.scheduler.runNow(entry.schedule.id)
    expect(h.scheduler.list()[0].history).toHaveLength(50)
    await h.scheduler.remove(entry.schedule.id)
    expect(h.scheduler.list()).toEqual([])
  })

  it('does not catch up runs from before a task existed', async () => {
    const h = harness()
    h.at('2026-10-26T09:30:00Z')
    await h.scheduler.load()
    await h.scheduler.save(input)
    await h.scheduler.tick()
    expect(h.start).not.toHaveBeenCalled()
  })

  it('one unreadable stored schedule never stops the others', async () => {
    const created = Date.parse('2026-10-25T00:00:00Z')
    const bad = { ...input, id: 'bad', preset: 'custom', cron: 'not a cron', createdAt: created }
    const good = { ...input, id: 'good', createdAt: created }
    await writeFile(
      join(dir, 'schedules.json'),
      JSON.stringify({ schedules: [bad, good], history: {}, lastCheckedAt: created }),
    )
    const h = harness()
    await h.scheduler.load()
    const listed = h.scheduler.list()
    expect(listed.map((entry) => entry.nextRunAt === null)).toEqual([true, false])
    h.at('2026-10-26T09:00:30Z')
    await h.scheduler.tick()
    expect(h.start).toHaveBeenCalledTimes(1)
    const entries = h.scheduler.list()
    expect(entries[1].history[0]).toMatchObject({ outcome: 'started' })
    expect(entries[0].history[0]).toMatchObject({ outcome: 'failed' })
    expect(entries[0].history[0].reason).toMatch(/could not read this schedule/)
    // The same problem is recorded once, not every minute.
    h.at('2026-10-26T09:01:30Z')
    await h.scheduler.tick()
    expect(h.scheduler.list()[0].history).toHaveLength(1)
  })

  it('a bad time zone records a failure instead of throwing', async () => {
    let now = Date.parse('2026-10-26T08:00:00Z')
    const start = vi.fn(async () => 'session-1')
    const scheduler = new Scheduler({
      file: join(dir, 'schedules.json'),
      now: () => now,
      tz: 'Not/AZone',
      start,
      isRunning: () => false,
      emit: () => {},
    })
    await scheduler.load()
    await scheduler.save(input)
    expect(scheduler.list()[0].nextRunAt).toBeNull()
    now = Date.parse('2026-10-26T09:00:30Z')
    await scheduler.tick()
    expect(start).not.toHaveBeenCalled()
    expect(scheduler.list()[0].history[0]).toMatchObject({ outcome: 'failed' })
  })

  it('a tick that starts while one runs does not check the tasks again', async () => {
    let release = () => {}
    const blocked = new Promise<void>((resolve) => (release = resolve))
    const h = harness(
      vi.fn(async () => {
        await blocked
        return 'session-1'
      }),
    )
    await h.scheduler.load()
    const first = await h.scheduler.save(input)
    const second = await h.scheduler.save({ ...input, name: 'Second' })
    h.at('2026-10-26T09:00:30Z')
    h.running.add('session-1')
    const one = h.scheduler.tick()
    const two = h.scheduler.tick()
    release()
    await Promise.all([one, two])
    expect(h.start).toHaveBeenCalledTimes(1)
    const entries = h.scheduler.list()
    const ran = entries.find((entry) => entry.schedule.id === first.schedule.id)!
    const skipped = entries.find((entry) => entry.schedule.id === second.schedule.id)!
    expect(ran.history).toHaveLength(1)
    expect(ran.history[0]).toMatchObject({ outcome: 'started' })
    expect(skipped.history).toHaveLength(1)
    expect(skipped.history[0]).toMatchObject({ outcome: 'skipped' })
  })

  it('a failed write does not block the next one', async () => {
    const folder = join(dir, 'later')
    const scheduler = new Scheduler({
      file: join(folder, 'schedules.json'),
      now: () => Date.parse('2026-10-26T08:00:00Z'),
      tz: 'UTC',
      start: async () => 'session-1',
      isRunning: () => false,
      emit: () => {},
    })
    await scheduler.load()
    await expect(scheduler.save(input)).rejects.toThrow(/ENOENT/)
    await mkdir(folder)
    await scheduler.save({ ...input, name: 'Second' })
    const stored = JSON.parse(await readFile(join(folder, 'schedules.json'), 'utf8'))
    expect(stored.schedules.map((entry: { name: string }) => entry.name)).toEqual([
      'Morning review',
      'Second',
    ])
  })

  it('the timer tolerates a failing write', async () => {
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {})
    const scheduler = new Scheduler({
      file: join(dir, 'missing', 'schedules.json'),
      tz: 'UTC',
      start: async () => 'session-1',
      isRunning: () => false,
      emit: () => {},
    })
    await scheduler.load()
    scheduler.start()
    await new Promise((resolve) => setTimeout(resolve, 50))
    scheduler.stop()
    expect(errors).toHaveBeenCalled()
    errors.mockRestore()
  })

  it('emits after saving and enabling, and refuses an unknown id', async () => {
    const h = harness()
    await h.scheduler.load()
    const entry = await h.scheduler.save(input)
    expect(h.events).toEqual([{ type: 'schedules-changed' }])
    await h.scheduler.setEnabled(entry.schedule.id, false)
    expect(h.events).toHaveLength(2)
    expect(h.scheduler.list()[0].schedule.enabled).toBe(false)
    await expect(h.scheduler.setEnabled('gone', true)).rejects.toThrow(
      'This scheduled task no longer exists.',
    )
  })

  it('a task removed during a slow start leaves no history', async () => {
    let release = () => {}
    const blocked = new Promise<void>((resolve) => (release = resolve))
    const h = harness(
      vi.fn(async () => {
        await blocked
        return 'session-1'
      }),
    )
    await h.scheduler.load()
    const entry = await h.scheduler.save({ ...input, preset: 'manual' })
    const running = h.scheduler.runNow(entry.schedule.id)
    await h.scheduler.remove(entry.schedule.id)
    release()
    await running
    expect(h.scheduler.list()).toEqual([])
    const stored = JSON.parse(await readFile(join(dir, 'schedules.json'), 'utf8'))
    expect(stored.history).toEqual({})
  })
})
