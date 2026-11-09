import { join } from 'node:path'
import { z } from 'zod'
import { readJsonFile, writeJsonFile } from './muse-config'

// MCP servers live in Muse Code's own settings.json under `mcpServers`, keyed by
// name: `{ command, args, env }` for stdio, `{ url, headers }` for remote
// (streamable HTTP). `enabled: false` turns an entry off. Muse's MSP surface
// offers no write method for these entries, so Desktop edits one entry at a
// time and preserves every other key. Muse reads the file when it starts.

const MCP_KEY = 'mcpServers'
const nameSchema = z
  .string()
  .regex(/^[A-Za-z0-9_-]{1,64}$/, 'Use letters, numbers, - and _ for the server name.')
const stringMap = z.record(z.string().min(1).max(256), z.string().max(4096))

export const mcpServerSchema = z.discriminatedUnion('transport', [
  z.object({
    name: nameSchema,
    transport: z.literal('stdio'),
    command: z.string().trim().min(1).max(1024),
    args: z.array(z.string().max(1024)).max(64).default([]),
    env: stringMap.default({}),
  }),
  z.object({
    name: nameSchema,
    transport: z.literal('http'),
    url: z
      .string()
      .url()
      .max(2048)
      .refine((value) => /^https?:\/\//.test(value), 'Use an http or https URL.'),
    headers: stringMap.default({}),
  }),
])
export type McpServerInput = z.input<typeof mcpServerSchema>
export type McpServer = z.output<typeof mcpServerSchema> & { enabled: boolean }

export const settingsFile = (configDir: string) => join(configDir, 'settings.json')

type Entry = Record<string, unknown>

async function readSettings(file: string) {
  const settings = (await readJsonFile(file)) ?? {}
  const servers = settings[MCP_KEY]
  if (servers !== undefined && (typeof servers !== 'object' || !servers || Array.isArray(servers)))
    throw new Error(`${MCP_KEY} in ${file} is not an object. Fix it, then try again.`)
  return { settings, servers: (servers ?? {}) as Record<string, Entry> }
}

async function writeSettings(
  file: string,
  settings: Record<string, unknown>,
  servers: Record<string, Entry>,
) {
  // Muse refuses to start without schema_version, so a new file needs one.
  await writeJsonFile(file, { schema_version: 1, ...settings, [MCP_KEY]: servers })
}

const stringRecord = (value: unknown): Record<string, string> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? Object.fromEntries(
        Object.entries(value).filter(
          (entry): entry is [string, string] => typeof entry[1] === 'string',
        ),
      )
    : {}

function fromEntry(name: string, entry: Entry): McpServer | null {
  const enabled = entry.enabled !== false && entry.disabled !== true
  if (typeof entry.url === 'string')
    return {
      name,
      transport: 'http',
      url: entry.url,
      headers: stringRecord(entry.headers),
      enabled,
    }
  if (typeof entry.command === 'string')
    return {
      name,
      transport: 'stdio',
      command: entry.command,
      args: Array.isArray(entry.args) ? entry.args.filter((arg) => typeof arg === 'string') : [],
      env: stringRecord(entry.env),
      enabled,
    }
  return null
}

export async function listServers(file: string): Promise<McpServer[]> {
  const { servers } = await readSettings(file)
  return Object.entries(servers)
    .filter(([, entry]) => entry && typeof entry === 'object')
    .map(([name, entry]) => fromEntry(name, entry))
    .filter((server): server is McpServer => server !== null)
    .sort((a, b) => a.name.localeCompare(b.name))
}

export async function addServer(file: string, input: McpServerInput) {
  const server = mcpServerSchema.parse(input)
  const { settings, servers } = await readSettings(file)
  if (servers[server.name]) throw new Error(`A server named "${server.name}" already exists.`)
  servers[server.name] =
    server.transport === 'stdio'
      ? { command: server.command, args: server.args, env: server.env }
      : { url: server.url, headers: server.headers }
  await writeSettings(file, settings, servers)
}

export async function setServerEnabled(file: string, name: string, enabled: boolean) {
  const { settings, servers } = await readSettings(file)
  const entry = servers[nameSchema.parse(name)]
  if (!entry) throw new Error(`No server named "${name}".`)
  delete entry.disabled
  if (enabled) delete entry.enabled
  else entry.enabled = false
  await writeSettings(file, settings, servers)
}

export async function removeServer(file: string, name: string) {
  const { settings, servers } = await readSettings(file)
  if (!servers[nameSchema.parse(name)]) throw new Error(`No server named "${name}".`)
  delete servers[name]
  await writeSettings(file, settings, servers)
}
