import { CronExpressionParser } from 'cron-parser'
import { z } from 'zod'
import { approvalModeSchema } from '../shared/protocol'

// Scheduled tasks' pure rules: what a task is, when it fires, and when it last came due.
// src/headless/schedule.ts runs them; mMac's ScheduleRules formats what this returns.

export const presetSchema = z.enum(['hourly', 'daily', 'weekdays', 'weekly', 'manual', 'custom'])

export const scheduleSchema = z.object({
  id: z.string().min(1).max(100),
  name: z.string().trim().min(1).max(100),
  prompt: z.string().trim().min(1).max(20000),
  folder: z.string().min(1).max(4096),
  preset: presetSchema,
  minute: z.number().int().min(0).max(59),
  hour: z.number().int().min(0).max(23),
  weekday: z.number().int().min(0).max(6),
  cron: z.string().max(100).optional(),
  approvalMode: approvalModeSchema,
  modelId: z.string().nullable(),
  worktree: z.boolean(),
  enabled: z.boolean(),
  createdAt: z.number(),
})
export type Schedule = z.infer<typeof scheduleSchema>

const SEVEN_DAYS = 7 * 24 * 60 * 60 * 1000

export function cronFor(schedule: Schedule): string | null {
  const { minute: m, hour: h, weekday: d } = schedule
  switch (schedule.preset) {
    case 'hourly':
      return `${m} * * * *`
    case 'daily':
      return `${m} ${h} * * *`
    case 'weekdays':
      return `${m} ${h} * * 1-5`
    case 'weekly':
      return `${m} ${h} * * ${d}`
    case 'custom':
      return schedule.cron ?? null
    case 'manual':
      return null
  }
}

/** Undefined when the custom expression is usable; otherwise the message for the form. */
export function checkCron(expression: string): string | undefined {
  const fields = expression.trim().split(/\s+/)
  if (fields.length !== 5)
    return 'A custom schedule has five fields: minute, hour, day, month, weekday.'
  if (!/^\d{1,2}$/.test(fields[0]) || Number(fields[0]) > 59)
    return 'A custom schedule runs at most once an hour, so its minute must be one number from 0 to 59.'
  try {
    CronExpressionParser.parse(expression)
    return undefined
  } catch (error) {
    return `Muse could not read this schedule: ${error instanceof Error ? error.message : String(error)}`
  }
}

// Fire times are found in local wall-clock time, where cron-parser has no daylight-saving
// changes, and each wall time becomes one instant: a repeated time (fall back) is its first
// occurrence, and a skipped time (spring forward) moves forward by the gap. The mapping never
// goes back in time, so dueTime and nextRun agree and each wall time runs once.
// cron-parser 5.10.2's own tz handling skips or repeats times inside the changed hour.

const HOUR = 60 * 60 * 1000
const formatters = new Map<string, Intl.DateTimeFormat>()

/** The zone's offset from UTC at this instant, in milliseconds. */
function offsetAt(instant: number, tz: string | undefined): number {
  const key = tz ?? ''
  let format = formatters.get(key)
  if (!format) {
    format = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    })
    formatters.set(key, format)
  }
  const part: Record<string, number> = {}
  for (const { type, value } of format.formatToParts(instant)) part[type] = Number(value)
  const wall = Date.UTC(part.year, part.month - 1, part.day, part.hour, part.minute, part.second)
  return wall - Math.floor(instant / 1000) * 1000
}

const toWall = (instant: number, tz: string | undefined) => instant + offsetAt(instant, tz)

function fromWall(wall: number, tz: string | undefined): number {
  const before = wall - offsetAt(wall - 12 * HOUR, tz)
  const after = wall - offsetAt(wall + 12 * HOUR, tz)
  const valid = [before, after].filter((instant) => toWall(instant, tz) === wall)
  // Neither is valid in a skipped hour: the old offset moves the time forward by the gap.
  return valid.length > 0 ? Math.min(...valid) : before
}

/** Fire times as wall clock, read as if UTC, starting at the given wall time. */
const wallTimes = (expression: string, wall: number) =>
  CronExpressionParser.parse(expression, { currentDate: new Date(wall), tz: 'UTC' })

/**
 * The latest fire time after `since` and at or before `now`, no older than seven days: one run,
 * whether this is a minute tick, a restart or a wake. Null when nothing came due.
 */
export function dueTime(
  schedule: Schedule,
  since: number,
  now: number,
  tz?: string,
): number | null {
  const expression = schedule.enabled ? cronFor(schedule) : null
  if (!expression) return null
  const from = Math.max(since, now - SEVEN_DAYS)
  // Start past now by more than any offset change, then step back to the first time at or
  // before now. Instants never decrease as wall times increase, so that one is the latest.
  const times = wallTimes(expression, toWall(now, tz) + 3 * HOUR)
  for (;;) {
    const instant = fromWall(times.prev().toDate().getTime(), tz)
    if (instant <= now) return instant > from ? instant : null
  }
}

export function nextRun(schedule: Schedule, after: number, tz?: string): number | null {
  const expression = cronFor(schedule)
  if (!expression) return null
  const times = wallTimes(expression, toWall(after, tz) - 3 * HOUR)
  for (;;) {
    const instant = fromWall(times.next().toDate().getTime(), tz)
    if (instant > after) return instant
  }
}
