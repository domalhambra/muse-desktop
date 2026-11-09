import { randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { open } from 'node:fs/promises'
import { basename, extname } from 'node:path'
import type { Attachment } from '../shared/protocol'

// Files chosen for the next message, as src/main/index.ts's `attachments`, `remove-attachment`
// and `send` handlers keep them. Copied, not shared: index.ts is deleted at the end of M4a.
// The paths stay here; mMac holds only the ids, names, kinds and sizes. One fix on purpose:
// when one file in a call fails, none of the call's files is kept. Electron kept the earlier
// ones and never returned their ids.

const MB = 1024 * 1024
const MAX_FILE = 2 * MB
const MAX_MESSAGE = 4 * MB
const MAX_TEXT = 200 * 1024
// Base64 makes data about 4/3 larger; Electron counts every file, text too, at 1.4.
const ENCODED = 1.4

const mediaTypes: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
}

const EXPIRED = 'An attachment expired. Select it again.'

/**
 * Any fs error that carries a string code (ENOENT, EACCES, EPERM, EISDIR, ENOTDIR, ELOOP, ENXIO
 * and the rest): the person never sees its text, which holds the path.
 */
function unreadable(error: unknown) {
  return typeof (error as { code?: unknown } | null)?.code === 'string'
}

/**
 * Opens the path once and checks and reads through that handle, so a swap between the check
 * and the read cannot slip through. O_NONBLOCK keeps a FIFO from blocking the open. Returns
 * `undefined` when the path is not a regular file or is over the limit; `data` is read only
 * when `read` is true.
 */
async function inspect(path: string, read: boolean) {
  const handle = await open(path, constants.O_RDONLY | constants.O_NONBLOCK)
  try {
    const info = await handle.stat()
    if (!info.isFile() || info.size > MAX_FILE) return undefined
    if (!read) return { size: info.size, data: Buffer.alloc(0) }
    // At most one byte past the limit, so a file that grew hugely after the stat cannot fill
    // memory before it is refused.
    const buffer = Buffer.alloc(MAX_FILE + 1)
    let length = 0
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length)
      if (!bytesRead) break
      length += bytesRead
    }
    if (length > MAX_FILE) return undefined
    return { size: info.size, data: buffer.subarray(0, length) }
  } finally {
    await handle.close()
  }
}

type Chosen = { attachment: Attachment; path: string }

export class Attachments {
  private selected = new Map<string, Chosen>()

  /** `newId` names each file. Tests pass a counter; the default is a random UUID. */
  constructor(private readonly newId: () => string = randomUUID) {}

  /** Checks every path, then keeps them all, or none when one fails. */
  async register(paths: string[]): Promise<Attachment[]> {
    if (paths.length > 5) throw new Error('Select up to five files at a time.')
    const chosen: Chosen[] = []
    for (const path of paths) {
      const notFile = new Error(`${basename(path)} must be a file smaller than 2 MB.`)
      const info = await inspect(path, false).catch((error) => {
        throw unreadable(error) ? notFile : error
      })
      if (!info) throw notFile
      chosen.push({
        path,
        attachment: {
          id: this.newId(),
          name: basename(path),
          kind: /\.(png|jpe?g|webp|gif)$/i.test(path) ? 'image' : 'text',
          size: info.size,
        },
      })
    }
    for (const entry of chosen) this.selected.set(entry.attachment.id, entry)
    return chosen.map((entry) => entry.attachment)
  }

  /** Forgets a file mMac no longer shows. */
  remove(id: string) {
    this.selected.delete(id)
  }

  /**
   * The message's parts and display text. Each file is read now, not when it was chosen, so it
   * sends its current content. A file that grew past a limit since, or vanished, fails here,
   * with the draft and the ids kept.
   */
  async build(text: string, ids: string[]) {
    const parts: Record<string, unknown>[] = [{ type: 'text', text }]
    const names: string[] = []
    let bytes = Buffer.byteLength(text)
    for (const id of ids) {
      const chosen = this.selected.get(id)
      if (!chosen) throw new Error(EXPIRED)
      const read = await inspect(chosen.path, true).catch((error) => {
        throw unreadable(error) ? new Error(EXPIRED) : error
      })
      if (!read) throw new Error('Attachments must be 2 MB or smaller.')
      const { data } = read
      bytes += data.length * ENCODED
      if (bytes > MAX_MESSAGE) throw new Error('This message exceeds the 4 MB attachment limit.')
      if (chosen.attachment.kind === 'image') {
        parts.push({
          type: 'image',
          mediaType: mediaTypes[extname(chosen.path).toLowerCase()],
          base64Data: data.toString('base64'),
        })
      } else {
        if (data.includes(0))
          throw new Error(
            `${chosen.attachment.name} is a binary file. Attach an image or a text file.`,
          )
        if (data.length > MAX_TEXT) throw new Error('Text attachments must be 200 KB or smaller.')
        parts.push({
          type: 'text',
          text: `Attached file: ${chosen.attachment.name}\n\n${data.toString('utf8')}`,
        })
      }
      names.push(chosen.attachment.name)
    }
    return { parts, display: [text, ...names.map((name) => `[Attached: ${name}]`)].join('\n') }
  }

  /** Forgets the files of a message Muse accepted. */
  forget(ids: string[]) {
    for (const id of ids) this.selected.delete(id)
  }
}
