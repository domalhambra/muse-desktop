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
  let asks = AskQueue()
  private var client: BackendClient?
  private var transport: ProcessTransport?
  private var launching = false
  private var quitting = false
  /// Set by a second Quit. mMac then quits whatever the backend answers.
  private var forced = false

  /// Starts a backend. Does nothing while one is starting or running.
  func start() async {
    guard client == nil, !launching else { return }
    launching = true
    defer { launching = false }
    phase = .starting
    workspace = nil
    var launched: ProcessTransport?
    do {
      let repository = try Self.repository()
      let arguments = Self.backendArguments()
      let transport = try await Task.detached {
        try Launcher.launch(repository: repository, arguments: arguments)
      }.value
      launched = transport
      self.transport = transport
      let asks = self.asks
      let client = BackendClient(transport: transport, answerAsk: { ask in await asks.present(ask) })
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
      let workspace = Workspace(client: client, started: started)
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
    do {
      // A forced stop can still answer false: the backend's SIGTERM path cancels its Ask, and
      // "Keep working" is the cancel choice.
      if try await client.shutdown() || forced { return true }
      quitting = false
      return false
    } catch {
      return true
    }
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
    guard !quitting else { return }
    let details = await Self.errorOutput(of: transport)
    guard client === stopped, !quitting else { return }
    client = nil
    transport = nil
    workspace = nil
    phase = .stopped(
      message: "The backend process ended. Restart it to continue. Your conversations are saved in Muse Code.",
      details: details)
  }

  /// The backend's last stderr output. stderr is read on its own queue, so the last lines of a
  /// crash can land just after stdout ends; a short pause lets them in.
  private static func errorOutput(of transport: ProcessTransport?) async -> String {
    guard let transport else { return "" }
    try? await Task.sleep(for: .milliseconds(250))
    return transport.recentErrorOutput
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
