import { chmod, access, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises'
import { execFile } from 'node:child_process'
import { constants } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { afterEach, beforeEach, expect, it } from 'vitest'
import { discoverCli } from '../../src/main/cli'
import { loginEnvShell } from '../../src/headless/login-env'

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

/** Runs discoverCli as server.ts sets it up: SHELL is the stub and mMac's environment is in place. */
async function discoverThroughStub(extra: Record<string, string>) {
  const muse = join(dir, 'muse')
  await writeFile(muse, '#!/bin/sh\necho "Muse Code 9.9.9"\n')
  await chmod(muse, 0o755)
  process.env.PATH = `${dir}:/usr/bin:/bin`
  process.env.SHELL = stub
  process.env.MMAC_LOGIN_SHELL = '/bin/zsh'
  Object.assign(process.env, extra)
  return { muse, found: await discoverCli() }
}

it('answers discoverCli from the environment mMac passed, with the real shell', async () => {
  const { muse, found } = await discoverThroughStub({ MMAC_TEST_MARKER: 'from mMac' })
  expect(found.path).toBe(muse)
  expect(found.version).toBe('9.9.9')
  expect(found.shellWarning).toBeUndefined()
  expect(found.environment.SHELL).toBe('/bin/zsh')
  expect(found.environment.MMAC_TEST_MARKER).toBe('from mMac')
})

it('leaves MMAC_LOGIN_SHELL out of the environment it prints', async () => {
  // The command discoverCli sends. The stub answers it from the environment it was started with.
  const { stdout } = await promisify(execFile)(
    stub,
    ['-ilc', "printf '\\0MUSE_DESKTOP_ENV\\0'; (/usr/bin/env -0 || env -0)"],
    { env: { PATH: '/usr/bin:/bin', MMAC_LOGIN_SHELL: '/bin/zsh', KEEP: 'yes' } },
  )
  const entries = stdout.split('\0MUSE_DESKTOP_ENV\0')[1].split('\0')
  expect(entries).toContain('KEEP=yes')
  expect(entries).toContain('SHELL=/bin/zsh')
  expect(entries.filter((entry) => entry.startsWith('MMAC_LOGIN_SHELL'))).toEqual([])
})

it('finds the stub next to the server, executable', async () => {
  const path = loginEnvShell()
  expect(path.endsWith('src/headless/login-env.sh')).toBe(true)
  await access(path, constants.X_OK)
})

it('names a missing stub', () => {
  expect(() => loginEnvShell(new URL('file:///nowhere/'))).toThrow(
    "mMac's backend is missing src/headless/login-env.sh.",
  )
})

it('names a stub that is not executable', async () => {
  await writeFile(join(dir, 'login-env.sh'), '#!/bin/sh\n', { mode: 0o644 })
  expect(() => loginEnvShell(pathToFileURL(`${dir}/`))).toThrow(
    "mMac's backend is missing src/headless/login-env.sh.",
  )
})

it('passes any other command to the real shell', async () => {
  const { stdout } = await promisify(execFile)(stub, ['-ilc', 'echo hi'], {
    env: { ...process.env, HOME: dir, ZDOTDIR: dir, MMAC_LOGIN_SHELL: '/bin/sh' },
  })
  expect(stdout.trim()).toBe('hi')
})
