import { useCallback, useEffect, useState } from 'react'
import { FolderSearch, KeyRound, Plus, Trash2 } from 'lucide-react'
import type { McpServerInput, McpServerView } from '../../../shared/protocol'

// One `KEY=value` (env) or `Name: value` (headers) pair per line.
export function parsePairs(text: string, separator: '=' | ':') {
  const pairs: Record<string, string> = {}
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    const index = trimmed.indexOf(separator)
    if (index <= 0) throw new Error(`Write each line as name${separator}value: ${trimmed}`)
    pairs[trimmed.slice(0, index).trim()] = trimmed.slice(index + 1).trim()
  }
  return pairs
}

export function McpSettings({
  onError,
  onReconnect,
}: {
  onError: (message: string) => void
  onReconnect: () => void
}) {
  const [servers, setServers] = useState<McpServerView[]>([])
  const [file, setFile] = useState('')
  const [changed, setChanged] = useState(false)
  const [adding, setAdding] = useState(false)
  const [transport, setTransport] = useState<'stdio' | 'http'>('stdio')
  const [name, setName] = useState('')
  const [command, setCommand] = useState('')
  const [args, setArgs] = useState('')
  const [env, setEnv] = useState('')
  const [url, setUrl] = useState('')
  const [headers, setHeaders] = useState('')
  const load = useCallback(async () => {
    try {
      const result = await window.muse.mcpList()
      setServers(result.servers)
      setFile(result.file)
    } catch (error) {
      onError(error instanceof Error ? error.message : String(error))
    }
  }, [onError])
  useEffect(() => {
    void load()
  }, [load])
  const run = async (action: () => Promise<void>) => {
    try {
      await action()
      setChanged(true)
      await load()
    } catch (error) {
      onError(error instanceof Error ? error.message : String(error))
    }
  }
  const add = () =>
    run(async () => {
      const server: McpServerInput =
        transport === 'stdio'
          ? {
              name: name.trim(),
              transport,
              command: command.trim(),
              args: args
                .split('\n')
                .map((arg) => arg.trim())
                .filter(Boolean),
              env: parsePairs(env, '='),
            }
          : { name: name.trim(), transport, url: url.trim(), headers: parsePairs(headers, ':') }
      await window.muse.mcpAdd(server)
      setAdding(false)
      setName('')
      setCommand('')
      setArgs('')
      setEnv('')
      setUrl('')
      setHeaders('')
    })
  return (
    <>
      <div className="settings-section-heading">
        <h3>MCP servers</h3>
        <p>
          Tools Muse Code can use. These live in Muse&rsquo;s own settings file, so the CLI and
          Desktop share them.
        </p>
      </div>
      {changed && (
        <div className="inline-notice mcp-notice">
          <span>Reconnect Muse Code to apply your changes.</span>
          <button className="button secondary" onClick={onReconnect}>
            Reconnect
          </button>
        </div>
      )}
      {servers.length === 0 && !adding && (
        <p className="field-hint">No MCP servers are configured yet.</p>
      )}
      {servers.map((server) => {
        const secrets = server.transport === 'stdio' ? server.envNames : server.headerNames
        return (
          <div className="setting-row mcp-server" key={server.name}>
            <div>
              <span className="setting-label">
                {server.name}
                <span className="mcp-transport">
                  {server.transport === 'stdio' ? 'Local' : 'Remote'}
                </span>
              </span>
              <small className="mcp-detail">
                {server.transport === 'stdio'
                  ? [server.command, ...(server.args ?? [])].join(' ')
                  : server.url}
              </small>
              {Boolean(secrets?.length) && (
                <small>
                  {server.transport === 'stdio' ? 'Environment' : 'Headers'}: {secrets!.join(', ')}
                </small>
              )}
            </div>
            <div className="mcp-actions">
              {server.transport === 'http' && (
                <button
                  className="icon-button"
                  title="Sign in with OAuth (runs muse mcp login in Terminal)"
                  aria-label={`Sign in to ${server.name}`}
                  onClick={() =>
                    void window.muse
                      .mcpLogin(server.name)
                      .catch((error: Error) => onError(error.message))
                  }
                >
                  <KeyRound size={15} />
                </button>
              )}
              <button
                className="icon-button"
                title="Remove"
                aria-label={`Remove ${server.name}`}
                onClick={() => {
                  if (!window.confirm(`Remove the MCP server ${server.name}?`)) return
                  void run(() => window.muse.mcpRemove(server.name))
                }}
              >
                <Trash2 size={15} />
              </button>
              <input
                type="checkbox"
                className="switch"
                aria-label={`Enable ${server.name}`}
                checked={server.enabled}
                onChange={(event) =>
                  void run(() => window.muse.mcpSetEnabled(server.name, event.target.checked))
                }
              />
            </div>
          </div>
        )
      })}
      {adding ? (
        <div className="mcp-form">
          <div className="segmented" role="group" aria-label="Server type">
            {(['stdio', 'http'] as const).map((value) => (
              <button
                key={value}
                aria-pressed={transport === value}
                className={transport === value ? 'selected' : ''}
                onClick={() => setTransport(value)}
              >
                {value === 'stdio' ? 'Local command' : 'Remote URL'}
              </button>
            ))}
          </div>
          <label className="field-label" htmlFor="mcp-name">
            Name
          </label>
          <input
            id="mcp-name"
            className="text-input"
            placeholder="filesystem"
            value={name}
            onChange={(event) => setName(event.target.value)}
          />
          {transport === 'stdio' ? (
            <>
              <label className="field-label" htmlFor="mcp-command">
                Command
              </label>
              <input
                id="mcp-command"
                className="text-input"
                placeholder="npx"
                value={command}
                onChange={(event) => setCommand(event.target.value)}
              />
              <label className="field-label" htmlFor="mcp-args">
                Arguments, one per line
              </label>
              <textarea
                id="mcp-args"
                className="text-input"
                rows={3}
                value={args}
                onChange={(event) => setArgs(event.target.value)}
              />
              <label className="field-label" htmlFor="mcp-env">
                Environment, one KEY=value per line
              </label>
              <textarea
                id="mcp-env"
                className="text-input"
                rows={2}
                value={env}
                onChange={(event) => setEnv(event.target.value)}
              />
            </>
          ) : (
            <>
              <label className="field-label" htmlFor="mcp-url">
                URL
              </label>
              <input
                id="mcp-url"
                className="text-input"
                placeholder="https://example.com/mcp"
                value={url}
                onChange={(event) => setUrl(event.target.value)}
              />
              <label className="field-label" htmlFor="mcp-headers">
                Headers, one Name: value per line
              </label>
              <textarea
                id="mcp-headers"
                className="text-input"
                rows={2}
                value={headers}
                onChange={(event) => setHeaders(event.target.value)}
              />
              <p className="field-hint">
                Leave headers empty for servers that use OAuth, then use the key button to sign in.
              </p>
            </>
          )}
          <div className="mcp-form-actions">
            <button className="button secondary" onClick={() => setAdding(false)}>
              Cancel
            </button>
            <button className="button primary" onClick={() => void add()}>
              Add server
            </button>
          </div>
        </div>
      ) : (
        <div className="mcp-form-actions">
          {file && (
            <button
              className="button secondary"
              onClick={() =>
                void window.muse.mcpRevealSettings().catch((error: Error) => onError(error.message))
              }
            >
              <FolderSearch size={15} />
              Show settings file
            </button>
          )}
          <button className="button primary" onClick={() => setAdding(true)}>
            <Plus size={15} />
            Add server
          </button>
        </div>
      )}
    </>
  )
}
