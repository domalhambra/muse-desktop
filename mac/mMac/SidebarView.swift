import MuseBackend
import MuseKit
import SwiftUI

struct SidebarView: View {
  let controller: AppController
  @Bindable var workspace: Workspace
  /// The picker entry that opens the panel instead of choosing a project.
  private static let openAnother = "\u{0}open-another"
  /// Changed after the open panel closes, so the picker draws the current project again
  /// instead of the "Open another project…" entry the person clicked.
  @State private var pickerGeneration = 0
  /// The row the arrow keys moved to. Nil when the highlight follows the open conversation.
  @State private var highlighted: String?
  /// Read in `body`, so a change redraws the list: after a deselect, or at midnight.
  @State private var redraw = 0

  var body: some View {
    let _ = redraw
    List(selection: selection) {
      Section {
        Button {
          workspace.startNew()
        } label: {
          Label("New conversation", systemImage: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .help("New conversation (⌘N)")
        Picker("Current project", selection: projectSelection) {
          Text("All projects").tag("")
          ForEach(projects, id: \.self) { path in
            Text(projectLabel(path)).tag(path)
          }
          Divider()
          Text("Open another project…").tag(Self.openAnother)
        }
        // The label is for VoiceOver only, as in Electron, so project names fit at 240 points.
        .labelsHidden()
        .id(pickerGeneration)
        if !workspace.project.isEmpty,
          let git = workspace.projectGit[ProjectPath.root(of: workspace.project)], git.isRepository
        {
          HStack(spacing: 6) {
            Label(git.branch, systemImage: "arrow.triangle.branch")
              .lineLimit(1)
              .accessibilityLabel("Branch \(git.branch)")
            GitBadgeView(status: git)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("project-git-badge")
        }
      }
      history
    }
    .listStyle(.sidebar)
    .onKeyPress(.return) {
      guard let sessionId = highlighted else { return .ignored }
      highlighted = nil
      Task { await workspace.open(sessionId) }
      return .handled
    }
    .onChange(of: workspace.view?.session.sessionId) { highlighted = nil }
    // `sections` groups by `.now` each time the list draws, so this moves yesterday's rows.
    // The notification is posted on the main thread.
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in redraw += 1 }
    .safeAreaInset(edge: .bottom) { connectionFooter }
  }

  /// The recent projects, then the current one if it is not among them, as Electron lists them.
  private var projects: [String] {
    let recent = workspace.preferences.recentProjects
    return workspace.project.isEmpty || recent.contains(workspace.project)
      ? recent : recent + [workspace.project]
  }

  /// "muse-desktop — main · 3 changed", as Electron's project cards show branch and changes.
  private func projectLabel(_ path: String) -> String {
    let name = ProjectPath.name(of: path)
    guard let status = workspace.projectGit[path], let summary = GitBadge.summary(status) else { return name }
    return "\(name) — \(summary)"
  }

  private var projectSelection: Binding<String> {
    Binding(
      get: { workspace.project },
      set: { value in
        if value == Self.openAnother {
          Task {
            await controller.openProject()
            pickerGeneration += 1
          }
        } else {
          workspace.selectProject(value)
        }
      })
  }

  /// The row the arrow keys moved to, else the conversation being opened, else the open one.
  /// As Electron, a row opens on a click or Return, not as the arrow keys pass it.
  private var selection: Binding<String?> {
    Binding(
      get: { highlighted ?? workspace.openingSessionId ?? workspace.view?.session.sessionId },
      set: { sessionId in
        guard let sessionId else {
          // A Command-click on the open row: draw it highlighted again.
          highlighted = nil
          redraw += 1
          return
        }
        if NSApp.currentEvent?.type == .keyDown {
          highlighted = sessionId
          return
        }
        highlighted = nil
        Task { await workspace.open(sessionId) }
      })
  }

  @ViewBuilder private var history: some View {
    // Read once: each read groups and sorts every session.
    let sections = workspace.sections
    if let error = workspace.historyError {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text("Could not load your conversation history.").font(.headline)
          Text(error).foregroundStyle(.secondary)
          Button("Try again") { Task { await workspace.refreshSessions() } }
        }
      }
    }
    ForEach(sections) { section in
      Section(section.title) {
        ForEach(section.sessions) { session in
          SessionRow(session: session, showProject: workspace.project.isEmpty)
            .tag(session.sessionId)
        }
      }
    }
    // `historyLoading` is true only until the first refresh succeeds. Rows from pages already
    // loaded show above it, as in Electron.
    if workspace.historyLoading, workspace.isConnected {
      Section {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading Muse history…")
        }
      }
    } else if sections.isEmpty, workspace.historyError == nil, workspace.isConnected {
      Section {
        VStack(alignment: .leading, spacing: 2) {
          Text("No conversations yet").font(.headline)
          Text("Start a conversation in this project.").foregroundStyle(.secondary)
        }
      }
    }
  }

  /// On a bar background, so rows do not show through it as the list scrolls.
  private var connectionFooter: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 6) {
        Circle().fill(dotColor).frame(width: 7, height: 7)
        Text(statusText).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .help(workspace.status.version.map { "Muse Code \($0)" } ?? workspace.status.message ?? "")
    }
    .background(.bar)
  }

  private var statusText: String {
    switch workspace.status.state {
    case "ready": "Connected to Muse Code"
    case "connecting": "Connecting to Muse…"
    default: "Muse Code disconnected"
    }
  }

  /// Electron's `status-dot`: green when ready, the accent while connecting, a warning otherwise.
  private var dotColor: Color {
    switch workspace.status.state {
    case "ready": .green
    case "connecting": .accentColor
    default: .orange
    }
  }
}

/// One conversation in the history, as Electron's sidebar row.
struct SessionRow: View {
  let session: Session
  let showProject: Bool

  var body: some View {
    HStack(spacing: 8) {
      if session.status == "running" {
        ProgressView().controlSize(.mini).accessibilityLabel("Working")
      } else {
        Image(systemName: "bubble.left").foregroundStyle(.secondary).accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(SessionTitle.of(session)).lineLimit(1)
        // Electron names the session's own folder, so a worktree shows its worktree's name.
        if showProject, let root = session.workspaceRoot, !root.isEmpty {
          Text(ProjectPath.name(of: root))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if ProjectPath.isWorktree(session) {
        Text("worktree")
          .font(.caption2)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(.quaternary, in: Capsule())
          .help(session.worktree?.path ?? session.workspaceRoot ?? "")
      }
      TimelineView(.everyMinute) { context in
        Text(RelativeTime.text(SidebarSections.activity(session), now: context.date))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .help(SessionTitle.of(session))
  }
}
