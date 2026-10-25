import { realpath } from 'node:fs/promises'

// Errors a person reads in mMac are plain sentences. Two raw shapes reached the screen in the
// M4b live run: Node's "ENOENT: no such file or directory, realpath '…'" for a folder that was
// removed, and Muse's "<method> command <id> rejected: <reason>" for a refused command. The raw
// text goes to stderr, the backend's log; wire.ts does not log failures.

/** Sentences for the `commandRejected` reasons mMac can meet. Others get REFUSED. */
const REFUSALS: Record<string, string> = {
  compaction_unavailable: 'This model cannot compact the conversation.',
  missing_run: 'There is no conversation history to compact yet.',
}
const REFUSED = 'Muse Code refused this request.'
const WORKTREE_GONE = 'This conversation’s worktree folder no longer exists.'
const FOLDER_GONE = 'This folder no longer exists.'
const FILE_GONE = 'This file no longer exists.'

const REJECTED = /^\S+ command \S+ rejected: ([a-z0-9_]+)$/
/** A Muse worktree root: `<project>/.muse/worktrees/<name>`, with nothing after the name. */
const WORKTREE_ROOT = /[/\\]\.muse[/\\]worktrees[/\\][^/\\]+[/\\]?$/

/** The fs calls whose ENOENT means a path is gone. A failed spawn (`spawn git`) is not one. */
const PATH_CALLS = new Set(['realpath', 'open', 'stat', 'lstat', 'scandir'])

function missing(error: unknown): error is NodeJS.ErrnoException {
  const fs = error as NodeJS.ErrnoException
  return error instanceof Error && fs.code === 'ENOENT' && PATH_CALLS.has(fs.syscall ?? '')
}

/** realFolder's error for a folder that is gone. Its message is already a plain sentence. */
export class MissingFolder extends Error {}

/**
 * realpath for a project, worktree or conversation folder. A missing folder becomes a plain
 * sentence: the worktree one when `path` is a Muse worktree's root, else the folder one.
 */
export async function realFolder(path: string): Promise<string> {
  try {
    return await realpath(path)
  } catch (error) {
    if (!missing(error)) throw error
    console.error(`A folder is missing: ${error.message}`)
    throw new MissingFolder(WORKTREE_ROOT.test(path) ? WORKTREE_GONE : FOLDER_GONE)
  }
}

/**
 * The error to send to mMac in place of `error`. The folder call sites use realFolder, so an
 * ENOENT that reaches this point is a file inside a folder that exists, such as one the Files
 * tab reads. A command Muse rejected becomes a sentence. Any other error is returned as it is.
 */
export function plainError(error: unknown): unknown {
  if (!(error instanceof Error)) return error
  if (missing(error)) {
    console.error(`A file is missing: ${error.message}`)
    return new Error(FILE_GONE)
  }
  const rejected = REJECTED.exec(error.message)
  if (rejected) {
    console.error(`Muse rejected a command: ${rejected[1]}`)
    return new Error(REFUSALS[rejected[1]] ?? REFUSED)
  }
  return error
}
