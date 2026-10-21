import AppKit
import MuseBackend
import Observation

@MainActor @Observable
final class AppModel {
  enum Phase: Equatable {
    case starting
    case running
    case stopped(String)
  }

  var phase: Phase = .starting
  var status: ConnectionStatus?
  var sessions: [Session] = []
  var selected: SessionView?
  var draft = ""
  var errorMessage: String?
  private var client: BackendClient?
  private var launching = false
  private var quitting = false

  /// Starts a backend. Does nothing while one is starting or running, so a second window or a
  /// second Restart click cannot start another.
  func start() async {
    guard client == nil, !launching else { return }
    launching = true
    defer { launching = false }
    phase = .starting
    errorMessage = nil
    status = nil
    sessions = []
    selected = nil
    var launched: ProcessTransport?
    do {
      let repository = try Self.repository()
      let transport = try await Task.detached { try Launcher.launch(repository: repository) }.value
      launched = transport
      let client = BackendClient(transport: transport, answerAsk: { ask in await AppModel.show(ask) })
      self.client = client
      await client.run()
      Task {
        for await event in client.events { self.handle(event, from: client) }
        self.backendStopped(client)
      }
      _ = try await client.hello()
      status = try await client.start(dataFolder: Self.dataFolder()).status
      phase = .running
      await refreshSessions()
    } catch {
      // A backend that failed to start is dropped, and its input closed so it quits.
      client = nil
      launched?.close()
      phase = .stopped(error.localizedDescription)
    }
  }

  func refreshSessions() async {
    guard let client else { return }
    await run { self.sessions = try await client.sessions().sessions }
  }

  func newConversation() async {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open project"
    guard panel.runModal() == .OK, let folder = panel.url, let client else { return }
    await run {
      let project = try await client.addProject(folder)
      self.selected = try await client.create(project: project)
    }
  }

  func open(_ sessionId: String) async {
    guard let client, sessionId != selected?.session.sessionId else { return }
    await run { self.selected = try await client.open(sessionId) }
  }

  func send() async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let client, let sessionId = selected?.session.sessionId, !text.isEmpty else { return }
    let unsent = draft
    draft = ""
    do {
      try await client.send(sessionId: sessionId, text: text)
    } catch {
      // A failed send, such as a cancelled trust Ask, keeps the text unless the person typed again.
      if draft.isEmpty { draft = unsent }
      errorMessage = error.localizedDescription
    }
  }

  /// Returns true when mMac may quit.
  func quit() async -> Bool {
    guard let client, phase == .running else { return true }
    quitting = true
    do {
      let quit = try await client.shutdown()
      if !quit { quitting = false }
      return quit
    } catch {
      return true
    }
  }

  /// Applies an event. Events from a client that is no longer current are dropped.
  private func handle(_ event: AppEvent, from source: BackendClient) {
    guard client === source else { return }
    switch event {
    case .connection(let status): self.status = status
    case .session(let view):
      if view.session.sessionId == selected?.session.sessionId { selected = view }
    case .sessionsChanged: Task { await refreshSessions() }
    case .error(let message): errorMessage = message
    case .other, .preferences: break
    }
  }

  private func backendStopped(_ stoppedClient: BackendClient) {
    guard client === stoppedClient, !quitting else { return }
    client = nil
    phase = .stopped("The backend process ended. Restart it to continue. Your conversations are saved in Muse Code.")
  }

  private func run(_ work: () async throws -> Void) async {
    do { try await work() } catch { errorMessage = error.localizedDescription }
  }

  /// Shows an Ask as a native alert. The last button cancels and is the default, as in Electron.
  private static func show(_ ask: Ask) -> Int {
    let alert = NSAlert()
    alert.messageText = ask.title
    alert.informativeText = [ask.message, ask.detail].compactMap { $0 }.joined(separator: "\n\n")
    for title in ask.buttons { alert.addButton(withTitle: title) }
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    // Electron's cancelId is the last button too, so Escape must choose it. A button holds one key
    // equivalent and the last one holds Return, so NSAlert maps Escape nowhere. This monitor, live
    // only while the alert runs, ends the alert with the last button's response on Escape.
    let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    let cancel = NSApplication.ModalResponse(rawValue: first + max(alert.buttons.count - 1, 0))
    let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53 else { return event }
      NSApp.stopModal(withCode: cancel)
      return nil
    }
    defer { if let escape { NSEvent.removeMonitor(escape) } }
    return alert.runModal().rawValue - first
  }

  private struct SetupError: LocalizedError {
    let errorDescription: String?
  }

  private static func repository() throws -> URL {
    guard let path = Bundle.main.object(forInfoDictionaryKey: "MMacRepository") as? String else {
      throw SetupError(errorDescription: "This mMac build does not name its checkout. Build it with XcodeGen from mac/project.yml.")
    }
    let repository = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: repository.appending(path: "src/headless/server.ts").path) else {
      throw SetupError(errorDescription: "mMac could not find src/headless/server.ts in \(repository.path).")
    }
    return repository
  }

  /// `~/Library/Application Support/mMac`. `MMAC_DATA_FOLDER` overrides it for test runs.
  private static func dataFolder() throws -> URL {
    if let folder = ProcessInfo.processInfo.environment["MMAC_DATA_FOLDER"], !folder.isEmpty {
      return URL(fileURLWithPath: folder)
    }
    return try FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appending(path: "mMac")
  }
}
