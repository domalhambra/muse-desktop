import Foundation
import MuseBackend
import Observation

/// An error mMac writes itself, as opposed to one the backend sends.
public struct WorkspaceError: LocalizedError, Equatable, Sendable {
  public let errorDescription: String?
  public init(_ message: String) { errorDescription = message }
}

/// The conversation state of the mMac window: the connection, Muse history, the project filter,
/// the open conversation and the composer. Every change goes through the backend; this keeps what
/// the views draw. Electron keeps the same state in `src/renderer/src/App.tsx`.
@MainActor @Observable
public final class Workspace {
  public enum SendOutcome: Equatable, Sendable {
    case sent
    /// No conversation is open and no project is chosen. Show the project panel, then send again.
    case needsProject
    case notSent
  }

  public private(set) var status: ConnectionStatus
  public internal(set) var preferences: Preferences
  public private(set) var sessions: [Session] = []
  /// True only until the first refresh succeeds, as in Electron. Later refreshes run quietly.
  public private(set) var historyLoading = false
  private var hasLoadedHistory = false
  public private(set) var historyError: String?
  /// The project filter, and the folder a new conversation starts in. Empty means all projects.
  /// The inspector follows it.
  public internal(set) var project: String {
    didSet { if project != oldValue { inspector.show(project: project) } }
  }
  /// The inspector for `project`.
  public let inspector: Inspector
  /// Git status per recent project, for the sidebar's badges. A folder whose status could not be
  /// read has no entry; one outside a repository has a status with `isRepository` false.
  public internal(set) var projectGit: [String: GitStatus] = [:]
  /// Start the next new conversation in its own Muse-created Git worktree.
  public var startInWorktree = false
  /// Bumped when Ask Muse adds to the draft, so the composer takes keyboard focus.
  public internal(set) var composerFocusRequest = 0
  /// The conversation open before a backend restart, opened again once history has loaded.
  private var reopenSessionId: String?
  /// How many `begin()` calls are running. Each ends by reading every badge, so a `preferences`
  /// event meanwhile (history loading saves the recent projects) does not read them too.
  private var beginsRunning = 0
  public internal(set) var view: SessionView?
  /// The conversation being opened, for a spinner.
  public private(set) var openingSessionId: String?
  public internal(set) var models: [MuseModel] = []
  /// The model for a new conversation, or the open conversation's model. Empty is the CLI default.
  public internal(set) var modelId = ""
  public var mode: SendMode = .queue
  public internal(set) var submitting = false
  public var errorMessage: String?
  public internal(set) var decidingApprovals: Set<String> = []
  public internal(set) var answeringQuestions: Set<String> = []
  public internal(set) var storedOutput: [String: String] = [:]
  public internal(set) var loadingOutput: Set<String> = []

  let client: BackendClient
  /// Unsent text by `draftKey`. AppController passes them to the next backend's Workspace.
  public internal(set) var drafts: [String: String] = [:]
  /// Counts `open` and `startNew` calls. An action that awaits the backend compares it after the
  /// await, so a reply for a conversation the person has left does not change the one shown.
  private(set) var openSequence = 0
  private var refreshSequence = 0
  /// Counts reads of every recent project's badge. An older read that finishes later is dropped.
  private var projectGitSequence = 0
  private var refreshDelay: Task<Void, Never>?
  /// The pause before a `sessions-changed` event refreshes history. Electron waits 250 ms.
  private let refreshDebounce: Duration

  /// `drafts` are an earlier Workspace's, so a backend restart keeps what the person typed, and
  /// `reopen` is the conversation that was open then.
  public init(
    client: BackendClient, started: Started, drafts: [String: String] = [:], reopen: String? = nil,
    refreshDebounce: Duration = .milliseconds(250)
  ) {
    self.client = client
    self.drafts = drafts
    status = started.status
    preferences = started.preferences
    let project = started.preferences.recentProjects.first ?? ""
    inspector = Inspector(client: client, project: project)
    self.project = project
    reopenSessionId = reopen
    self.refreshDebounce = refreshDebounce
    inspector.reportError = { [weak self] message in self?.errorMessage = message }
    inspector.statusRead = { [weak self] path, status in self?.projectGit[path] = status }
  }

  public var sections: [SidebarSection] {
    SidebarSections.build(sessions, project: project, now: .now)
  }
  public var isConnected: Bool { status.isReady }
  public var isRunning: Bool { view?.session.status == "running" }
  /// A new conversation can start in a worktree on a CLI that offers Muse's experimental methods.
  public var canStartInWorktree: Bool { view == nil && status.experimental == true }
  public var effort: String { preferences.reasoningEffort }

  /// The composer text for the open conversation, or for a new one in the current project.
  /// Drafts live in memory only, as in Electron, and outlast a backend restart.
  public var draft: String {
    get { drafts[draftKey] ?? "" }
    set { drafts[draftKey] = newValue }
  }
  var draftKey: String { view?.session.sessionId ?? "new:\(project)" }

  /// Loads history, models and the project badges, and reopens the conversation open before a
  /// restart. Call it once `start` has replied; a later `ready` event calls it again.
  public func begin() async {
    guard status.isReady else { return }
    beginsRunning += 1
    defer { beginsRunning -= 1 }
    await refreshSessions()
    await loadModels()
    if let reopen = reopenSessionId {
      reopenSessionId = nil
      // Not over a conversation the person opened, is opening, or is sending a first message to
      // while history loaded.
      if view == nil, openingSessionId == nil, !submitting { await open(reopen) }
    }
    await refreshProjectGit()
  }

  /// Reads the Git status of `only` these projects, or of every recent project, for the badges.
  public func refreshProjectGit(_ only: [String]? = nil) async {
    let paths = only ?? preferences.recentProjects
    var sequence: Int?
    if only == nil {
      projectGitSequence += 1
      sequence = projectGitSequence
    }
    let client = self.client
    let found = await withTaskGroup(of: (String, GitStatus?).self) { group in
      for path in paths { group.addTask { (path, try? await client.gitStatus(project: path)) } }
      var found: [String: GitStatus] = [:]
      for await (path, status) in group { if let status { found[path] = status } }
      return found
    }
    // A cancelled caller's `try?` reads give no status; keep the badges shown instead.
    guard !Task.isCancelled else { return }
    if let sequence {
      // A newer read of every project, for newer recent projects, already replaced this one.
      guard sequence == projectGitSequence else { return }
      projectGit = found
    } else {
      for path in paths { projectGit[path] = found[path] }
    }
  }

  public func apply(_ event: AppEvent) {
    switch event {
    case .connection(let next):
      let becameReady = !status.isReady && next.isReady
      status = next
      if becameReady { Task { await begin() } }
    case .preferences(let next):
      let projectsChanged = next.recentProjects != preferences.recentProjects
      preferences = next
      // A running `begin()` reads them all once it ends.
      if projectsChanged, beginsRunning == 0 { Task { await refreshProjectGit() } }
    case .session(let next):
      if next.session.sessionId == view?.session.sessionId {
        // A turn that ends may have changed files: read the project's badge again. Only a recent
        // project has a badge; a worktree conversation's folder does not.
        if view?.session.status == "running", next.session.status != "running",
          let root = next.session.workspaceRoot, preferences.recentProjects.contains(root)
        {
          Task { await refreshProjectGit([root]) }
        }
        view = next
      }
      if let index = sessions.firstIndex(where: { $0.sessionId == next.session.sessionId }) {
        // Only on a change: every streamed update sends a session event, and the sidebar
        // rebuilds its sections whenever `sessions` is written.
        if sessions[index] != next.session { sessions[index] = next.session }
      }
    case .sessionsChanged:
      // Cancels only a pause still waiting. A refresh that already started is not cancelled,
      // which would cancel its request; the newer refresh's sequence retires it instead.
      refreshDelay?.cancel()
      // Weak: the stored task must not keep the Workspace alive through the pause.
      refreshDelay = Task { [weak self, refreshDebounce] in
        try? await Task.sleep(for: refreshDebounce)
        guard !Task.isCancelled, let self else { return }
        self.refreshDelay = nil
        await self.refreshSessions()
      }
    case .error(let message):
      errorMessage = message
    case .other:
      break
    }
  }

  /// Loads every page of Muse history. A newer refresh makes an older one stop.
  public func refreshSessions() async {
    refreshSequence += 1
    let sequence = refreshSequence
    if !hasLoadedHistory { historyLoading = true }
    historyError = nil
    defer { if sequence == refreshSequence { historyLoading = false } }
    // Labels known before this refresh. Each page also reads the current rows, for a session
    // event that named a conversation between pages. The open conversation counts too: a new one
    // has no row until a refresh adds it.
    let before = Self.byId(sessions)
    var merged: [String: Session] = [:]
    var order: [String] = []
    var cursor: String?
    var seen = Set<String>()
    do {
      repeat {
        let page = try await client.sessions(cursor: cursor)
        guard sequence == refreshSequence else { return }
        var known = before.merging(Self.byId(sessions)) { _, now in now }
        if let open = view?.session { known[open.sessionId] = Self.keepingKnownLabels(open, from: known) }
        for session in page.sessions {
          if merged[session.sessionId] == nil { order.append(session.sessionId) }
          merged[session.sessionId] = Self.keepingKnownLabels(session, from: known)
        }
        sessions = order.compactMap { merged[$0] }
        cursor = page.nextCursor
        if let cursor, !seen.insert(cursor).inserted {
          throw WorkspaceError("Muse returned a repeated history cursor. Reconnect to refresh history.")
        }
      } while cursor != nil
      hasLoadedHistory = true
    } catch is CancellationError {
      // Not a failure the person needs to see.
    } catch {
      if sequence == refreshSequence { historyError = error.localizedDescription }
    }
  }

  private static func byId(_ sessions: [Session]) -> [String: Session] {
    Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// `session/list` lags a live conversation. Just after a turn it can leave out the name, the title
  /// and the first prompt that session events already gave. Keep each one the list leaves out; a
  /// value in the list wins. (The CLI lowercases ASCII letters in names.)
  static func keepingKnownLabels(_ session: Session, from known: [String: Session]) -> Session {
    guard let old = known[session.sessionId] else { return session }
    var kept = session
    kept.name = session.name ?? old.name
    kept.title = session.title ?? old.title
    kept.firstUserPrompt = session.firstUserPrompt ?? old.firstUserPrompt
    return kept
  }

  /// Shows a recent project, or all projects for an empty path, and starts a new conversation.
  public func selectProject(_ path: String) {
    project = path
    startNew()
  }

  /// Closes the open conversation, so the composer starts a new one. An `open` still in flight is
  /// dropped, as Electron's `startNew` does.
  public func startNew() {
    openSequence += 1
    openingSessionId = nil
    view = nil
    mode = .queue
    clearStoredOutput()
  }

  /// Stored output belongs to one conversation's items.
  private func clearStoredOutput() {
    storedOutput = [:]
    loadingOutput = []
  }

  /// Adds a folder chosen in the open panel and selects its real path.
  @discardableResult
  public func addProject(_ folder: URL) async -> Bool {
    do {
      selectProject(try await client.addProject(folder))
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Opens a conversation. A reply that arrives after a newer `open` started is ignored, so the
  /// last click wins. `force` reopens the open conversation, after a reconnect.
  public func open(_ sessionId: String, force: Bool = false) async {
    if !force, sessionId == view?.session.sessionId {
      // Already shown. Drop any other open still in flight, so it does not replace this one.
      // With nothing opening the click changes nothing, so a pending reply for this one still lands.
      if openingSessionId != nil {
        openSequence += 1
        openingSessionId = nil
      }
      return
    }
    openSequence += 1
    let sequence = openSequence
    openingSessionId = sessionId
    defer { if sequence == openSequence { openingSessionId = nil } }
    do {
      let opened = try await client.open(sessionId)
      guard sequence == openSequence else { return }
      if opened.session.sessionId != view?.session.sessionId { clearStoredOutput() }
      view = opened
      // As Electron: a conversation without a folder shows all projects, so it stays visible.
      project = opened.session.workspaceRoot ?? ""
      modelId = opened.session.modelId ?? ""
    } catch {
      guard sequence == openSequence else { return }
      errorMessage = error.localizedDescription
    }
  }

  /// Loads the models Muse offers. A new conversation starts on the default one, as in Electron.
  public func loadModels() async {
    do {
      models = try await client.models()
      if modelId.isEmpty { modelId = models.first(where: \.isDefault)?.modelId ?? "" }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Runs one backend call and shows its error, if any.
  func run(_ work: () async throws -> Void) async {
    do { try await work() } catch { errorMessage = error.localizedDescription }
  }
}
