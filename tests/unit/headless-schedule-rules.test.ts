import { describe, expect, it } from 'vitest'
import {
  checkCron,
  cronFor,
  dueTime,
  nextRun,
  type Schedule,
} from '../../src/headless/schedule-rules'

const base: Schedule = {
  id: 'a',
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
  createdAt: Date.UTC(2026, 9, 1),
}
const at = (iso: string) => Date.parse(iso)

describe('schedule rules', () => {
  it('turns each preset into a cron expression', () => {
    expect(cronFor({ ...base, preset: 'hourly', minute: 15 })).toBe('15 * * * *')
    expect(cronFor(base)).toBe('0 9 * * *')
    expect(cronFor({ ...base, preset: 'weekdays' })).toBe('0 9 * * 1-5')
    expect(cronFor({ ...base, preset: 'weekly', weekday: 3 })).toBe('0 9 * * 3')
    expect(cronFor({ ...base, preset: 'custom', cron: '30 6 1 * *' })).toBe('30 6 1 * *')
    expect(cronFor({ ...base, preset: 'manual' })).toBeNull()
  })

  it('accepts a custom cron at most once an hour and names each refusal', () => {
    expect(checkCron('15 9 * * 1')).toBeUndefined()
    expect(checkCron('0 */2 * * *')).toBeUndefined()
    expect(checkCron('0 9 * *')).toMatch(/five fields/)
    expect(checkCron('*/5 * * * *')).toMatch(/at most once an hour/)
    expect(checkCron('0,30 9 * * *')).toMatch(/at most once an hour/)
    expect(checkCron('* 9 * * *')).toMatch(/at most once an hour/)
    const unreadable = 'mMac could not read this schedule. Check that each field is in range.'
    expect(checkCron('0 25 * * *')).toBe(unreadable)
    expect(checkCron('0 9 32 * *')).toBe(unreadable)
    expect(checkCron('0 9 * 13 *')).toBe(unreadable)
  })

  it('gives the latest fire time since the last check, within seven days', () => {
    const now = at('2026-10-26T09:00:30Z')
    expect(dueTime(base, at('2026-10-26T08:59:30Z'), now, 'UTC')).toBe(at('2026-10-26T09:00:00Z'))
    expect(dueTime(base, at('2026-10-26T09:00:10Z'), now, 'UTC')).toBeNull()
    // Never a fire time after now, even less than a second after.
    expect(
      dueTime(base, at('2026-10-26T08:59:00Z'), at('2026-10-26T08:59:59.500Z'), 'UTC'),
    ).toBeNull()
    // A wake after three days catches up once, for the latest missed time.
    expect(dueTime(base, at('2026-10-23T10:00:00Z'), at('2026-10-26T08:00:00Z'), 'UTC')).toBe(
      at('2026-10-25T09:00:00Z'),
    )
    // Nothing older than seven days.
    const weekly = { ...base, preset: 'weekly' as const, weekday: 1 }
    expect(dueTime(weekly, at('2026-10-01T00:00:00Z'), at('2026-10-26T08:00:00Z'), 'UTC')).toBe(
      at('2026-10-19T09:00:00Z'),
    )
    expect(dueTime(weekly, 0, at('2026-10-26T08:59:00Z'), 'UTC')).toBe(at('2026-10-19T09:00:00Z'))
    // A last fire more than seven days old never comes due.
    const monthly = { ...base, preset: 'custom' as const, cron: '0 9 1 * *' }
    expect(dueTime(monthly, 0, at('2026-10-11T00:00:00Z'), 'UTC')).toBeNull()
    expect(dueTime({ ...base, preset: 'manual' }, 0, now, 'UTC')).toBeNull()
    expect(dueTime({ ...base, enabled: false }, 0, now, 'UTC')).toBeNull()
  })

  // Walk minute ticks the way the scheduler does: each check passes the previous check's time.
  const dueOver = (schedule: Schedule, from: string, to: string, tz: string) => {
    const due: number[] = []
    for (let t = at(from); t < at(to); t += 60_000) {
      const time = dueTime(schedule, t, t + 60_000, tz)
      if (time !== null) due.push(time)
    }
    return due
  }

  it('runs a task once when daylight saving changes, at the time nextRun gives', () => {
    const tz = 'America/Los_Angeles'
    // 2026-03-08: 2:30 PST does not exist, so a daily 2:30 runs at 3:30 PDT.
    const spring = { ...base, hour: 2, minute: 30 }
    expect(nextRun(spring, at('2026-03-07T12:00:00Z'), tz)).toBe(at('2026-03-08T10:30:00Z'))
    expect(dueOver(spring, '2026-03-08T07:00:00Z', '2026-03-08T14:00:00Z', tz)).toEqual([
      at('2026-03-08T10:30:00Z'),
    ])
    // 2026-11-01: 1:30 happens at 08:30Z (PDT) and again at 09:30Z (PST); a daily 1:30 runs once.
    const fall = { ...base, hour: 1, minute: 30 }
    expect(nextRun(fall, at('2026-10-31T12:00:00Z'), tz)).toBe(at('2026-11-01T08:30:00Z'))
    expect(nextRun(fall, at('2026-11-01T09:00:00Z'), tz)).toBe(at('2026-11-02T09:30:00Z'))
    expect(dueOver(fall, '2026-11-01T07:00:00Z', '2026-11-01T12:00:00Z', tz)).toEqual([
      at('2026-11-01T08:30:00Z'),
    ])
  })

  it('keeps the same rule in zones thirteen or more hours ahead of UTC', () => {
    const daily = { ...base, hour: 2, minute: 30 }
    // Auckland, 2026-04-05: 2:30 happens at 13:30Z (NZDT) and again at 14:30Z (NZST); the first.
    expect(
      dueOver(daily, '2026-04-04T10:00:00Z', '2026-04-04T18:00:00Z', 'Pacific/Auckland'),
    ).toEqual([at('2026-04-04T13:30:00Z')])
    // Auckland, 2026-09-27: 2:30 NZST does not exist, so it runs at 3:30 NZDT.
    expect(
      dueOver(daily, '2026-09-26T10:00:00Z', '2026-09-26T18:00:00Z', 'Pacific/Auckland'),
    ).toEqual([at('2026-09-26T14:30:00Z')])
    // Chatham on an ordinary day: 2:30 at UTC+12:45.
    expect(
      dueOver(daily, '2026-07-14T10:00:00Z', '2026-07-14T18:00:00Z', 'Pacific/Chatham'),
    ).toEqual([at('2026-07-14T13:45:00Z')])
  })

  it('runs an hourly task every real hour across a daylight-saving change', () => {
    const tz = 'America/Los_Angeles'
    const hourly = { ...base, preset: 'hourly' as const, minute: 15 }
    // 2026-11-01 is 25 hours long: 1:15 runs at 08:15Z (PDT) and again at 09:15Z (PST).
    const fall = dueOver(hourly, '2026-11-01T07:00:00Z', '2026-11-02T08:00:00Z', tz)
    expect(fall).toHaveLength(25)
    expect(fall).toContain(at('2026-11-01T08:15:00Z'))
    expect(fall).toContain(at('2026-11-01T09:15:00Z'))
    // 2026-03-08 is 23 hours long, with no 2:15.
    const spring = dueOver(hourly, '2026-03-08T08:00:00Z', '2026-03-09T07:00:00Z', tz)
    expect(spring).toHaveLength(23)
    expect(new Set(spring.map((t) => t % (60 * 60 * 1000)))).toEqual(new Set([15 * 60 * 1000]))
    expect(nextRun(hourly, at('2026-11-01T08:15:00Z'), tz)).toBe(at('2026-11-01T09:15:00Z'))
    // A custom cron with hour * keeps its day rule: Sundays only.
    const sundays = { ...base, preset: 'custom' as const, cron: '15 * * * 0' }
    expect(dueOver(sundays, '2026-11-01T07:00:00Z', '2026-11-02T08:00:00Z', tz)).toHaveLength(25)
    expect(nextRun(sundays, at('2026-11-02T07:15:00Z'), tz)).toBe(at('2026-11-08T08:15:00Z'))
  })

  it('catches up once after a long sleep, with a time from the last seven days', () => {
    const now = at('2026-10-26T12:00:00Z')
    const due = dueTime(base, now - 10 * 24 * 60 * 60 * 1000, now, 'UTC')
    expect(due).toBe(at('2026-10-26T09:00:00Z'))
    expect(due! >= now - 7 * 24 * 60 * 60 * 1000).toBe(true)
  })

  it('gives the next run, or null for manual', () => {
    expect(nextRun(base, at('2026-10-26T09:00:00Z'), 'UTC')).toBe(at('2026-10-27T09:00:00Z'))
    expect(nextRun({ ...base, preset: 'manual' }, at('2026-10-26T09:00:00Z'), 'UTC')).toBeNull()
  })
})
