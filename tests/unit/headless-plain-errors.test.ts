import { describe, expect, it } from 'vitest'
import { plainError } from '../../src/headless/plain-errors'

const plain = (message: string) => (plainError(new Error(message)) as Error).message

describe('plainError refusals', () => {
  it.each([
    ['turn/cancel', 'missing_run', 'No turn is running.'],
    ['session/compact', 'missing_run', 'There is no conversation history to compact yet.'],
    ['session/compact', 'compaction_unavailable', 'This model cannot compact the conversation.'],
    ['workflow/pause', 'missing_run', 'This workflow is no longer running.'],
    ['workflow/resume', 'missing_run', 'This workflow is no longer running.'],
    ['workflow/cancel', 'missing_run', 'This workflow is no longer running.'],
    ['goal/pause', 'missing_goal', 'This conversation has no goal.'],
    ['goal/pause', 'invalid_goal_state', 'The goal cannot do that in its current state.'],
    ['subagent/stop', 'invalid_target', 'This subagent has already finished.'],
    ['task/stop', 'invalid_target', 'Muse Code refused this request.'],
    ['turn/start', 'something_new', 'Muse Code refused this request.'],
  ])('%s %s', (method, reason, sentence) => {
    expect(plain(`${method} command 01a rejected: ${reason}`)).toBe(sentence)
  })

  it('explains a fork from before a goal changed', () => {
    expect(plain('invalid fork boundary for session 01a: HistoricalGoalCutUnsupported')).toBe(
      'Muse cannot fork from before this conversation’s goal changed. Fork from the latest turn.',
    )
  })

  it('explains any other fork boundary', () => {
    expect(plain('invalid fork boundary for session 01a: forkBoundaryInvalid')).toBe(
      'Muse cannot fork from this turn. It may not have finished.',
    )
  })
})
