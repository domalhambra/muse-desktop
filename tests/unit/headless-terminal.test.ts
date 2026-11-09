import { execFileSync } from 'node:child_process'
import { chmod, mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { folderCommand, openInTerminal, terminalCommand } from '../../src/headless/terminal'

let dir = ''
beforeEach(async () => {
  dir = await realpath(await mkdtemp(join(tmpdir(), 'mmac-terminal-')))
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('terminalCommand', () => {
  it('escapes a single quote in the folder, the CLI and an argument', () => {
    expect(terminalCommand("/tmp/O'Brien dir", '/opt/my muse', ["x'; echo pwned"])).toBe(
      `cd '/tmp/O'\\''Brien dir' && '/opt/my muse' 'x'\\''; echo pwned'`,
    )
  })

  it('gives a line the shell parses and runs with every argument literal', async () => {
    const folder = join(dir, "O'Brien dir")
    await mkdir(folder)
    const cli = join(folder, "my 'muse'")
    await writeFile(cli, '#!/bin/sh\nprintf "%s\\n" "$@"\npwd\n')
    await chmod(cli, 0o755)
    const line = terminalCommand(folder, cli, ['mcp', "x'; echo pwned", '$HOME `id`'])

    expect(() => execFileSync('/bin/sh', ['-n', '-c', line])).not.toThrow()
    const output = execFileSync('/bin/sh', ['-c', line], { encoding: 'utf8' })
    expect(output.split('\n')).toEqual(['mcp', "x'; echo pwned", '$HOME `id`', folder, ''])
  })
})

describe('folderCommand', () => {
  it('escapes a single quote in the folder', () => {
    expect(folderCommand("/tmp/O'Brien dir")).toBe(`cd '/tmp/O'\\''Brien dir'`)
  })

  it('gives a line the shell parses and runs into the folder, every character literal', async () => {
    const folder = join(dir, "O'Brien $HOME `id`")
    await mkdir(folder)
    const line = folderCommand(folder)
    expect(() => execFileSync('/bin/sh', ['-n', '-c', line])).not.toThrow()
    expect(execFileSync('/bin/sh', ['-c', `${line} && pwd`], { encoding: 'utf8' })).toBe(
      `${folder}\n`,
    )
  })
})

describe('openInTerminal', () => {
  it('runs osascript with the script as -e lines and the command as the last argument', async () => {
    const run = vi.fn(async () => undefined)
    await openInTerminal("cd '/tmp' && 'muse'", run)
    expect(run).toHaveBeenCalledOnce()
    expect(run).toHaveBeenCalledWith(
      '/usr/bin/osascript',
      [
        '-e',
        'on run argv',
        '-e',
        'tell application "Terminal"',
        '-e',
        'activate',
        '-e',
        'do script (item 1 of argv)',
        '-e',
        'end tell',
        '-e',
        'end run',
        "cd '/tmp' && 'muse'",
      ],
      { timeout: 10000 },
    )
  })
})
