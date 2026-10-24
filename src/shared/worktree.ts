// Muse Code creates per-session worktrees at `<project>/.muse/worktrees/<name>`
// (`session/start` with `worktree: { mode: 'create' }`). These helpers recognize
// that layout lexically so a worktree is treated as part of its parent project.

const worktreePattern = /^(.*)[/\\]\.muse[/\\]worktrees[/\\]([^/\\]+)[/\\]?$/

export function worktreeParent(path: string | null | undefined): string | null {
  const match = path ? worktreePattern.exec(path) : null
  return match && match[1] ? match[1] : null
}

export function projectRoot(path: string): string {
  return worktreeParent(path) ?? path
}
