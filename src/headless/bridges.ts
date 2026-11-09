import type { AgentApi } from '../main/agent-api'
import { FileBridge } from '../main/bridge-files'
import { McpBridge } from '../main/bridge-mcp'
import { messageOf } from '../main/muse-host'
import type { BridgeStatus, Preferences } from '../shared/protocol'

// mMac's bridges: the folder bridge and the localhost MCP bridge, started and stopped as the
// preferences say. This repeats syncBridges and bridgeStatus in src/main/index.ts, with mMac's own
// folder, and a token mMac keeps in the login Keychain and sends in `start`. The token lives in
// memory here and nowhere else.

// McpBridge.start resolves with the bound port; Bridges does not use it.
type Startable = { start(): Promise<unknown>; stop(): Promise<void> }

export type BridgeFactories = {
  files: (root: string, api: AgentApi) => Startable
  mcp: (
    api: AgentApi,
    options: { port: number; token: string; projects: () => string[] },
  ) => Startable
}

export const realBridges: BridgeFactories = {
  files: (root, api) => new FileBridge(root, api),
  mcp: (api, options) => new McpBridge(api, options),
}

export type BridgesOptions = {
  root: string
  token: string
  api: AgentApi
  preferences: () => Preferences
  factories?: BridgeFactories
}

export class Bridges {
  private files?: Startable
  private mcp?: { bridge: Startable; port: number; token: string }
  private errors: { files?: string; mcp?: string } = {}
  private chain: Promise<void> = Promise.resolve()
  private stopped = false
  private token: string
  private readonly factories: BridgeFactories

  constructor(private readonly options: BridgesOptions) {
    this.token = options.token
    this.factories = options.factories ?? realBridges
  }

  get hasToken() {
    return Boolean(this.token)
  }

  /** Takes a new token. The next sync restarts a running MCP bridge with it. */
  setToken(token: string) {
    this.token = token
  }

  /** Brings both bridges in line with the preferences. Calls run one after another. */
  sync() {
    // Every start and stop inside apply() already catches, as in Electron. This catch keeps a bug
    // from breaking the chain, so later syncs and status() still run.
    this.chain = this.chain
      .then(() => this.apply())
      .catch((error: unknown) => {
        console.error(`The mMac bridges could not sync: ${messageOf(error)}`)
      })
    return this.chain
  }

  /** Stops both bridges for good: the quit path. */
  stop() {
    this.stopped = true
    return this.sync()
  }

  private async apply() {
    const preferences = this.options.preferences()
    const { api, root } = this.options
    const wantFiles = preferences.bridgeFilesEnabled && !this.stopped
    if (wantFiles && !this.files) {
      const bridge = this.factories.files(root, api)
      try {
        await bridge.start()
        this.files = bridge
        delete this.errors.files
      } catch (error) {
        await bridge.stop().catch(() => {})
        this.errors.files = messageOf(error)
      }
    } else if (!wantFiles && this.files) {
      await this.files.stop().catch(() => {})
      this.files = undefined
    }
    if (!wantFiles) delete this.errors.files

    const wantMcp = preferences.bridgeMcpEnabled && !this.stopped
    const port = preferences.bridgeMcpPort
    const token = this.token
    if (this.mcp && (!wantMcp || this.mcp.port !== port || this.mcp.token !== token)) {
      await this.mcp.bridge.stop().catch(() => {})
      this.mcp = undefined
    }
    if (wantMcp && !this.mcp) {
      const bridge = this.factories.mcp(api, {
        port,
        token,
        projects: () => {
          const current = this.options.preferences()
          return current.recentProjects.filter((project) =>
            current.trustedProjects.includes(project),
          )
        },
      })
      try {
        await bridge.start()
        this.mcp = { bridge, port, token }
        delete this.errors.mcp
      } catch (error) {
        await bridge.stop().catch(() => {})
        this.errors.mcp =
          error instanceof Error && 'code' in error && error.code === 'EADDRINUSE'
            ? `Port ${port} is in use. Choose another port.`
            : messageOf(error)
      }
    } else if (!wantMcp) delete this.errors.mcp
  }

  async status(): Promise<BridgeStatus> {
    await this.chain
    const preferences = this.options.preferences()
    return {
      folder: this.options.root,
      files: {
        enabled: preferences.bridgeFilesEnabled,
        running: Boolean(this.files),
        ...(this.errors.files ? { error: this.errors.files } : {}),
      },
      mcp: {
        enabled: preferences.bridgeMcpEnabled,
        running: Boolean(this.mcp),
        url: `http://127.0.0.1:${preferences.bridgeMcpPort}/mcp`,
        hasToken: this.hasToken,
        ...(this.errors.mcp ? { error: this.errors.mcp } : {}),
      },
      activeJobs: this.options.api.activeCount,
    }
  }
}
