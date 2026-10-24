import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

// Terminal, as src/main/index.ts's openProjectTerminal opens it on macOS. mMac runs only on macOS.

export type Run = (file: string, args: string[], options: { timeout: number }) => Promise<unknown>

const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`

/** The line Terminal runs to open a shell in `folder`, as Electron's Terminal button does. */
export function folderCommand(folder: string) {
  return `cd ${quote(folder)}`
}

/** The line Terminal runs: change to `folder`, then run the CLI with `cliArgs`. */
export function terminalCommand(folder: string, cli: string, cliArgs: string[]) {
  return `${folderCommand(folder)} && ${[cli, ...cliArgs].map(quote).join(' ')}`
}

/** Opens Terminal and runs `command`. argv carries it as data; nothing is put into AppleScript. */
export async function openInTerminal(command: string, run: Run = promisify(execFile)) {
  await run(
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
      command,
    ],
    { timeout: 10000 },
  )
}
