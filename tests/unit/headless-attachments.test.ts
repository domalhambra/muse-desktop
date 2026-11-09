import { mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { Attachments } from '../../src/headless/attachments'

// The class behind the backend's attachment methods. The backend tests cover every error
// string through the methods; this file covers what they cannot see: the ids.

let dir = ''
beforeEach(async () => {
  dir = await realpath(await mkdtemp(join(tmpdir(), 'mmac-attachments-')))
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

/** Ids in order, so a test can name the id a failed call used. */
function counter() {
  let next = 0
  return () => `id-${++next}`
}

describe('Attachments', () => {
  it('registers none of a call’s files when one fails', async () => {
    const attachments = new Attachments(counter())
    const good = join(dir, 'good.txt')
    await writeFile(good, 'ok')
    const folder = join(dir, 'notes')
    await mkdir(folder)
    await expect(attachments.register([good, folder])).rejects.toThrow(
      'notes must be a file smaller than 2 MB.',
    )
    // good.txt took id-1 in the failed call. It must not be held.
    await expect(attachments.build('', ['id-1'])).rejects.toThrow(
      'An attachment expired. Select it again.',
    )
    const [again] = await attachments.register([good])
    expect(again).toEqual({ id: 'id-2', name: 'good.txt', kind: 'text', size: 2 })
    expect(await attachments.build('', ['id-2'])).toEqual({
      parts: [
        { type: 'text', text: '' },
        { type: 'text', text: 'Attached file: good.txt\n\nok' },
      ],
      display: '\n[Attached: good.txt]',
    })
  })

  it('forgets removed and sent ids, and keeps the others', async () => {
    const attachments = new Attachments(counter())
    const path = join(dir, 'a.txt')
    await writeFile(path, 'a')
    await attachments.register([path, path, path])
    attachments.remove('id-1')
    attachments.forget(['id-2'])
    await expect(attachments.build('x', ['id-1'])).rejects.toThrow('An attachment expired.')
    await expect(attachments.build('x', ['id-2'])).rejects.toThrow('An attachment expired.')
    expect((await attachments.build('x', ['id-3'])).display).toBe('x\n[Attached: a.txt]')
  })

  it('reads each file at build time, not at register time', async () => {
    const attachments = new Attachments(counter())
    const path = join(dir, 'late.txt')
    await writeFile(path, 'before')
    await attachments.register([path])
    await writeFile(path, 'after')
    expect((await attachments.build('', ['id-1'])).parts[1]).toEqual({
      type: 'text',
      text: 'Attached file: late.txt\n\nafter',
    })
  })
})
