import MuseBackend
import MuseKit
import SwiftUI

/// The Changes tab, as Electron's: changed files, a file's diff with its review buttons, and
/// Muse worktrees with Merge and Remove.
struct ChangesView: View {
  let workspace: Workspace
  let inspector: Inspector

  var body: some View {
    if let path = inspector.selected {
      DiffPane(workspace: workspace, inspector: inspector, path: path)
    } else {
      list
    }
  }

  /// As Electron: no review while an action or a turn runs, so Muse and the person never edit at once.
  private var locked: Bool { inspector.busy || workspace.isRunning }
  private var lockedHelp: String? { workspace.isRunning ? "Wait for the current turn to finish" : nil }

  private var list: some View {
    List {
      // The open conversation's pull request, as a change card.
      if workspace.view != nil {
        if let error = workspace.pullRequestError {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(error).font(.caption).foregroundStyle(.themeSecondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Retry") { Task { await workspace.retryPullRequest() } }
              .controlSize(.small)
              .accessibilityLabel("Read the pull request again")
              .accessibilityIdentifier("pull-request-retry")
          }
        } else if let pr = workspace.pullRequest {
          ChangeCardView(pr: pr, all: [pr], workspace: workspace, conversationCard: true)
            .listRowSeparator(.hidden)
        }
      }
      if let error = inspector.error {
        Text(error).foregroundStyle(.red)
      }
      if let changes = inspector.git?.changes, !changes.isEmpty {
        Section {
          ForEach(changes) { change in
            Button {
              // The pane reads the diff itself, so a read cut short when it goes away runs again.
              inspector.open(change: change.path)
            } label: {
              ChangedFileRow(change: change)
            }
            .buttonStyle(.plain)
            .help(change.path)
            .filePathMenu(change.path, workspace: workspace)
            // A button reads its label as one string, so it says the colour-coded status in words.
            .accessibilityLabel(
              "\(ChangeLabel.name(change.path)), \(ChangeLabel.folder(change.path)), \(ChangeLabel.spoken(change))")
          }
        }
      } else if inspector.error == nil {
        // Until the first read answers, a project is being read: "No Git repository" must not flash.
        if inspector.git == nil, !workspace.project.isEmpty {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading your workspace…").foregroundStyle(.themeSecondary)
          }
        } else {
          EmptyChanges(project: workspace.project, git: inspector.git)
        }
      }
      if !inspector.museWorktrees.isEmpty {
        Section("Muse worktrees") {
          ForEach(inspector.museWorktrees) { entry in
            WorktreeRow(
              entry: entry, mainBranch: inspector.mainBranch, locked: locked, lockedHelp: lockedHelp,
              busy: inspector.busy, isOpen: entry.path == workspace.project,
              merge: { Task { await inspector.merge(entry) } },
              remove: { Task { await confirmRemove(entry) } })
          }
        }
      }
      // A merge's message, under the worktree it came from.
      if let notice = inspector.notice {
        Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green)
      }
    }
    .listStyle(.inset)
    // The loop only asks the rule; the rule holds the 60-second pace and the first look.
    .task(id: workspace.view?.session.sessionId) {
      while !Task.isCancelled {
        if workspace.shouldPollPullRequest(showingChanges: true, now: .now) { await workspace.refreshPullRequest() }
        try? await Task.sleep(for: .seconds(15))
      }
    }
  }

  private func confirmRemove(_ entry: WorktreeEntry) async {
    let name = ProjectPath.name(of: entry.path)
    // Electron writes "The branch  is kept." for a detached worktree; this names no branch instead.
    let kept = entry.branch.flatMap { $0.isEmpty ? nil : "The branch \($0) is kept." } ?? "Its branch is kept."
    // The answer is for the project shown now.
    let generation = inspector.generation
    let choice = await SheetAlert.present(
      title: "Remove the worktree \(name)?",
      message: "Uncommitted changes in it are discarded. \(kept)",
      buttons: ["Remove", "Cancel"])
    // Things may have moved on while the sheet showed: another project, another action, or this
    // worktree opened.
    guard choice == 0, inspector.generation == generation, !inspector.busy, entry.path != workspace.project
    else { return }
    await inspector.remove(entry)
  }
}

struct ChangedFileRow: View {
  let change: GitChange

  var body: some View {
    let name = ChangeLabel.name(change.path)
    HStack(spacing: 8) {
      Image(systemName: FileKind.of(name: name, directory: false).symbol)
        .foregroundStyle(.themeSecondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(name).lineLimit(1)
        Text(ChangeLabel.folder(change.path))
          .font(.caption)
          .foregroundStyle(.themeSecondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer(minLength: 4)
      Text(ChangeLabel.status(change))
        .font(.caption.monospaced().bold())
        .foregroundStyle(ChangeLabel.isDeleted(change) ? .red : .orange)
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(.themeMuted).accessibilityHidden(true)
    }
    .contentShape(.rect)
  }
}

/// Electron's three empty states for the Changes tab.
struct EmptyChanges: View {
  let project: String
  let git: GitStatus?

  var body: some View {
    let (title, text) =
      project.isEmpty
      ? ("Open a project", "Open a project and its changes will appear here.")
      : git?.isRepository == true
        ? ("No changes", "Your working tree has no changes.")
        : ("No Git repository", "This folder isn’t a Git repository. Muse can still work with its files.")
    ContentUnavailableView(title, systemImage: "checkmark", description: Text(text).foregroundStyle(.themeSecondary))
  }
}

struct WorktreeRow: View {
  let entry: WorktreeEntry
  let mainBranch: String
  let locked: Bool
  let lockedHelp: String?
  let busy: Bool
  let isOpen: Bool
  let merge: () -> Void
  let remove: () -> Void

  var body: some View {
    let name = ProjectPath.name(of: entry.path)
    HStack(spacing: 8) {
      Image(systemName: "arrow.triangle.branch").foregroundStyle(.themeSecondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(name).lineLimit(1).help(entry.path)
        Text(detail).font(.caption).foregroundStyle(.themeSecondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      Button("Merge", action: merge)
        .disabled(locked)
        .accessibilityLabel("Merge \(name) into \(mainBranch)")
        .help(lockedHelp ?? "Merge \(branchOrName(name)) into \(mainBranch)")
      Button("Remove", action: remove)
        .disabled(busy || isOpen)
        .accessibilityLabel("Remove worktree \(name)")
        .help(
          isOpen
            ? "Open another conversation before removing this worktree"
            : "Remove this worktree (its branch is kept)")
    }
    .controlSize(.small)
  }

  /// As Electron's `entry.branch || name`: an empty branch counts as none.
  private func branchOrName(_ name: String) -> String {
    entry.branch.flatMap { $0.isEmpty ? nil : $0 } ?? name
  }

  /// "muse/fix · a conversation open", as Electron's worktree row.
  private var detail: String {
    let branch = entry.branch.flatMap { $0.isEmpty ? nil : $0 } ?? "Detached"
    switch entry.sessionIds.count {
    case 0: return branch
    case 1: return "\(branch) · a conversation open"
    case let count: return "\(branch) · \(count) conversations open"
    }
  }
}

/// One file's diff, with Stage, Revert file and Ask Muse above it.
struct DiffPane: View {
  let workspace: Workspace
  let inspector: Inspector
  let path: String

  /// Also locked while the status reloads after an action or a turn: until the new rows arrive, the
  /// shown "Revert hunk 2" may not be the backend's hunk 2.
  private var locked: Bool { inspector.busy || inspector.loading || workspace.isRunning }
  private var lockedHelp: String? { workspace.isRunning ? "Wait for the current turn to finish" : nil }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Button {
          inspector.close()
        } label: {
          Label(path, systemImage: "chevron.left").lineLimit(1).truncationMode(.head)
        }
        .buttonStyle(.borderless)
        .filePathMenu(path, workspace: workspace)
        .accessibilityLabel("Back to the changed files")
        .accessibilityValue(path)
        .help("Back to the changed files")
        Spacer(minLength: 8)
        Button("Stage") { Task { await inspector.stage() } }
          .disabled(locked)
          .help(lockedHelp ?? "Stage this file")
        Button("Revert file") { Task { await confirmRevert() } }
          .disabled(locked)
          .help(lockedHelp ?? "Discard all changes to this file")
        Button {
          workspace.askAboutChanges(path)
        } label: {
          Label("Ask Muse", systemImage: "arrow.up.right")
        }
        .help("Ask Muse to review these changes")
      }
      .controlSize(.small)
      .padding(8)
      Divider()
      switch inspector.diff {
      case .idle, .loading:
        ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        Text(message)
          .foregroundStyle(.themeSecondary)
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      case .loaded(let rows):
        DiffView(rows: rows, locked: locked, lockedHelp: lockedHelp, revert: { index in
          Task { await inspector.revertHunk(index) }
        }, metrics: inspector.diffMetrics)
        .equatable()
      }
    }
    // The pane reads its diff. A read cancelled when the pane went away (another tab, the
    // inspector closed) leaves `.loading`, so a returning pane reads again. A loaded diff stays;
    // the inspector's refresh reloads it when a turn ends.
    .task(id: path) {
      if case .loaded = inspector.diff { return }
      guard inspector.selected == path, !Task.isCancelled else { return }
      await inspector.select(path)
    }
  }

  private func confirmRevert() async {
    // The answer is for the project shown now.
    let generation = inspector.generation
    let choice = await SheetAlert.present(
      title: "Discard all changes to \(path)?", message: "", buttons: ["Revert file", "Cancel"])
    // Another project may show, or a turn may have started, while the sheet showed. `revertFile`
    // drops a file no longer selected.
    guard choice == 0, inspector.generation == generation, !workspace.isRunning else { return }
    await inspector.revertFile(path)
  }
}

/// A line-numbered diff. Each working-tree hunk header carries a labelled Revert hunk button.
/// Equatable without its closure, so a re-render of the conversation (a streamed token) does not
/// rebuild every row.
struct DiffView: View, Equatable {
  let rows: [DiffLine]
  let locked: Bool
  let lockedHelp: String?
  let revert: (Int) -> Void
  /// Measured once when the diff loaded, so a re-render does no per-row work.
  let metrics: DiffLine.Metrics

  nonisolated static func == (lhs: DiffView, rhs: DiffView) -> Bool {
    lhs.rows == rhs.rows && lhs.locked == rhs.locked && lhs.lockedHelp == rhs.lockedHelp
      && lhs.metrics == rhs.metrics
  }

  /// The gutter's width, from the largest line number's digits.
  private var gutterWidth: CGFloat { CGFloat(max(metrics.maxDigits, 2)) * Self.advance + 4 }

  /// One width for every row, from the longest line, so row tints line up and the horizontal
  /// scroller holds still. Room for a Revert hunk button is always kept.
  private var contentWidth: CGFloat {
    Self.padding * 2 + gutterWidth + Self.spacing + CGFloat(metrics.maxColumns) * Self.advance
      + Self.hunkButtonWidth
  }

  static let padding: CGFloat = 8
  static let spacing: CGFloat = 8
  /// Room for the mini "Revert hunk" button and the space before it.
  static let hunkButtonWidth: CGFloat = 96
  /// The advance of one character of the diff's font, `.caption` monospaced.
  static let advance: CGFloat = {
    let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    return ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 100) / 100
  }()

  var body: some View {
    GeometryReader { proxy in
      let width = max(contentWidth, proxy.size.width)
      let gutterWidth = gutterWidth
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            DiffRow(
              row: row, width: width, gutterWidth: gutterWidth, locked: locked, lockedHelp: lockedHelp,
              revert: revert,
              copyHunk: { Self.copy(DiffLine.hunkText(rows, at: row.id)) },
              copyDiff: { Self.copy(DiffLine.text(rows)) }
            )
          }
        }
        .padding(.vertical, 6)
      }
    }
    .font(.system(.caption, design: .monospaced))
    .accessibilityIdentifier("diff")
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

struct DiffRow: View {
  let row: DiffLine
  @Environment(\.appearance) private var appearance
  /// The width every row shares, so each tint and context-menu target spans the whole row.
  let width: CGFloat
  let gutterWidth: CGFloat
  let locked: Bool
  let lockedHelp: String?
  let revert: (Int) -> Void
  let copyHunk: () -> Void
  let copyDiff: () -> Void

  var body: some View {
    HStack(spacing: DiffView.spacing) {
      Text(row.gutter)
        .foregroundStyle(.themeMuted)
        .frame(width: gutterWidth, alignment: .trailing)
        .accessibilityHidden(true)
      // A very long line, such as a minified file, shows cut. Copy hunk and Copy diff copy it whole.
      Text(row.text.isEmpty ? " " : DiffLine.display(row.text))
        .foregroundStyle(foreground)
        .textSelection(.enabled)
        .fixedSize()
        // "Added, line 12, let b = 3": the tint and the gutter say it only to the eye. Its own
        // element, read as text: with the label set on the selectable text itself, in this row,
        // any accessibility read of an open diff recursed through the label until the main
        // thread's stack overflowed. Selectable labelled text elsewhere, such as the Bridges
        // token, did not. Why this row and not that one is not known.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(row.spoken)
      if let index = row.hunkIndex {
        Button("Revert hunk") { revert(index) }
          .controlSize(.mini)
          .disabled(locked)
          .accessibilityLabel("Revert hunk \(index + 1)")
          .help(lockedHelp ?? "Revert this hunk")
      }
    }
    .padding(.horizontal, DiffView.padding)
    .padding(.vertical, 1)
    .frame(width: width, alignment: .leading)
    .background(background)
    .contentShape(.rect)
    .contextMenu {
      if row.kind == .hunk {
        Button("Copy hunk", action: copyHunk)
      }
      Button("Copy diff", action: copyDiff)
    }
  }

  /// Added and removed text stays primary for contrast; the row's tint carries the kind.
  private var foreground: Color {
    switch row.kind {
    case .hunk: appearance.colors.accent
    case .meta: appearance.colors.secondary
    case .added, .removed, .context: appearance.colors.text
    }
  }

  private var background: Color {
    switch row.kind {
    case .added: .green.opacity(0.15)
    case .removed: .red.opacity(0.15)
    case .hunk: appearance.colors.accent.opacity(0.1)
    case .meta, .context: .clear
    }
  }
}
