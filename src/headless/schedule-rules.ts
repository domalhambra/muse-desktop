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
  // prev() is strictly before currentDate, so start one second past now to include it, then
  // step back once more if that found a fire time in the second after now.
  const times = CronExpressionParser.parse(expression, { currentDate: new Date(now + 1000), tz })
  let latest = times.prev().toDate().getTime()
  if (latest > now) latest = times.prev().toDate().getTime()
  return latest > since && latest >= now - SEVEN_DAYS ? latest : null
}

export function nextRun(schedule: Schedule, after: number, tz?: string): number | null {
  const expression = cronFor(schedule)
  if (!expression) return null
  return CronExpressionParser.parse(expression, { currentDate: new Date(after), tz })
    .next()
    .toDate()
    .getTime()
}
