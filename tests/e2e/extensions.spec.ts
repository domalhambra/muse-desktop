import { _electron as electron, test, expect, type ElectronApplication } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { discoverCli } from '../../src/main/cli'
import { preferencesSchema } from '../../src/shared/protocol'

const original = 'one\ntwo\nthree\n' + 'x\n'.repeat(20) + 'ten\neleven\n'

test('the inspector reverts a hunk, stages a file and reverts a file', async () => {
  const sandbox = await realpath(await mkdtemp(join(tmpdir(), 'muse-desktop-revert-')))
  const project = join(sandbox, 'revert-me')
  const userData = join(sandbox, 'desktop')
  await mkdir(project)
  await mkdir(userData)
  const git = (...args: string[]) =>
    execFileSync('git', args, { cwd: project, stdio: 'pipe' }).toString()
  git('init', '-q')
  git('config', 'user.email', 'test@example.com')
  git('config', 'user.name', 'Test')
  await writeFile(join(project, 'a.txt'), original)
  await writeFile(join(project, 'b.txt'), 'bee\n')
  git('add', '.')
  git('commit', '-q', '-m', 'init')
  await writeFile(
    join(project, 'a.txt'),
    original.replace('two', 'TWO').replace('eleven', 'ELEVEN'),
  )
  await writeFile(join(project, 'b.txt'), 'buzz\n')
  await writeFile(
    join(userData, 'preferences.json'),
    JSON.stringify(
      preferencesSchema.parse({
        trustedProjects: [project],
        recentProjects: [project],
        cliPath: (await discoverCli(process.env.MUSE_BIN || '')).path,
      }),
    ),
  )
  let app: ElectronApplication | undefined
  try {
    app = await electron.launch({
      args: [resolve('out/main/index.js')],
      env: {
        ...process.env,
        HOME: sandbox,
        XDG_CONFIG_HOME: join(sandbox, 'config'),
        XDG_DATA_HOME: join(sandbox, 'data'),
        XDG_STATE_HOME: join(sandbox, 'state'),
        MUSE_HOME: join(sandbox, 'muse'),
        MUSE_DESKTOP_USER_DATA: userData,
        MUSE_DESKTOP_TEST_PROVIDER: 'echo',
      },
    })
    const page = await app.firstWindow()
    await expect(page.getByText('Connected to Muse Code', { exact: true })).toBeVisible()
    await page.getByRole('button', { name: 'Toggle project inspector' }).click()
    const inspector = page.getByRole('complementary', { name: 'Project inspector' })

    await inspector.getByRole('button', { name: /a\.txt/ }).click()
    await expect(inspector.getByRole('button', { name: 'Revert hunk 2' })).toBeVisible()
    await inspector.getByRole('button', { name: 'Revert hunk 1' }).click()
    await expect(inspector.getByRole('button', { name: 'Revert hunk 2' })).toHaveCount(0)
    const afterHunk = await readFile(join(project, 'a.txt'), 'utf8')
    expect(afterHunk).toContain('\ntwo\n')
    expect(afterHunk).toContain('ELEVEN')

    await inspector.getByRole('button', { name: 'Stage', exact: true }).click()
    await expect.poll(() => git('diff', '--cached', '--name-only')).toContain('a.txt')

    await inspector.getByRole('button', { name: /^a\.txt$/ }).click()
    await inspector.getByRole('button', { name: /b\.txt/ }).click()
    page.once('dialog', (dialog) => void dialog.accept())
    await inspector.getByRole('button', { name: 'Revert file', exact: true }).click()
    await expect.poll(() => readFile(join(project, 'b.txt'), 'utf8')).toBe('bee\n')
    await expect(inspector.getByRole('button', { name: /b\.txt/ })).toHaveCount(0)
  } finally {
    await app?.close()
    await rm(sandbox, { recursive: true, force: true })
  }
})
