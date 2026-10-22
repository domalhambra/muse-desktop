import AppKit
import MuseBackend
import MuseKit
import Observation

/// Starts and stops the backend, and owns what lives as long as it does: the Workspace, the Ask
/// queue, and the error output shown when the backend fails.
@MainActor @Observable
final class AppController {
  enum Phase: Equatable {
    case starting
    case running
    /// The backend could not start. `details` is its last stderr output.
    case setupFailed(message: String, details: String)
    /// The backend ended while mMac was running.
    case stopped(message: String, details: String)
  }

  private(set) var phase: Phase = .starting
  private(set) var workspace: Workspace?
  /// The last Workspace's unsent drafts, for the next backend's Workspace.
  private var drafts: [String: String] = [:]
  let asks = AskQueue()
  private var client: BackendClient?
  private var transport: ProcessTransport?
  private var launching = false
  private var quitting = false
  /// Set by a second Quit. mMac then quits whatever the backend answers.
  private var forced = false
  /// A backend that stopped while a Quit waited. If the person then keeps working, mMac shows
  /// the stopped screen rather than a window on a dead backend.
  private var stoppedWhileQuitting: BackendClient?
  /// Opens the main window. RootView sets it, because only SwiftUI can open a scene's window.
  @ObservationIgnored var showWindow: (@MainActor () -> Void)?

  /// Starts a backend. Does nothing while one is starting or running.
  func start() async {
    guard client == nil, !launching else { return }
    launching = true
    defer { launching = false }
    phase = .starting
    dropWorkspace()
    stoppedWhileQuitting = nil
    var launched: ProcessTransport?
    do {
      let repository = try Self.repository()
      let arguments = Self.backendArguments()
      // A nonisolated async function, so it runs off the main actor.
      let transport = try await Launcher.launch(repository: repository, arguments: arguments)
      launched = transport
      self.transport = transport
      // Asks are tied to this backend's generation: one that arrives after the queue was
      // cancelled for it gets -1 at once, and shows no sheet.
      let generation = asks.generation
      let client = BackendClient(
        transport: transport,
        answerAsk: { [weak self] ask in await self?.present(ask, generation: generation) ?? -1 })
      self.client = client
      await client.run()
      Task {
        for await event in client.events where self.client === client {
          self.workspace?.apply(event)
        }
        await self.backendStopped(client)
      }
      _ = try await client.hello()
      let started = try await client.start(dataFolder: Self.dataFolder())
      let workspace = Workspace(client: client, started: started, drafts: drafts)
      self.workspace = workspace
      phase = .running
      await workspace.begin()
    } catch {
      // A backend that failed to start is dropped, and its input closed so it quits.
      client = nil
      transport = nil
      asks.cancelAll()
      let details = await Self.errorOutput(of: launched)
      launched?.close()
      phase = .setupFailed(message: error.localizedDescription, details: details)
    }
  }

  /// Returns true when mMac may quit. The backend may Ask first if a turn is running.
  func quit() async -> Bool {
    guard let client, phase == .running else { return true }
    quitting = true
    let quit: Bool
    do {
      quit = try await client.shutdown()
    } catch {
      quit = true
    }
    if forced {
      // A forced stop can still answer false: the backend's SIGTERM path cancels its Ask, and
      // "Keep working" is the cancel choice. Wait for the process to end, so mMac does not exit
      // before forceStop's SIGKILL.
      await client.waitForExit(timeout: .seconds(3))
      return true
    }
    if quit { return true }
    quitting = false
    if let stopped = stoppedWhileQuitting {
      stoppedWhileQuitting = nil
      await backendStopped(stopped)
    }
    return false
  }

  /// A second Quit while the first waits: stop the backend now, so the first Quit's wait ends.
  func forceQuit() {
    forced = true
    asks.cancelAll()
    client?.forceStop()
  }

  private func backendStopped(_ stopped: BackendClient) async {
    // A client dropped after a failed start ends too. It must not cancel a newer backend's Asks.
    guard client === stopped else { return }
    asks.cancelAll()
    guard !quitting else {
      stoppedWhileQuitting = stopped
      return
    }
    let details = await Self.errorOutput(of: transport)
    guard client === stopped, !quitting else { return }
    client = nil
    transport = nil
    dropWorkspace()
    phase = .stopped(
      message: "The backend process ended. Restart it to continue. Your conversations are saved in Muse Code.",
      details: details)
  }

  /// Drops the Workspace and keeps its drafts. A send the stop cut off has put its text back by
  /// now: `BackendError.stopped` reaches it before the event stream ends this backend.
  private func dropWorkspace() {
    if let workspace { drafts = workspace.drafts }
    workspace = nil
  }

  /// The backend's last stderr output, once stderr has ended.
  private static func errorOutput(of transport: ProcessTransport?) async -> String {
    await transport?.errorOutput() ?? ""
  }

  /// Shows an Ask from the backend of `generation`, opening the window first if it is closed,
  /// so a Quit's "Quit while Muse is working?" always has a window to show in.
  private func present(_ ask: Ask, generation: Int) async -> Int {
    guard generation == asks.generation else { return -1 }
    revealWindow()
    return await asks.present(ask, generation: generation)
  }

  /// Opens the main window when no mMac window is visible. Returns false if it cannot.
  @discardableResult
  func revealWindow() -> Bool {
    if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { return true }
    guard let showWindow else { return false }
    showWindow()
    NSApp.activate()
    return true
  }

  // MARK: Panels

  /// "Open project…": adds the chosen folder and selects it.
  func openProject() async {
    guard let workspace, let folder = Self.chooseProjectFolder() else { return }
    await workspace.addProject(folder)
  }

  /// Sends the draft. With no project yet, asks for one first, as Electron does.
  /// `send(addingProject:)` moves the draft to the new project's key, so no copy is left behind.
  func send() async {
    guard let workspace else { return }
    guard await workspace.send() == .needsProject, let folder = Self.chooseProjectFolder() else { return }
    _ = await workspace.send(addingProject: folder)
  }

  /// "Choose Muse Code…": saves the executable's path and reconnects.
  func chooseCLI() async {
    guard let workspace else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose the Muse Code executable"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.showsHiddenFiles = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    await workspace.setCLIPath(url.path)
  }

  /// "Choose checkout…": runs the backend from another Muse Desktop checkout.
  func chooseRepository() async {
    let panel = NSOpenPanel()
    panel.message = "Choose the folder that holds your Muse Desktop checkout."
    panel.prompt = "Use this checkout"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // A folder that is not a checkout is refused, and the saved choice stays as it was.
    do {
      _ = try Self.checkout(at: url.path)
    } catch {
      phase = .setupFailed(message: error.localizedDescription, details: "")
      return
    }
    UserDefaults.standard.set(url.path, forKey: Self.repositoryKey)
    await start()
  }

  // MARK: Where things are

  static let repositoryKey = "MMacRepository"

  private struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  /// The checkout the backend runs from: the one chosen in the app, else the one this build came from.
  static func repository() throws -> URL {
    let chosen = UserDefaults.standard.string(forKey: repositoryKey)
    let built = Bundle.main.object(forInfoDictionaryKey: repositoryKey) as? String
    guard let path = chosen ?? built else {
      throw SetupError("This mMac build does not name a Muse Desktop checkout. Choose one.")
    }
    return try checkout(at: path)
  }

  /// `path` as a checkout URL, if it holds the backend.
  static func checkout(at path: String) throws -> URL {
    let repository = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: repository.appending(path: "src/headless/server.ts").path) else {
      throw SetupError("mMac could not find src/headless/server.ts in \(repository.path). Choose the Muse Desktop checkout.")
    }
    return repository
  }

  /// `~/Library/Application Support/mMac`. `MMAC_DATA_FOLDER` overrides it for test runs.
  static func dataFolder() throws -> URL {
    if let folder = ProcessInfo.processInfo.environment["MMAC_DATA_FOLDER"], !folder.isEmpty {
      return URL(fileURLWithPath: folder)
    }
    return try FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appending(path: "mMac")
  }

  /// The Node arguments for the backend. Debug builds can run the UI tests' fake backend instead.
  static func backendArguments() -> [String] {
    #if DEBUG
      if let script = ProcessInfo.processInfo.environment["MMAC_BACKEND_SCRIPT"], !script.isEmpty {
        return [script]
      }
    #endif
    return ProcessTransport.serverArguments
  }

  /// The folder for "Open project". The open panel runs in another process that UI tests cannot
  /// drive, so Debug builds take `MMAC_TEST_PROJECT` instead when it is set.
  static func chooseProjectFolder() -> URL? {
    #if DEBUG
      if let folder = ProcessInfo.processInfo.environment["MMAC_TEST_PROJECT"], !folder.isEmpty {
        return URL(fileURLWithPath: folder)
      }
    #endif
    let panel = NSOpenPanel()
    panel.message = "Open a project"
    panel.prompt = "Open project"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
  }
}
