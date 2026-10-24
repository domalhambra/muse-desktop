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
    expect(checkCron('0 25 * * *')).toMatch(/^Muse could not read this schedule/)
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

  // These pin cron-parser 5.10.2's daylight-saving behaviour, so an upgrade cannot change it
  // silently. They record what the code does today, not what scheduled tasks should do: on the
  // spring-forward day dueTime skips the 2:30 run that nextRun predicts, and on the fall-back
  // day dueTime returns 1:30 twice, an hour apart, where nextRun skips the repeat.
  it('pins the library behaviour across daylight-saving changes in Los Angeles', () => {
    const tz = 'America/Los_Angeles'
    const spring = { ...base, hour: 2, minute: 30 }
    // 2026-03-08: 2:30 PST does not exist; nextRun gives 3:30 PDT.
    expect(nextRun(spring, at('2026-03-07T12:00:00Z'), tz)).toBe(at('2026-03-08T10:30:00Z'))
    expect(dueTime(spring, at('2026-03-08T10:29:30Z'), at('2026-03-08T10:30:30Z'), tz)).toBeNull()
    expect(dueTime(spring, at('2026-03-08T06:00:00Z'), at('2026-03-08T18:00:00Z'), tz)).toBeNull()

    const fall = { ...base, hour: 1, minute: 30 }
    // 2026-11-01: 1:30 happens at 08:30Z (PDT) and again at 09:30Z (PST).
    expect(nextRun(fall, at('2026-10-31T12:00:00Z'), tz)).toBe(at('2026-11-01T08:30:00Z'))
    expect(nextRun(fall, at('2026-11-01T08:30:00Z'), tz)).toBe(at('2026-11-02T09:30:00Z'))
    expect(dueTime(fall, at('2026-11-01T08:29:30Z'), at('2026-11-01T08:30:30Z'), tz)).toBe(
      at('2026-11-01T08:30:00Z'),
    )
    expect(dueTime(fall, at('2026-11-01T09:29:30Z'), at('2026-11-01T09:30:30Z'), tz)).toBe(
      at('2026-11-01T09:30:00Z'),
    )
  })

  it('gives the next run, or null for manual', () => {
    expect(nextRun(base, at('2026-10-26T09:00:00Z'), 'UTC')).toBe(at('2026-10-27T09:00:00Z'))
    expect(nextRun({ ...base, preset: 'manual' }, at('2026-10-26T09:00:00Z'), 'UTC')).toBeNull()
  })
})
