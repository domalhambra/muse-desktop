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
    expect(dueTime({ ...base, preset: 'manual' }, 0, now, 'UTC')).toBeNull()
    expect(dueTime({ ...base, enabled: false }, 0, now, 'UTC')).toBeNull()
  })

  it('gives the next run, or null for manual', () => {
    expect(nextRun(base, at('2026-10-26T09:00:00Z'), 'UTC')).toBe(at('2026-10-27T09:00:00Z'))
    expect(nextRun({ ...base, preset: 'manual' }, at('2026-10-26T09:00:00Z'), 'UTC')).toBeNull()
  })
})
