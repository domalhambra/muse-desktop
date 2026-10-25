import { chmod, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// A fake gh for the tests. No test may reach the real gh: the env this returns has a PATH that
// holds only the fake's own folder (with a link to this node, so its shebang runs), and every
// call must also pass `folders: []` so ghEnvironment adds no Homebrew folders.

let log = ''
const folders: string[] = []

/**
 * A fake gh on PATH: it logs its arguments, and prints the output whose key is a prefix of its
 * joined arguments. With `failure` it prints that to stderr and exits 1. With no matching key it
 * fails as gh does for a branch without a PR.
 */
export async function fakeGh(
  outputs: Record<string, unknown>,
  failure?: string,
): Promise<NodeJS.ProcessEnv> {
  const dir = await mkdtemp(join(tmpdir(), 'mmac-gh-'))
  folders.push(dir)
  log = join(dir, 'calls.log')
  const script = `#!/usr/bin/env node
const { appendFileSync } = require('node:fs')
const args = process.argv.slice(2)
appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + '\\n')
const failure = ${JSON.stringify(failure ?? null)}
if (failure) { process.stderr.write(failure); process.exit(1) }
const outputs = ${JSON.stringify(outputs)}
const key = Object.keys(outputs).find((prefix) => args.join(' ').startsWith(prefix))
if (key === undefined) { process.stderr.write('no pull requests found for branch'); process.exit(1) }
process.stdout.write(typeof outputs[key] === 'string' ? outputs[key] : JSON.stringify(outputs[key]))
`
  await writeFile(join(dir, 'gh'), script)
  await chmod(join(dir, 'gh'), 0o755)
  await symlink(process.execPath, join(dir, 'node'))
  return { ...process.env, PATH: dir }
}

/** The argument lists the newest fake gh was called with, in order. */
export const calls = async () =>
  (await readFile(log, 'utf8'))
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line) as string[])

/** Deletes every fake gh folder made so far. */
export async function removeFakeGh() {
  await Promise.all(folders.splice(0).map((folder) => rm(folder, { recursive: true, force: true })))
}

/** gh's JSON for one open PR, as `gh pr view --json` prints it. */
export const raw = {
  number: 9,
  title: 'mMac now shows your usage limits',
  url: 'https://github.com/o/r/pull/9',
  state: 'OPEN',
  isDraft: false,
  reviewDecision: null,
  mergeStateStatus: 'CLEAN',
  baseRefName: 'main',
  headRefName: 'usage',
  mergedAt: null,
  mergeCommit: null,
  body: '## Summary\nShows limits.',
  files: [{ path: 'docs/a.md' }],
  statusCheckRollup: [
    { __typename: 'CheckRun', name: 'check', status: 'COMPLETED', conclusion: 'SUCCESS' },
    { __typename: 'CheckRun', name: 'lint', status: 'IN_PROGRESS', conclusion: '' },
    { __typename: 'CheckRun', name: 'e2e', status: 'COMPLETED', conclusion: 'FAILURE' },
    { __typename: 'CheckRun', name: 'docs', status: 'COMPLETED', conclusion: 'SKIPPED' },
    { __typename: 'StatusContext', context: 'netlify', state: 'PENDING' },
  ],
}
