import { useCallback, useEffect, useState } from 'react'
import { Copy, FolderOpen, KeyRound } from 'lucide-react'
import type { BridgeStatus, Preferences } from '../../../shared/protocol'

export function BridgeSettings({
  preferences,
  onSave,
  onError,
}: {
  preferences: Preferences
  onSave: (patch: Partial<Preferences>) => void
  onError: (message: string) => void
}) {
  const [status, setStatus] = useState<BridgeStatus>()
  const [token, setToken] = useState('')
  const [port, setPort] = useState(String(preferences.bridgeMcpPort))
  const fail = useCallback(
    (error: unknown) => onError(error instanceof Error ? error.message : String(error)),
    [onError],
  )
  const refresh = useCallback(() => {
    void window.muse.bridgeStatus().then(setStatus).catch(fail)
  }, [fail])
  useEffect(refresh, [
    refresh,
    preferences.bridgeFilesEnabled,
    preferences.bridgeMcpEnabled,
    preferences.bridgeMcpPort,
  ])
  const savePort = () => {
    const value = Number(port)
    if (Number.isInteger(value) && value >= 1024 && value <= 65535) onSave({ bridgeMcpPort: value })
    else {
      setPort(String(preferences.bridgeMcpPort))
      onError('Use a port between 1024 and 65535.')
    }
  }
  const state = (part?: { enabled: boolean; running: boolean; error?: string }) =>
    part?.error ? `Not running: ${part.error}` : part?.running ? 'Running' : 'Off'
  return (
    <>
      <div className="settings-section-heading">
        <h3>Bridges</h3>
        <p>
          Let another agent, such as the Muse app, ask Muse Code to work in projects you have opened
          and trusted here. Every job appears in this window with its approvals.
        </p>
      </div>
      <label className="setting-row">
        <div>
          <span className="setting-label">Folder bridge</span>
          <small>Requests are Markdown files in a folder. {state(status?.files)}</small>
        </div>
        <input
          type="checkbox"
          className="switch"
          checked={preferences.bridgeFilesEnabled}
          onChange={(event) => onSave({ bridgeFilesEnabled: event.target.checked })}
        />
      </label>
      {status && <p className="path-readout">{status.folder}</p>}
      <div className="bridge-actions">
        <button
          className="button secondary"
          onClick={() => void window.muse.bridgeRevealFolder().catch(fail)}
        >
          <FolderOpen size={15} />
          Open bridge folder
        </button>
      </div>
      <p className="field-hint">
        Give the README.md in that folder to the other agent as its instructions.
      </p>
      <label className="setting-row">
        <div>
          <span className="setting-label">MCP bridge</span>
          <small>
            A local MCP server for agents that speak MCP.{' '}
            {status?.mcp.hasToken ? state(status.mcp) : 'Make a token first.'}
          </small>
        </div>
        <input
          type="checkbox"
          className="switch"
          disabled={!status?.mcp.hasToken && !preferences.bridgeMcpEnabled}
          checked={preferences.bridgeMcpEnabled}
          onChange={(event) => onSave({ bridgeMcpEnabled: event.target.checked })}
        />
      </label>
      {status && <p className="path-readout">{status.mcp.url}</p>}
      <label className="field-label" htmlFor="bridge-port">
        Port
      </label>
      <input
        id="bridge-port"
        className="text-input bridge-port"
        inputMode="numeric"
        value={port}
        onChange={(event) => setPort(event.target.value)}
        onBlur={savePort}
        onKeyDown={(event) => {
          if (event.key === 'Enter') savePort()
        }}
      />
      {token && (
        <>
          <label className="field-label" htmlFor="bridge-token">
            New token, shown once
          </label>
          <input id="bridge-token" className="text-input" readOnly value={token} />
          <p className="field-hint">
            Send it as <code>Authorization: Bearer &lt;token&gt;</code>. Making a new token
            disconnects agents that use the old one.
          </p>
        </>
      )}
      <div className="bridge-actions">
        {status?.mcp.hasToken && (
          <button
            className="button secondary"
            onClick={() => void window.muse.bridgeCopyToken().catch(fail)}
          >
            <Copy size={15} />
            Copy token
          </button>
        )}
        <button
          className="button secondary"
          onClick={() => {
            if (
              status?.mcp.hasToken &&
              !window.confirm('Make a new token? Agents using the current token lose access.')
            )
              return
            void window.muse
              .bridgeRegenerateToken()
              .then((value) => {
                setToken(value)
                refresh()
              })
              .catch(fail)
          }}
        >
          <KeyRound size={15} />
          {status?.mcp.hasToken ? 'Make new token' : 'Make token'}
        </button>
      </div>
    </>
  )
}
