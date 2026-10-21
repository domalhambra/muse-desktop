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

  var body: some View {
    List(selection: selection) {
      Section {
        Button {
          workspace.startNew()
        } label: {
          Label("New conversation", systemImage: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .help("New conversation (⌘N)")
        Picker("Current project", selection: projectSelection) {
          Text("All projects").tag("")
          ForEach(projects, id: \.self) { path in
            Text(ProjectPath.name(of: path)).tag(path)
          }
          Divider()
          Text("Open another project…").tag(Self.openAnother)
        }
        .id(pickerGeneration)
      }
      history
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { connectionFooter }
  }

  /// The recent projects, then the current one if it is not among them, as Electron lists them.
  private var projects: [String] {
    let recent = workspace.preferences.recentProjects
    return workspace.project.isEmpty || recent.contains(workspace.project)
      ? recent : recent + [workspace.project]
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

  /// The conversation being opened, else the open one. A click highlights its row at once.
  private var selection: Binding<String?> {
    Binding(
      get: { workspace.openingSessionId ?? workspace.view?.session.sessionId },
      set: { sessionId in
        if let sessionId { Task { await workspace.open(sessionId) } }
      })
  }

  @ViewBuilder private var history: some View {
    if let error = workspace.historyError {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text("Could not load your conversation history.").font(.headline)
          Text(error).foregroundStyle(.secondary)
          Button("Try again") { Task { await workspace.refreshSessions() } }
        }
      }
    }
    ForEach(workspace.sections) { section in
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
    } else if workspace.sections.isEmpty, workspace.historyError == nil, workspace.isConnected {
      Section {
        VStack(alignment: .leading, spacing: 2) {
          Text("No conversations yet").font(.headline)
          Text("Start a conversation in this project.").foregroundStyle(.secondary)
        }
      }
    }
  }

  private var connectionFooter: some View {
    HStack(spacing: 6) {
      Circle().fill(dotColor).frame(width: 7, height: 7)
      Text(statusText).font(.caption).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .help(workspace.status.version.map { "Muse Code \($0)" } ?? workspace.status.message ?? "")
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
        Image(systemName: "bubble.left").foregroundStyle(.secondary)
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
