import Foundation
import MuseBackend
import Observation

/// The inspector's state for one project: Git status and the open diff, the review actions, Muse
/// worktrees, and the Files tab. Electron keeps the same state in `Inspector.tsx` and the Files
/// page in `WorkspacePages.tsx`. The Workspace owns one and points it at its current project.
@MainActor @Observable
public final class Inspector {
  public enum Tab: String, CaseIterable, Sendable { case changes, files, activity }

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
  public private(set) var diffMetrics = DiffLine.Metrics(maxDigits: 0, maxColumns: 0)
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

  /// Bumped by `show(project:)`. A reply for an earlier project compares it and is dropped.
  private var generation = 0
  private var refreshSequence = 0
  private var diffSequence = 0
  private var filesSequence = 0
  private var previewSequence = 0

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
    // As Electron: a folder Muse cannot list worktrees for simply has none.
    let list = (try? await client.worktrees(project: project)) ?? []
    // A cancelled caller's `try?` gives an empty list; keep the worktrees shown instead.
    guard current(), !Task.isCancelled else { return }
    worktrees = list
    do {
      let status = try await client.gitStatus(project: project)
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
    }
  }

  public func select(_ path: String) async {
    selected = path
    diff = .loading
    await loadDiff()
  }

  /// Shows a changed file's diff pane at once, without reading the diff. The pane reads it with
  /// `select(_:)` from its `.task`, so a read cancelled when the pane goes away runs again when it
  /// comes back. A read for an earlier file is dropped.
  public func open(change path: String) {
    selected = path
    diffSequence += 1
    diff = .loading
  }

  /// Back to the list of changed files.
  public func close() {
    selected = nil
    diffSequence += 1
    diff = .idle
  }

  /// Loads the selected file's diff. A reload keeps the rows shown until the new ones arrive.
  private func loadDiff() async {
    guard let path = selected else { return }
    let project = self.project
    let generation = self.generation
    diffSequence += 1
    let sequence = diffSequence
    do {
      let text = try await client.gitDiff(project: project, path: path)
      guard sequence == diffSequence, generation == self.generation else { return }
      let rows = DiffLine.parse(text)
      diffMetrics = DiffLine.metrics(rows)
      diff = .loaded(rows)
    } catch is CancellationError {
      // The caller stopped waiting, so nothing shows a message; the next select or refresh loads it.
    } catch {
      guard sequence == diffSequence, generation == self.generation else { return }
      diff = .failed(error.localizedDescription)
    }
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

  public func revertHunk(_ index: Int) async {
    guard let path = selected else { return }
    await act { client, project in
      try await client.revertHunk(project: project, path: path, index: index)
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
