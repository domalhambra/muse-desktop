import { chmod, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises'
import { execFile } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { afterEach, beforeEach, expect, it } from 'vitest'
import { discoverCli } from '../../src/main/cli'

// mMac reads the login shell once and starts the backend with its environment. discoverCli
// then runs "$SHELL -ilc …" again; server.ts points SHELL at this stub so that read is instant.
const stub = fileURLToPath(new URL('../../src/headless/login-env.sh', import.meta.url))

let dir = ''
const saved = { ...process.env }
beforeEach(async () => {
  dir = await realpath(await mkdtemp(join(tmpdir(), 'mmac-login-env-')))
})
afterEach(async () => {
  process.env = { ...saved }
  await rm(dir, { recursive: true, force: true })
})

it('answers discoverCli from the environment mMac passed, with the real shell', async () => {
  const muse = join(dir, 'muse')
  await writeFile(muse, '#!/bin/sh\necho "Muse Code 9.9.9"\n')
  await chmod(muse, 0o755)
  process.env.PATH = `${dir}:/usr/bin:/bin`
  process.env.SHELL = stub
  process.env.MMAC_LOGIN_SHELL = '/bin/zsh'
  process.env.MMAC_TEST_MARKER = 'from mMac'
  const found = await discoverCli()
  expect(found.path).toBe(muse)
  expect(found.version).toBe('9.9.9')
  expect(found.shellWarning).toBeUndefined()
  expect(found.environment.SHELL).toBe('/bin/zsh')
  expect(found.environment.MMAC_TEST_MARKER).toBe('from mMac')
})

it('passes any other command to the real shell', async () => {
  const { stdout } = await promisify(execFile)(stub, ['-ilc', 'echo hi'], {
    env: { ...process.env, HOME: dir, ZDOTDIR: dir, MMAC_LOGIN_SHELL: '/bin/sh' },
  })
  expect(stdout.trim()).toBe('hi')
})
