import { _electron as electron, test, expect, type ElectronApplication } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { discoverCli } from '../../src/main/cli'
import { preferencesSchema } from '../../src/shared/protocol'

const original = 'one\ntwo\nthree\n' + 'x\n'.repeat(20) + 'ten\neleven\n'

async function launch(sandbox: string, project: string) {
  const userData = join(sandbox, 'desktop')
  await mkdir(userData, { recursive: true })
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
  const app = await electron.launch({
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
  return { app, page }
}

test('the inspector reverts a hunk, stages a file and reverts a file', async () => {
  const sandbox = await realpath(await mkdtemp(join(tmpdir(), 'muse-desktop-revert-')))
  const project = join(sandbox, 'revert-me')
  await mkdir(project)
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
  let app: ElectronApplication | undefined
  try {
    const launched = await launch(sandbox, project)
    app = launched.app
    const page = launched.page
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

test('a new conversation can run in a Muse-created worktree and merge back', async () => {
  const sandbox = await realpath(await mkdtemp(join(tmpdir(), 'muse-desktop-worktree-')))
  const project = join(sandbox, 'isolated')
  await mkdir(project)
  const git = (cwd: string, ...args: string[]) =>
    execFileSync('git', args, { cwd, stdio: 'pipe' }).toString()
  git(project, 'init', '-q', '-b', 'main')
  git(project, 'config', 'user.email', 'test@example.com')
  git(project, 'config', 'user.name', 'Test')
  await writeFile(join(project, 'readme.md'), 'base\n')
  git(project, 'add', '.')
  git(project, 'commit', '-q', '-m', 'init')
  let app: ElectronApplication | undefined
  try {
    const launched = await launch(sandbox, project)
    app = launched.app
    const page = launched.page
    const toggle = page.getByRole('button', { name: 'Start in a new Git worktree' })
    await toggle.click()
    await expect(page.getByText('Muse will create a separate Git worktree')).toBeVisible()
    await page.getByRole('textbox', { name: 'Message Muse' }).fill('Work over here.')
    await page.getByRole('button', { name: 'Send message' }).click()
    await expect(page.locator('.worktree-chip').first()).toBeVisible()
    await expect(page.getByRole('button', { name: /Start in a new Git worktree/ })).toHaveCount(0)

    const listed = git(project, 'worktree', 'list', '--porcelain')
    const worktree = /worktree (.*\/\.muse\/worktrees\/[^\n]+)/.exec(listed)?.[1]
    expect(worktree).toBeTruthy()
    const trust = JSON.parse(await readFile(join(sandbox, 'config', 'muse', 'trust.json'), 'utf8'))
    expect(trust.projects[project].decision).toBe('trusted')

    await writeFile(join(worktree!, 'feature.md'), 'from the worktree\n')
    git(worktree!, 'add', '.')
    git(worktree!, '-c', 'user.email=t@e.com', '-c', 'user.name=T', 'commit', '-q', '-m', 'feature')
    await page.getByRole('button', { name: 'Toggle project inspector' }).click()
    const inspector = page.getByRole('complementary', { name: 'Project inspector' })
    const name = worktree!.split('/').at(-1)!
    await expect(inspector.getByRole('button', { name: `Remove worktree ${name}` })).toBeDisabled()
    await inspector.getByRole('button', { name: `Merge ${name} into main` }).click()
    await expect
      .poll(() => readFile(join(project, 'feature.md'), 'utf8').catch(() => 'missing'))
      .toBe('from the worktree\n')
  } finally {
    await app?.close()
    await rm(sandbox, { recursive: true, force: true })
  }
})

test('the MCP servers tab edits Muse settings.json without exposing secrets', async () => {
  const sandbox = await realpath(await mkdtemp(join(tmpdir(), 'muse-desktop-mcp-')))
  const project = join(sandbox, 'tools')
  await mkdir(project)
  const settings = join(sandbox, 'config', 'muse', 'settings.json')
  await mkdir(join(sandbox, 'config', 'muse'), { recursive: true })
  await writeFile(settings, JSON.stringify({ schema_version: 1, model: 'keep-me' }))
  const read = async () => JSON.parse(await readFile(settings, 'utf8'))
  let app: ElectronApplication | undefined
  try {
    const launched = await launch(sandbox, project)
    app = launched.app
    const page = launched.page
    await page.getByRole('button', { name: 'Settings', exact: true }).click()
    await page.getByRole('button', { name: 'MCP servers', exact: true }).click()
    await expect(page.getByText('No MCP servers are configured yet.')).toBeVisible()
    await page.getByRole('button', { name: 'Add server' }).click()
    await page.getByLabel('Name', { exact: true }).fill('files')
    await page.getByLabel('Command', { exact: true }).fill('npx')
    await page.getByLabel('Arguments, one per line').fill('-y\n@scope/server')
    await page.getByLabel('Environment, one KEY=value per line').fill('API_TOKEN=very-secret')
    await page.getByRole('button', { name: 'Add server' }).last().click()
    await expect(page.getByText('Environment: API_TOKEN')).toBeVisible()
    await expect(page.getByText('very-secret')).toHaveCount(0)
    await expect(page.getByText('Reconnect Muse Code to apply your changes.')).toBeVisible()
    expect(await read()).toEqual({
      schema_version: 1,
      model: 'keep-me',
      mcpServers: {
        files: { command: 'npx', args: ['-y', '@scope/server'], env: { API_TOKEN: 'very-secret' } },
      },
    })
    await page.getByRole('checkbox', { name: 'Enable files' }).click()
    await expect.poll(async () => (await read()).mcpServers.files.enabled).toBe(false)
    page.once('dialog', (dialog) => void dialog.accept())
    await page.getByRole('button', { name: 'Remove files' }).click()
    await expect.poll(async () => (await read()).mcpServers).toEqual({})
    // The status already reads Connected, so record that a reconnect really started.
    await page.locator('.connection-status').evaluate((element) => {
      const seen: string[] = []
      Object.assign(window, { connectionStatusSeen: seen })
      new MutationObserver(() => seen.push(element.textContent ?? '')).observe(element, {
        subtree: true,
        childList: true,
        characterData: true,
      })
    })
    await page.getByRole('button', { name: 'Reconnect', exact: true }).click()
    await expect
      .poll(() =>
        page.evaluate(() =>
          (window as unknown as { connectionStatusSeen: string[] }).connectionStatusSeen.some(
            (text) => text.includes('Connecting to Muse'),
          ),
        ),
      )
      .toBe(true)
    await expect(page.getByText('Connected to Muse Code', { exact: true })).toBeVisible()
  } finally {
    await app?.close()
    await rm(sandbox, { recursive: true, force: true })
  }
})

test('the folder bridge runs a request as a Muse conversation', async () => {
  const sandbox = await realpath(await mkdtemp(join(tmpdir(), 'muse-desktop-bridge-')))
  const project = join(sandbox, 'bridged')
  const outsider = join(sandbox, 'outsider')
  await mkdir(project)
  await mkdir(outsider)
  const bridge = join(sandbox, 'desktop', 'bridge')
  let app: ElectronApplication | undefined
  try {
    const launched = await launch(sandbox, project)
    app = launched.app
    const page = launched.page
    await page.getByRole('button', { name: 'Settings', exact: true }).click()
    await page.getByRole('button', { name: 'Bridges', exact: true }).click()
    await page.getByRole('checkbox', { name: /Folder bridge/ }).click()
    await expect(page.getByRole('checkbox', { name: /Folder bridge/ })).toBeChecked()
    await expect(page.getByText(/Requests are Markdown files in a folder\. Running/)).toBeVisible()
    await page.keyboard.press('Escape')
    expect(await readFile(join(bridge, 'README.md'), 'utf8')).toContain('## Ask for work')

    await writeFile(
      join(bridge, 'inbox', 'hello.md'),
      `---\nproject: ${project}\neffort: low\n---\nHello through the folder bridge.\n`,
    )
    await writeFile(join(bridge, 'inbox', 'sneaky.md'), `---\nproject: ${outsider}\n---\nHi\n`)
    const outbox = join(bridge, 'outbox', 'hello.md')
    await expect
      .poll(() => readFile(outbox, 'utf8').catch(() => ''), { timeout: 20000 })
      .toContain('status: done')
    expect(await readFile(outbox, 'utf8')).toMatch(/# Reply\n.*Hello through the folder bridge/)
    await expect(page.locator('.conversation-row')).toHaveCount(1)
    await expect
      .poll(() =>
        readFile(join(bridge, 'inbox', 'rejected', 'sneaky.error.txt'), 'utf8').catch(() => ''),
      )
      .toContain('Open project')
  } finally {
    await app?.close()
    await rm(sandbox, { recursive: true, force: true })
  }
})

test('the MCP bridge lets an MCP client ask Muse through Desktop', async () => {
  const { Client } = await import('@modelcontextprotocol/sdk/client/index.js')
  const { StreamableHTTPClientTransport } =
    await import('@modelcontextprotocol/sdk/client/streamableHttp.js')
  const sandbox = await realpath(await mkdtemp(join(tmpdir(), 'muse-desktop-mcpbridge-')))
  const project = join(sandbox, 'served')
  await mkdir(project)
  const port = 40000 + Math.floor(Math.random() * 20000)
  let app: ElectronApplication | undefined
  try {
    const launched = await launch(sandbox, project)
    app = launched.app
    const page = launched.page
    await page.getByRole('button', { name: 'Settings', exact: true }).click()
    await page.getByRole('button', { name: 'Bridges', exact: true }).click()
    await page.getByLabel('Port').fill(String(port))
    await page.getByLabel('Port').press('Enter')
    await page.getByRole('button', { name: 'Make token' }).click()
    const token = await page.getByLabel('New token, shown once').inputValue()
    expect(token).toMatch(/^[A-Za-z0-9_-]{32}$/)
    await page.getByRole('checkbox', { name: /MCP bridge/ }).click()
    await expect(
      page.getByText(/A local MCP server for agents that speak MCP\. Running/),
    ).toBeVisible()
    await expect(page.getByText(`http://127.0.0.1:${port}/mcp`)).toBeVisible()

    const url = new URL(`http://127.0.0.1:${port}/mcp`)
    expect((await fetch(url, { method: 'POST', body: '{}' })).status).toBe(401)
    const client = new Client({ name: 'e2e', version: '0.0.0' })
    await client.connect(
      new StreamableHTTPClientTransport(url, {
        requestInit: { headers: { Authorization: `Bearer ${token}` } },
      }),
    )
    const projects = await client.callTool({ name: 'list_projects', arguments: {} })
    expect(JSON.stringify(projects.content)).toContain(project)
    const asked = await client.callTool({
      name: 'ask_muse',
      arguments: { project, prompt: 'Hello over MCP.', effort: 'low', wait_seconds: 20 },
    })
    const job = JSON.parse((asked.content as { text: string }[])[0].text)
    expect(job.status).toBe('done')
    expect(job.reply).toContain('Hello over MCP.')
    await client.close()

    page.once('dialog', (dialog) => void dialog.accept())
    await page.getByRole('button', { name: 'Make new token' }).click()
    await expect(page.getByLabel('New token, shown once')).not.toHaveValue(token)
    const stale = await fetch(url, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: '{}',
    })
    expect(stale.status).toBe(401)
  } finally {
    await app?.close()
    await rm(sandbox, { recursive: true, force: true })
  }
})
