// Errors a person reads in mMac are plain sentences. Two raw shapes reached the screen in the
// M4b live run: Node's "ENOENT: no such file or directory, realpath '…'" for a folder that was
// removed, and Muse's "<method> command <id> rejected: <reason>" for a refused command.

/** Sentences for the `commandRejected` reasons mMac can meet. Others get REFUSED. */
const REFUSALS: Record<string, string> = {
  compaction_unavailable: 'This model cannot compact the conversation.',
  missing_run: 'There is no conversation history to compact yet.',
}
const REFUSED = 'Muse Code refused this request.'
const WORKTREE_GONE = 'This conversation’s worktree folder no longer exists.'
const FOLDER_GONE = 'This folder no longer exists.'

const REJECTED = /^\S+ command \S+ rejected: ([a-z0-9_]+)$/

/**
 * The error to send to mMac in place of `error`: a plain sentence for a missing folder that
 * realpath reported, or for a command Muse rejected. Any other error is returned as it is.
 */
export function plainError(error: unknown): unknown {
  if (!(error instanceof Error)) return error
  const fs = error as NodeJS.ErrnoException
  if (fs.code === 'ENOENT' && fs.syscall === 'realpath') {
    const path = typeof fs.path === 'string' ? fs.path : ''
    return new Error(/[/\\]\.muse[/\\]worktrees[/\\]/.test(path) ? WORKTREE_GONE : FOLDER_GONE)
  }
  const rejected = REJECTED.exec(error.message)
  if (rejected) {
    // The reason stays in the backend's log, never on the screen.
    console.error(`Muse rejected a command: ${rejected[1]}`)
    return new Error(REFUSALS[rejected[1]] ?? REFUSED)
  }
  return error
}
