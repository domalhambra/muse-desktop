import MuseBackend
import MuseKit
import SwiftUI

struct SidebarView: View {
  let controller: AppController
  @Bindable var workspace: Workspace
  @Environment(\.appearance) private var appearance
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
            Text(projectLabel(path)).lineLimit(1).truncationMode(.middle).tag(path)
          }
          Divider()
          Text("Open another project…").tag(Self.openAnother)
        }
        // The label is for VoiceOver only, as in Electron, so project names fit at 240 points.
        .labelsHidden()
        // A long name loses its middle, so the folder's end stays visible; the tooltip has it all.
        .lineLimit(1)
        .truncationMode(.middle)
        .help(workspace.project.isEmpty ? "All projects" : workspace.project)
        // The stock bezel: the theme's light accent under a white label is unreadable.
        .tint(nil)
        .id(pickerGeneration)
        // The folder's own status: a worktree shows its branch once read, never its parent's.
        if let git = workspace.projectBadge, git.isRepository {
          HStack(spacing: 6) {
            Label(git.branch, systemImage: "arrow.triangle.branch")
              .lineLimit(1)
              .accessibilityLabel("Branch \(git.branch)")
            GitBadgeView(status: git)
          }
          .font(.caption)
          .foregroundStyle(.themeSecondary)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("project-git-badge")
        }
        if !workspace.project.isEmpty {
          Button {
            controller.sheets.proposedChanges = true
          } label: {
            Label("Proposed changes", systemImage: "rectangle.stack.badge.person.crop").lineLimit(1)
          }
          .buttonStyle(.plain)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
          .help("The project\u{2019}s pull requests, as change cards")
          .accessibilityIdentifier("proposed-changes")
        }
      }
      history
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(appearance.colors.sidebar)
    .onKeyPress(.return) {
      guard let sessionId = highlighted else { return .ignored }
      highlighted = nil
      Task { await workspace.open(sessionId) }
      return .handled
    }
    .onChange(of: workspace.view?.session.sessionId) { highlighted = nil }
    .onChange(of: workspace.project) { highlighted = nil }
    .onChange(of: workspace.showArchived) { highlighted = nil }
    // `sections` groups by `.now` each time the list draws, so this moves yesterday's rows.
    .onReceive(
      NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)
    ) { _ in redraw += 1 }
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
        if Self.isKeyEvent(NSApp.currentEvent) {
          highlighted = sessionId
          return
        }
        highlighted = nil
        Task { await workspace.open(sessionId) }
      })
  }

  /// A key press that is still being handled. `currentEvent` keeps the last event after it is
  /// handled, so an older key press must not turn a later change into a highlight.
  private static func isKeyEvent(_ event: NSEvent?) -> Bool {
    guard let event, event.type == .keyDown else { return false }
    return ProcessInfo.processInfo.systemUptime - event.timestamp < 1.0
  }

  @ViewBuilder private var history: some View {
    // Read once: each read groups and sorts every session.
    let sections = workspace.sections
    scheduled
    Section {
      conversationsHeader
      if let error = workspace.historyError {
        VStack(alignment: .leading, spacing: 6) {
          Text("Could not load your conversation history.").font(.headline)
          Text(error).foregroundStyle(.themeSecondary)
          Button("Try again") { Task { await workspace.refreshSessions() } }
        }
      }
    }
    ForEach(sections) { section in
      Section(section.title) {
        ForEach(section.sessions) { session in
          SessionRow(
            session: session, showProject: workspace.project.isEmpty,
            pinned: workspace.isPinned(session.sessionId),
            // A click on the row the arrow keys moved to: the selection does not change, so the
            // binding is not set. An ordinary click clears `highlighted` on mouse-down first, so
            // it does not open twice.
            open: {
              guard highlighted == session.sessionId else { return }
              highlighted = nil
              Task { await workspace.open(session.sessionId) }
            }
          ) {
            Task { await workspace.togglePin(session.sessionId) }
          }
          .tag(session.sessionId)
          .contentShape(.rect)
          .contextMenu { rowMenu(session) }
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
          Text(workspace.showArchived ? "No archived conversations" : "No conversations yet").font(.headline)
          Text(workspace.showArchived ? "Archived conversations appear here." : "Start a conversation in this project.")
            .foregroundStyle(.themeSecondary)
        }
      }
    }
  }

  /// The active scheduled tasks, each with its next run. A click opens the latest run that started
  /// a conversation. Rows have no tag, so the list never selects them.
  @ViewBuilder private var scheduled: some View {
    let active = workspace.schedules.filter(\.schedule.enabled)
    if !active.isEmpty {
      Section("Scheduled") {
        ForEach(active) { entry in
          let sessionId = entry.history.first(where: { $0.sessionId != nil })?.sessionId
          Button {
            if let sessionId { Task { await workspace.open(sessionId) } }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.schedule.name).lineLimit(1).truncationMode(.tail)
              Text(ScheduleRules.nextRun(entry, now: .now))
                .font(.caption)
                .foregroundStyle(.themeSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .disabled(sessionId == nil)
          .help(entry.schedule.name)
          .accessibilityElement(children: .combine)
          .accessibilityHint(sessionId == nil ? "No run yet" : "Opens the latest run")
          .accessibilityIdentifier("scheduled-row-\(entry.schedule.id)")
        }
      }
    }
  }

  /// CONVERSATIONS, or ARCHIVED, with the Archive toggle beside it, as Electron's section header.
  /// A row without a tag, so the list never selects it.
  private var conversationsHeader: some View {
    let label = workspace.showArchived ? "Show conversations" : "Show archived conversations"
    return HStack {
      Text(workspace.showArchived ? "ARCHIVED" : "CONVERSATIONS")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.themeSecondary)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Button {
        workspace.showArchived.toggle()
      } label: {
        Image(systemName: workspace.showArchived ? "archivebox.fill" : "archivebox")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(workspace.showArchived ? appearance.colors.accent : appearance.colors.secondary)
      .accessibilityLabel(label)
      .accessibilityAddTraits(workspace.showArchived ? .isSelected : [])
      .accessibilityIdentifier("archive-toggle")
      .help(label)
    }
  }

  /// A row's context menu. Archive's label follows the row's own state.
  @ViewBuilder private func rowMenu(_ session: Session) -> some View {
    let id = session.sessionId
    Button(workspace.isPinned(id) ? "Unpin conversation" : "Pin conversation") {
      Task { await workspace.togglePin(id) }
    }
    .accessibilityIdentifier("row-pin")
    Button(workspace.isArchived(id) ? "Restore conversation" : "Archive in Desktop") {
      Task { await workspace.toggleArchive(id) }
    }
    .accessibilityIdentifier("row-archive")
    Divider()
    Button("Rename conversation…") {
      Task { if await workspace.ensureOpen(id), let open = workspace.view?.session { controller.sheets.rename(open) } }
    }
    .accessibilityIdentifier("row-rename")
    Button("Export as Markdown…") {
      Task { if await workspace.ensureOpen(id) { await ExportPanel.run(workspace) } }
    }
    .accessibilityIdentifier("row-export")
  }

  /// On the sidebar's solid color, so rows do not show through it as the list scrolls. A click opens
  /// Settings on the Muse Code pane, as Electron's status pill does.
  private var connectionFooter: some View {
    VStack(spacing: 0) {
      Divider()
      if let limits = workspace.limits { UsageFooter(limits: limits) }
      MuseCodeSettingsButton {
        HStack(spacing: 6) {
          Circle().fill(dotColor).frame(width: 7, height: 7)
          Text(statusText).font(.caption).foregroundStyle(.themeSecondary)
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Muse Code settings")
      .accessibilityValue(statusText)
      .help(workspace.status.version.map { "Muse Code \($0)" } ?? workspace.status.message ?? "")
    }
    .background(appearance.colors.sidebarSolid)
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
    case "connecting": appearance.colors.accent
    default: .orange
    }
  }
}

/// One conversation in the history, as Electron's sidebar row.
struct SessionRow: View {
  let session: Session
  let showProject: Bool
  var pinned = false
  /// A click on the row outside the pin button.
  var open: () -> Void = {}
  /// The hover button's action.
  var togglePin: () -> Void = {}
  /// While the pointer is over the row, the pin button replaces the time, as in Electron.
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      // Everything but the pin button takes the row's click, so pinning never opens the row.
      HStack(spacing: 8) { content }
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded(open))
      if hovering {
        Button(action: togglePin) {
          Image(systemName: pinned ? "pin.slash" : "pin")
        }
        .buttonStyle(.borderless)
        .help(pinned ? "Unpin conversation" : "Pin conversation")
        .accessibilityLabel("\(pinned ? "Unpin" : "Pin") \(SessionTitle.of(session))")
        .accessibilityIdentifier("pin-button")
      }
    }
    .onHover { hovering = $0 }
    .help(SessionTitle.of(session))
    // VoiceOver reaches the pin without hovering.
    .accessibilityAction(named: pinned ? "Unpin conversation" : "Pin conversation", togglePin)
  }

  /// The icon, the title, the project, the worktree badge, and the time unless the pin button
  /// replaces it.
  @ViewBuilder private var content: some View {
    // As Electron: a pinned row shows its pin, even while it runs.
    if pinned {
      Image(systemName: "pin.fill").font(.caption).foregroundStyle(.themeSecondary).accessibilityLabel("Pinned")
    } else if session.status == "running" {
      ProgressView().controlSize(.mini).accessibilityLabel("Working")
    } else {
      Image(systemName: "bubble.left").foregroundStyle(.themeSecondary).accessibilityHidden(true)
    }
    VStack(alignment: .leading, spacing: 2) {
      Text(SessionTitle.of(session)).lineLimit(1)
      // Electron names the session's own folder, so a worktree shows its worktree's name.
      if showProject, let root = session.workspaceRoot, !root.isEmpty {
        Text(ProjectPath.name(of: root))
          .font(.caption)
          .foregroundStyle(.themeSecondary)
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
    if !hovering {
      TimelineView(.everyMinute) { context in
        Text(RelativeTime.text(SidebarSections.activity(session), now: context.date))
          .font(.caption)
          .foregroundStyle(.themeSecondary)
          .monospacedDigit()
      }
    }
  }
}
