import Foundation
import MuseBackend
import Observation

/// The inspector's state for one project: Git status and the open diff, the review actions, Muse
/// worktrees, and the Files tab. Electron keeps the same state in `Inspector.tsx` and the Files
/// page in `WorkspacePages.tsx`. The Workspace owns one and points it at its current project.
@MainActor @Observable
public final class Inspector {
  public enum Tab: String, CaseIterable, Sendable { case changes, files, activity, tasks, agents, preview }

  /// Something that loads after a click: a diff or a file preview.
  public enum Loadable<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    /// The backend's message, which is written for the person.
    case failed(String)
  }

  public var tab: Tab = .changes
  public private(set) var project: String
  public private(set) var git: GitStatus?
  public private(set) var worktrees: [WorktreeEntry] = []
  public private(set) var loading = false
  /// Why the status could not be read.
  public private(set) var error: String?
  /// The changed file whose diff shows.
  public private(set) var selected: String?
  public private(set) var diff: Loadable<[DiffLine]> = .idle
  /// The loaded diff's measurements, taken once when it loads rather than on every render.
  public private(set) var diffMetrics = Inspector.noMetrics
  /// Where Revert hunk takes the hunk text it sends, so the backend reverts the hunk the person
  /// saw or refuses.
  private enum RawHunks {
    /// `git-raw-diff` has not answered for the diff shown, or failed.
    case unread
    /// The raw diff does not match the diff shown: the file changed between the two reads.
    case mismatched
    /// The working-tree hunks, cut from `git-raw-diff` as the backend cuts them.
    case read([String])
  }
  private var rawHunks = RawHunks.unread
  /// True while a review or worktree action runs. The buttons are disabled meanwhile.
  public private(set) var busy = false
  /// A successful merge's message, until the next action.
  public private(set) var notice: String?

  /// The Files tab's folder, relative to the project root. Empty is the root.
  public private(set) var directory = ""
  public private(set) var files: [ProjectFile] = []
  public private(set) var filesLoading = false
  public private(set) var filesError: String?
  /// "Find in this folder…".
  public var query = ""
  public private(set) var previewPath: String?
  public private(set) var preview: Loadable<String> = .idle

  let client: BackendClient
  /// Shows an action's failure. The Workspace sets it to its window alert.
  @ObservationIgnored var reportError: @MainActor (String) -> Void = { _ in }
  /// Receives each status read, so the sidebar's badge for this project stays current.
  @ObservationIgnored var statusRead: @MainActor (String, GitStatus) -> Void = { _, _ in }
  /// True while a view keeps a refresh live that runs `refresh()` whenever the open conversation's
  /// status changes, as `InspectorView`'s `.task(id:)` does. On macOS 15 that view is built when
  /// the window opens and stays built, its task restarting on each change, while the inspector is
  /// collapsed; so this means "the refresh task is live", not "the inspector is on screen".
  /// The Workspace leaves a turn end's badge read to that refresh. Whatever sets this true must
  /// keep the refresh alive until it sets it false.
  @ObservationIgnored public var refreshesOnStatusChange = false
  /// Receives the project whose status read failed, so the Workspace can read a badge it left to
  /// this inspector.
  @ObservationIgnored var statusFailed: @MainActor (String) -> Void = { _ in }

  /// Bumped by `show(project:)`. A reply for an earlier project compares it and is dropped, as is
  /// a confirmation the view showed before the inspector moved to another project.
  public private(set) var generation = 0
  private var refreshSequence = 0
  private var diffSequence = 0
  private var filesSequence = 0
  private var previewSequence = 0

  static let noMetrics = DiffLine.Metrics(maxDigits: 0, maxColumns: 0)

  /// The backend's refusal when a hunk changed after its diff was read (src/headless/revert-hunk.ts).
  /// mMac shows it too when it cannot tell which hunk the person saw.
  nonisolated public static let staleHunk =
    "The file changed since this diff was read. Refresh the diff, then try again."
  /// Shown when the raw diff that Revert hunk sends from could not be read.
  nonisolated public static let unreadHunk =
    "mMac could not read this diff again. Refresh the diff, then try again."

  init(client: BackendClient, project: String) {
    self.client = client
    self.project = project
  }

  /// Shows another project. Everything resets, as Electron remounts its inspector per project.
  func show(project: String) {
    guard project != self.project else { return }
    generation += 1
    self.project = project
    tab = .changes
    git = nil
    worktrees = []
    loading = false
    error = nil
    selected = nil
    diff = .idle
    diffMetrics = Self.noMetrics
    rawHunks = .unread
    busy = false
    notice = nil
    directory = ""
    files = []
    filesLoading = false
    filesError = nil
    query = ""
    previewPath = nil
    preview = .idle
  }

  /// Muse-created worktrees (`<project>/.muse/worktrees/<name>`), which get Merge and Remove.
  public var museWorktrees: [WorktreeEntry] {
    worktrees.filter { ProjectPath.worktreeParent($0.path) != nil }
  }

  /// The branch a merge goes into, as Electron names it.
  public var mainBranch: String {
    worktrees.first(where: \.isMain)?.branch.flatMap { $0.isEmpty ? nil : $0 } ?? "the main checkout"
  }

  public var visibleFiles: [ProjectFile] {
    let needle = query.lowercased()
    return needle.isEmpty ? files : files.filter { $0.name.lowercased().contains(needle) }
  }

  // MARK: Changes

  /// Reads the worktrees and the status. The open diff stays, and reloads, while its file still
  /// has changes; it closes when the file has none.
  public func refresh() async {
    guard !project.isEmpty else { return }
    let project = self.project
    let generation = self.generation
    refreshSequence += 1
    let sequence = refreshSequence
    func current() -> Bool { sequence == refreshSequence && generation == self.generation }
    loading = true
    error = nil
    defer { if current() { loading = false } }
    // Both reads go out at once, as Electron's `Promise.all`. The status shows after the worktrees.
    let client = self.client
    async let listReply = client.worktrees(project: project)
    async let statusReply = client.gitStatus(project: project)
    // As Electron: a folder Muse cannot list worktrees for simply has none.
    let list = (try? await listReply) ?? []
    // A cancelled caller's `try?` gives an empty list; keep the worktrees shown instead. Leaving
    // here cancels the status read.
    guard current(), !Task.isCancelled else { return }
    worktrees = list
    do {
      let status = try await statusReply
      guard current() else { return }
      git = status
      statusRead(project, status)
      if let selected {
        if status.changes.contains(where: { $0.path == selected }) { await loadDiff() } else { close() }
      }
    } catch is CancellationError {
      // The caller stopped waiting; the next refresh reads the status.
    } catch {
      guard current() else { return }
      self.error = error.localizedDescription
      statusFailed(project)
    }
  }

  public func select(_ path: String) async {
    selected = path
    diff = .loading
    rawHunks = .unread
    await loadDiff()
  }

  /// Shows a changed file's diff pane at once, without reading the diff. The pane reads it with
  /// `select(_:)` from its `.task`, so a read cancelled when the pane goes away runs again when it
  /// comes back. A read for an earlier file is dropped.
  public func open(change path: String) {
    selected = path
    diffSequence += 1
    diff = .loading
    rawHunks = .unread
  }

  /// Back to the list of changed files.
  public func close() {
    selected = nil
    diffSequence += 1
    diff = .idle
    diffMetrics = Self.noMetrics
    rawHunks = .unread
  }

  /// Loads the selected file's diff. A reload keeps the rows shown until the new ones arrive.
  /// It reads the labelled diff it shows and, beside it, the raw working diff that Revert hunk
  /// sends from. The labelled diff ends with the same working diff, so a file that changed
  /// between the two reads shows as a mismatch, and no hunk is sent from it.
  private func loadDiff() async {
    guard let path = selected else { return }
    let project = self.project
    let generation = self.generation
    diffSequence += 1
    let sequence = diffSequence
    let client = self.client
    async let shownReply = client.gitDiff(project: project, path: path)
    async let rawReply = client.gitRawDiff(project: project, path: path)
    do {
      let text = try await shownReply
      // A failed raw read still shows the diff; Revert hunk then asks for a refresh.
      let raw = try? await rawReply
      guard sequence == diffSequence, generation == self.generation else { return }
      let rows = DiffLine.parse(text)
      diffMetrics = DiffLine.metrics(rows)
      rawHunks = raw.map { Self.ends(text, with: $0) ? .read(DiffLine.rawHunks($0)) : .mismatched } ?? .unread
      diff = .loaded(rows)
    } catch is CancellationError {
      // The caller stopped waiting, so nothing shows a message; the next select or refresh loads it.
    } catch {
      guard sequence == diffSequence, generation == self.generation else { return }
      diff = .failed(error.localizedDescription)
    }
  }

  /// Compared as bytes, so a "\r" before a "\n" counts.
  static func ends(_ text: String, with suffix: String) -> Bool {
    text.utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8)
  }

  public func stage() async {
    guard let path = selected else { return }
    await act { client, project in
      try await client.stageFile(project: project, path: path)
      return nil
    }
  }

  /// Discards every change to `path`, the file the view asked about. Does nothing when that file
  /// is no longer the selected one, since the person may move on while the confirmation shows.
  public func revertFile(_ path: String) async {
    guard selected == path else { return }
    await act { client, project in
      try await client.revertFile(project: project, path: path)
      return nil
    }
  }

  /// Reverts working-tree hunk `index` of the selected file, sending the hunk's text so the
  /// backend refuses if the file changed since the diff was read. Either way the diff reloads.
  public func revertHunk(_ index: Int) async {
    guard let path = selected else { return }
    let source = rawHunks
    await act { client, project in
      switch source {
      case .unread: throw WorkspaceError(Self.unreadHunk)
      case .mismatched: throw WorkspaceError(Self.staleHunk)
      case .read(let hunks):
        guard hunks.indices.contains(index) else { throw WorkspaceError(Self.staleHunk) }
        try await client.revertHunk(project: project, path: path, index: index, expected: hunks[index])
      }
      return nil
    }
  }

  public func merge(_ entry: WorktreeEntry) async {
    await act { client, project in
      let result = try await client.mergeWorktree(project: project, path: entry.path)
      guard result.ok else {
        throw WorkspaceError(result.output.isEmpty ? "The merge did not finish." : result.output)
      }
      return result.output
    }
  }

  /// Removes a worktree and keeps its branch. The view asks first.
  public func remove(_ entry: WorktreeEntry) async {
    await act { client, project in
      try await client.removeWorktree(project: project, path: entry.path)
      return nil
    }
  }

  /// Runs one action at a time, reports a failure, then refreshes. `work` returns a notice to show.
  private func act(_ work: (BackendClient, String) async throws -> String?) async {
    guard !busy, !project.isEmpty else { return }
    let generation = self.generation
    busy = true
    notice = nil
    var shown: String?
    do {
      shown = try await work(client, project)
    } catch is CancellationError {
      // The caller stopped waiting. The backend still finishes; the refresh shows the result.
    } catch {
      if generation == self.generation { reportError(error.localizedDescription) }
    }
    guard generation == self.generation else { return }
    busy = false
    notice = shown
    // A cancelled caller cannot wait for a refresh. The next one shows the result.
    if !Task.isCancelled { await refresh() }
  }

  // MARK: Files

  public func open(directory: String) async {
    let project = self.project
    let generation = self.generation
    self.directory = directory
    query = ""
    filesSequence += 1
    let sequence = filesSequence
    func current() -> Bool { sequence == filesSequence && generation == self.generation }
    files = []
    filesError = nil
    guard !project.isEmpty else { return }
    filesLoading = true
    defer { if current() { filesLoading = false } }
    do {
      let list = try await client.files(project: project, directory: directory)
      guard current() else { return }
      files = list
    } catch is CancellationError {
      // The caller stopped waiting. The next open lists the folder.
    } catch {
      guard current() else { return }
      filesError = error.localizedDescription
    }
  }

  public func openParent() async { await open(directory: Breadcrumb.parent(of: directory)) }

  /// A folder opens; a file previews.
  public func choose(_ file: ProjectFile) async {
    if file.directory { await open(directory: file.path) } else { await preview(file.path) }
  }

  public func preview(_ path: String) async {
    guard !project.isEmpty else { return }
    let project = self.project
    let generation = self.generation
    previewPath = path
    preview = .loading
    previewSequence += 1
    let sequence = previewSequence
    do {
      let text = try await client.readFile(project: project, path: path)
      guard sequence == previewSequence, generation == self.generation else { return }
      preview = .loaded(text)
    } catch is CancellationError {
      // The caller stopped waiting. The next preview reads the file.
    } catch {
      guard sequence == previewSequence, generation == self.generation else { return }
      preview = .failed(error.localizedDescription)
    }
  }
}
