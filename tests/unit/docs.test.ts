import { describe, expect, it } from 'vitest'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

// The documentation standard's check, run with the suite. `docs/README.md`
// must index every document under `docs/`, every path the guide and the docs
// quote must exist, and `CLAUDE.md` must stay under its token budget.
// `scripts/docs_check.py` is vendored byte for byte from Dom's workspace;
// this test only runs it. Two gitignored folders may be absent: `release/`,
// the build output `README.md` names, and `.cache/`, where
// `docs/releasing.md` says the Sparkle tools land.
const root = fileURLToPath(new URL('../..', import.meta.url))

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
  'release/',
  '--known-absent',
  '.cache/',
]

describe('documentation', () => {
  it('is indexed, quotes only paths that exist, and keeps the guide under budget', () => {
    const run = spawnSync('python3', args, { cwd: root, encoding: 'utf8' })
    expect(run.error, 'python3 must be on PATH').toBeUndefined()
    expect(run.status, `docs_check exited ${run.status}\n${run.stdout}${run.stderr}`).toBe(0)
  })
})
