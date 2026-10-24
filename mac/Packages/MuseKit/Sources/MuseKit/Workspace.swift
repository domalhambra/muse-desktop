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
  /// The inspector follows it, and its badge is read at once, so a worktree conversation's folder
  /// gets its own badge with the inspector hidden. A running `begin()` reads it in its final read.
  public internal(set) var project: String {
    didSet {
      guard project != oldValue else { return }
      // The inspector's read for the old project is dropped now, so read the badge it was to write.
      if pendingTurnEndRead == oldValue { makeUpTurnEndRead() }
      inspector.show(project: project)
      if !project.isEmpty, beginsRunning == 0 { startBadgeRead([project]) }
    }
  }
  /// The inspector for `project`.
  public let inspector: Inspector
  /// Git status per recent project and the current one, for the sidebar's badges. A folder whose
  /// status could not be read has no entry; one outside a repository has a status with
  /// `isRepository` false.
  public internal(set) var projectGit: [String: GitStatus] = [:]
  /// The current project's own status, for the sidebar's badge. A worktree conversation's folder
  /// not yet read has none, rather than its parent's branch and changes.
  public var projectBadge: GitStatus? { project.isEmpty ? nil : projectGit[project] }
  /// Start the next new conversation in its own Muse-created Git worktree.
  public var startInWorktree = false
  /// The sidebar lists archived conversations instead of the others. Not saved, as in Electron;
  /// `startNew()` turns it off.
  public var showArchived = false
  /// Called for every `session` event, with the status that conversation had in the event before
  /// it (nil for the first one this Workspace sees). The app posts the completion notice from it.
  @ObservationIgnored public var turnFinished: (@MainActor (Session, _ previous: String?) -> Void)?
  /// The last status each `session` event gave, for every conversation the events name.
  @ObservationIgnored private var lastStatus: [String: String] = [:]
  /// The folder whose turn-end badge read was left to the inspector's refresh, until that refresh
  /// writes it. If the project changes first, or the inspector's read fails, the Workspace reads it.
  @ObservationIgnored private var pendingTurnEndRead: String?
  /// Bumped when Ask Muse adds to the draft, so the composer takes keyboard focus.
  public internal(set) var composerFocusRequest = 0
  /// The conversation open before a backend restart, opened again once history has loaded.
  private var reopenSessionId: String?
  /// The conversation `begin()` will reopen, until it does. A backend that stops before then hands
  /// it on to the next Workspace.
  public var pendingReopen: String? { reopenSessionId }
  /// How many `begin()` calls have not yet reached their final read of every badge. A `preferences`
  /// event meanwhile (history loading saves the recent projects) leaves the reading to that one.
  private var beginsRunning = 0
  public internal(set) var view: SessionView?
  /// The side session shown in the side chat sheet, or nil. A side session is Muse's: seeded from
  /// the open conversation, and never part of it.
  public internal(set) var sideView: SessionView?
  public internal(set) var sideOpening = false
  /// A subagent's session, shown read-only in a sheet from the Agents tab, or nil.
  public internal(set) var childView: SessionView?
  /// The conversation being opened, for a spinner.
  public private(set) var openingSessionId: String?
  public internal(set) var models: [MuseModel] = []
  /// The model for a new conversation, or the open conversation's model. Empty is the CLI default.
  public internal(set) var modelId = ""
  public var mode: SendMode = .queue
  public internal(set) var submitting = false
  public var errorMessage: String?
  /// The success toast's text. The app shows it for 4 seconds, then sets it to nil. Errors stay in
  /// `errorMessage`.
  public var notice: String?
  /// Bumped by every `showNotice(_:)`, so the same text twice restarts the app's timer.
  public private(set) var noticeCount = 0
  /// The open conversation's PR, or nil. A gh failure sets `pullRequestError` and stops the poll.
  public internal(set) var pullRequest: PullRequest?
  public internal(set) var pullRequestError: String?
  @ObservationIgnored var lastPullRequestPoll: Date?
  /// True while a `pr-status` read runs. `clearPullRequest()` leaves it, so a read for the old
  /// conversation still blocks a second one until it ends; its reply is then dropped.
  @ObservationIgnored var pullRequestInFlight = false
  /// The project's PRs, as change cards.
  public internal(set) var changeCards: [PullRequest] = []
  public internal(set) var decidingApprovals: Set<String> = []
  public internal(set) var answeringQuestions: Set<String> = []
  public internal(set) var storedOutput: [String: String] = [:]
  public internal(set) var loadingOutput: Set<String> = []

  let client: BackendClient
  /// Unsent text by `draftKey`. AppController passes them to the next backend's Workspace.
  public internal(set) var drafts: [String: String] = [:]
  /// The composer's attachment chips: one list beside the draft, not per conversation, as in
  /// Electron. Their ids belong to this backend, so AppController does not pass them on.
  public internal(set) var attachments: [Attachment] = []
  /// Pasted images on disk until their chip is sent or removed. The folder goes with the Workspace.
  let pastedFiles = PastedFiles()
  /// The chip ids of the send in flight. The backend reads each id while it builds the message, so
  /// a chip in this set cannot be removed until the send ends. The chip view disables its ×.
  public internal(set) var sendingAttachmentIds: Set<String> = []
  public func isSending(_ attachmentId: String) -> Bool { sendingAttachmentIds.contains(attachmentId) }
  /// Counts `open` and `startNew` calls. An action that awaits the backend compares it after the
  /// await, so a reply for a conversation the person has left does not change the one shown.
  private(set) var openSequence = 0
  private var refreshSequence = 0
  /// Counts reads of every recent project's badge. An older read that finishes later is dropped.
  private var projectGitSequence = 0
  private var refreshDelay: Task<Void, Never>?
  /// The pause before a `sessions-changed` event refreshes history. Electron waits 250 ms.
  private let refreshDebounce: Duration
  /// The last pin or archive toggle. The next one waits for it, then reads `preferences`.
  @ObservationIgnored var preferenceToggles: Task<Bool, Never>?

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
    inspector.statusRead = { [weak self] path, status in
      guard let self else { return }
      projectGit[path] = status
      if pendingTurnEndRead == path { pendingTurnEndRead = nil }
    }
    inspector.statusFailed = { [weak self] path in
      if let self, pendingTurnEndRead == path { makeUpTurnEndRead() }
    }
  }

  public var sections: [SidebarSection] {
    SidebarSections.build(
      sessions, project: project, pinned: preferences.pinnedSessionIds,
      archived: preferences.archivedSessionIds, showArchived: showArchived, now: .now)
  }
  public var isConnected: Bool { status.isReady }
  public var isRunning: Bool { view?.session.status == "running" }
  /// A new conversation can start in a worktree on a CLI that offers Muse's experimental methods,
  /// in a project known to be a Git repository.
  public var canStartInWorktree: Bool {
    view == nil && status.experimental == true && projectBadge?.isRepository == true
  }
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
    do {
      // Until the read below starts. A change during that read starts a newer one, which wins.
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
    }
    await refreshProjectGit()
  }

  /// Reads the Git status of `only` these projects, or of every recent project and the current one
  /// (a worktree conversation's folder is not a recent project), for the badges.
  public func refreshProjectGit(_ only: [String]? = nil) async {
    let read = badgeRead(only)
    let found = await Self.statuses(read.paths, client: client)
    // A cancelled caller's `try?` reads give no status; keep the badges shown instead.
    guard !Task.isCancelled else { return }
    store(found, from: read)
  }

  /// `refreshProjectGit(_:)` in its own task, which holds the Workspace weakly: a Workspace the app
  /// drops is released while its reads wait, and a read that ends after that is dropped.
  func startBadgeRead(_ only: [String]? = nil) {
    let read = badgeRead(only)
    Task { [weak self, client] in
      let found = await Self.statuses(read.paths, client: client)
      self?.store(found, from: read)
    }
  }

  /// Reads the badge a turn end left to the inspector, whose read will not write it.
  private func makeUpTurnEndRead() {
    guard let root = pendingTurnEndRead else { return }
    pendingTurnEndRead = nil
    startBadgeRead([root])
  }

  /// The folders one badge read covers, and its sequence when it reads every project.
  private struct BadgeRead: Sendable {
    let paths: [String]
    let sequence: Int?
  }

  private func badgeRead(_ only: [String]?) -> BadgeRead {
    var paths = only ?? preferences.recentProjects
    if only == nil, !project.isEmpty, !paths.contains(project) { paths.append(project) }
    guard only == nil else { return BadgeRead(paths: paths, sequence: nil) }
    projectGitSequence += 1
    return BadgeRead(paths: paths, sequence: projectGitSequence)
  }

  /// Reads every folder at once. A folder whose status could not be read has no entry.
  private static func statuses(_ paths: [String], client: BackendClient) async -> [String: GitStatus] {
    await withTaskGroup(of: (String, GitStatus?).self) { group in
      for path in paths { group.addTask { (path, try? await client.gitStatus(project: path)) } }
      var found: [String: GitStatus] = [:]
      for await (path, status) in group { if let status { found[path] = status } }
      return found
    }
  }

  private func store(_ found: [String: GitStatus], from read: BadgeRead) {
    if let sequence = read.sequence {
      // A newer read of every project, for newer recent projects, already replaced this one.
      guard sequence == projectGitSequence else { return }
      // The current project chosen during this read has its own read; keep what that one found.
      var found = found
      if !project.isEmpty, !read.paths.contains(project) { found[project] = projectGit[project] }
      projectGit = found
    } else {
      for path in read.paths { projectGit[path] = found[path] }
    }
  }

  public func apply(_ event: AppEvent) {
    switch event {
    case .connection(let next):
      let becameReady = !status.isReady && next.isReady
      status = next
      // `begin()` holds the Workspace while it runs; a backend stop fails its requests.
      if becameReady { Task { [weak self] in await self?.begin() } }
    case .preferences(let next):
      let projectsChanged = next.recentProjects != preferences.recentProjects
      preferences = next
      // A running `begin()` reads them all once it ends.
      if projectsChanged, beginsRunning == 0 { startBadgeRead() }
    case .session(let next):
      let previous = lastStatus[next.session.sessionId]
      lastStatus[next.session.sessionId] = next.session.status
      turnFinished?(next.session, previous)
      if next.session.sessionId == view?.session.sessionId {
        // A turn that ends may have changed files: read the folder's badge again. A recent project
        // and the current project have badges, so a worktree conversation's own folder does too.
        // An inspector on that folder whose refresh is live reads its status when the open
        // conversation's status changes (`InspectorView`), and that read writes the badge through
        // `statusRead`, so the turn's end needs no second read unless that one does not land.
        if view?.session.status == "running", next.session.status != "running",
          let root = next.session.workspaceRoot, preferences.recentProjects.contains(root) || root == project
        {
          if inspector.refreshesOnStatusChange, inspector.project == root {
            pendingTurnEndRead = root
          } else {
            startBadgeRead([root])
          }
        }
        view = next
      }
      if next.session.sessionId == sideView?.session.sessionId { sideView = next }
      if next.session.sessionId == childView?.session.sessionId { childView = next }
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
    case .usageChanged:
      break
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
    sideView = nil
    childView = nil
    clearPullRequest()
    mode = .queue
    // As Electron's startNew: back to the normal list.
    showArchived = false
    clearStoredOutput()
  }

  /// The PR monitor belongs to one conversation: another one starts with a first look of its own.
  func clearPullRequest() {
    pullRequest = nil
    pullRequestError = nil
    lastPullRequestPoll = nil
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
      if opened.session.sessionId != view?.session.sessionId { sideView = nil; childView = nil; clearPullRequest() }
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

  /// Shows a success toast, as Electron's `showSuccess`.
  public func showNotice(_ text: String) {
    notice = text
    noticeCount += 1
  }
}
