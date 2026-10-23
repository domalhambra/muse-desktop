import { describe, expect, it } from 'vitest'
import { spawnSync } from 'node:child_process'
import { lstatSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

// The documentation standard's check, run with the suite. `docs/README.md`
// must index every document under `docs/`, every path the guide and the docs
// quote must exist, and `CLAUDE.md` must stay under its token budget.
// `scripts/docs_check.py` is vendored byte for byte from Dom's workspace;
// this test only runs it. `.cache/` is gitignored and may be absent. The other
// names left with Electron's shell in M4a: `docs/decisions.md` quotes them in
// its history, and the upstream-sync step in `docs/changing-things.md` names
// the folders. Add a name here only for such a quote, never for a live doc.
// In a linked worktree, `.git` is a file that names the main checkout's Git
// folder, so the `.git/` paths the docs quote exist only in the main checkout.
// That exception applies in a linked worktree only.
const root = fileURLToPath(new URL('../..', import.meta.url))

/** True when `.git` is a file: a linked worktree, not the main checkout. */
function linkedWorktree() {
  try {
    return lstatSync(join(root, '.git')).isFile()
  } catch {
    return false
  }
}

const removedWithElectron = [
  'src/renderer/',
  'src/preload/',
  'tests/e2e/',
  'src/main/index.ts',
  'src/main/updates.ts',
  'electron-builder.yml',
  'scripts/sparkle-config.json',
  'releasing.md',
  'release-readiness.md',
]

const args = [
  'scripts/docs_check.py',
  root,
  '--require',
  'docs/architecture.md',
  '--require',
  'docs/changing-things.md',
  '--require',
  'docs/decisions.md',
  '--known-absent',
  '.cache/',
  ...removedWithElectron.flatMap((name) => ['--known-absent', name]),
  ...(linkedWorktree() ? ['--known-absent', '.git/'] : []),
]

describe('documentation', () => {
  it('is indexed, quotes only paths that exist, and keeps the guide under budget', () => {
    const run = spawnSync('python3', args, { cwd: root, encoding: 'utf8' })
    expect(run.error, 'python3 must be on PATH').toBeUndefined()
    expect(run.status, `docs_check exited ${run.status}\n${run.stdout}${run.stderr}`).toBe(0)
  })
})
