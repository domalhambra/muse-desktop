import { describe, expect, it } from 'vitest'
import { Wire, type Method } from '../../src/headless/wire'

function harness(methods: Record<string, Method> = {}) {
  const lines: string[] = []
  const wire = new Wire((line) => lines.push(line), new Map(Object.entries(methods)))
  const sent = () => lines.map((line) => JSON.parse(line) as Record<string, unknown>)
  return { wire, lines, sent }
}

describe('headless wire', () => {
  it('replies with the value a method returns', async () => {
    const { wire, sent } = harness({ add: (a, b) => (a as number) + (b as number) })
    await wire.receive(JSON.stringify({ id: 7, method: 'add', args: [2, 3] }))
    expect(sent()).toEqual([{ id: 7, ok: true, value: 5 }])
  })

  it('replies null when a method returns nothing', async () => {
    const { wire, sent } = harness({ quiet: () => undefined })
    await wire.receive(JSON.stringify({ id: 1, method: 'quiet' }))
    expect(sent()).toEqual([{ id: 1, ok: true, value: null }])
  })

  it('replies with the error message when a method throws or does not exist', async () => {
    const { wire, sent } = harness({
      fail: () => {
        throw new Error('Send start first.')
      },
    })
    await wire.receive(JSON.stringify({ id: 1, method: 'fail', args: [] }))
    await wire.receive(JSON.stringify({ id: 2, method: 'missing', args: [] }))
    expect(sent()).toEqual([
      { id: 1, ok: false, error: 'Send start first.' },
      { id: 2, ok: false, error: 'Unknown method: missing' },
    ])
  })

  it('reports an unreadable line as an error event and ignores blank lines', async () => {
    const { wire, sent } = harness()
    await wire.receive('not json')
    await wire.receive(JSON.stringify({ id: 'x', method: 'sessions' }))
    await wire.receive('   ')
    const lines = sent()
    expect(lines).toHaveLength(2)
    for (const line of lines) expect(line.event).toMatchObject({ type: 'error' })
  })

  it('sends an Ask and resolves it with the answer', async () => {
    const { wire, sent } = harness()
    const choice = wire.ask({
      kind: 'confirm',
      title: 'Trust this project?',
      message: 'Work with Muse in “p”?',
      buttons: ['Trust project', 'Cancel'],
    })
    expect(sent()).toEqual([
      {
        ask: 1,
        kind: 'confirm',
        title: 'Trust this project?',
        message: 'Work with Muse in “p”?',
        buttons: ['Trust project', 'Cancel'],
      },
    ])
    await wire.receive(JSON.stringify({ answer: 1, choice: 0 }))
    await expect(choice).resolves.toBe(0)
  })

  it('answers every open Ask with -1 on quit', async () => {
    const { wire } = harness()
    const first = wire.ask({ kind: 'confirm', title: 'A', message: 'A', buttons: ['OK', 'Cancel'] })
    const second = wire.ask({
      kind: 'confirm',
      title: 'B',
      message: 'B',
      buttons: ['OK', 'Cancel'],
    })
    wire.cancelAsks()
    await expect(first).resolves.toBe(-1)
    await expect(second).resolves.toBe(-1)
  })

  it('drains requests still in flight', async () => {
    let finish = () => {}
    const { wire, sent } = harness({
      slow: () =>
        new Promise<void>((resolve) => {
          finish = () => resolve()
        }),
    })
    void wire.receive(JSON.stringify({ id: 1, method: 'slow' }))
    const drained = wire.drain()
    expect(sent()).toEqual([])
    finish()
    await drained
    expect(sent()).toEqual([{ id: 1, ok: true, value: null }])
  })

  it('writes one JSON object per line', () => {
    const { wire, lines } = harness()
    wire.emit({ type: 'sessions-changed' })
    expect(lines).toEqual(['{"event":{"type":"sessions-changed"}}\n'])
  })
})
