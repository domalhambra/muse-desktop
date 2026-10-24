import AppKit
import MuseBackend
import MuseKit
import SwiftUI

/// The project inspector, as Electron's `Inspector.tsx`: the project and its branch, the Changes,
/// Files and Activity tabs, and the conversation's token usage.
struct InspectorView: View {
  let controller: AppController
  let workspace: Workspace
  @Bindable var inspector: Inspector
  @Environment(\.appearance) private var appearance
  /// The tab bar's width, for choosing between titled and icon-only segments.
  @State private var tabBarWidth: CGFloat = 0

  var body: some View {
    // Built once per render, for the tab's count and the list, so the list compares entries
    // rather than re-reading transcript items whose message text alone changed.
    let entries = ActivityEntry.build(workspace.view?.items ?? [])
    VStack(spacing: 0) {
      header
      Divider()
      tabs(activityCount: entries.count, todosCount: TodoRow.build(workspace.view?.todos).count)
      Divider()
      Group {
        switch inspector.tab {
        case .changes: ChangesView(workspace: workspace, inspector: inspector)
        case .files: FilesView(controller: controller, workspace: workspace, inspector: inspector)
        case .activity: ActivityView(entries: entries)
        case .tasks: TasksView(rows: TodoRow.build(workspace.view?.todos))
        case .agents: AgentsView(rows: AgentRow.build(workspace.view?.items ?? []), controller: controller, workspace: workspace)
        case .preview: PreviewView(project: workspace.project)
        }
      }
      // A tab's content never sets the column's width: minWidth 0 keeps a wide list or split view
      // from widening the inspector past its column and both window edges, and anything wider is
      // cut at the column's edge.
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
      if let usage = workspace.view?.usage {
        Divider()
        UsagePanel(usage: usage)
      }
      Divider()
      footer
    }
    // As Electron: read again when the project changes and when the open conversation's status
    // does, so a turn that ends shows what it changed.
    // The Changes, Files and Activity lists draw on the column's color.
    .scrollContentBackground(.hidden)
    // The column's own width, whatever its views would like: see `WindowLayout`.
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .background(appearance.colors.dialog)
    .task(id: RefreshKey(project: workspace.project, status: workspace.view?.session.status)) {
      await inspector.refresh()
    }
    // This view stays built, and the task above live, while the inspector is collapsed, so the
    // Workspace leaves a turn end's badge read to it. Set together: the flag promises the task.
    .onAppear { inspector.refreshesOnStatusChange = true }
    .onDisappear { inspector.refreshesOnStatusChange = false }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Project inspector")
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder").font(.title3).foregroundStyle(.themeSecondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(workspace.project.isEmpty ? "No project selected" : ProjectPath.name(of: workspace.project))
          .font(.headline)
          .lineLimit(1)
        if let git = inspector.git, git.isRepository {
          HStack(spacing: 6) {
            Label(git.branch, systemImage: "arrow.triangle.branch")
              .accessibilityLabel("Branch \(git.branch)")
            GitBadgeView(status: git)
          }
          .font(.caption)
          .foregroundStyle(.themeSecondary)
        } else {
          Text("Local project").font(.caption).foregroundStyle(.themeSecondary)
        }
        if let context = workspace.view?.context {
          Text(ContextGauge.label(context))
            .font(.caption)
            .foregroundStyle(gaugeColor(ContextGauge.tint(context)))
            .accessibilityIdentifier("context-gauge")
            .help("How full this conversation\u{2019}s context window is. Muse compacts it when it fills.")
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .help(workspace.project)
  }

  private func tabs(activityCount: Int, todosCount: Int) -> some View {
    let titles = InspectorTab.all.map { tab in
      switch tab.tab {
      case .changes: ChangeLabel.counted("Changes", inspector.git?.changes.count ?? 0)
      case .activity: ChangeLabel.counted("Activity", activityCount)
      case .tasks: ChangeLabel.counted("Tasks", todosCount)
      case .agents: ChangeLabel.counted("Agents", AgentRow.build(workspace.view?.items ?? []).count)
      case .files, .preview: tab.title
      }
    }
    return HStack(spacing: 8) {
      Group {
        // Titled segments when all six fit the bar; at the column's narrower widths, icons, whose
        // names (with the counts) VoiceOver and the tooltip still read.
        if tabBarWidth == 0 || tabBarWidth >= InspectorTab.titledWidth(titles) {
          Picker("Inspector view", selection: $inspector.tab) {
            ForEach(Array(InspectorTab.all.enumerated()), id: \.offset) { index, tab in
              Text(titles[index]).tag(tab.tab)
            }
          }
          .frame(minWidth: 0, maxWidth: .infinity)
        } else {
          Picker("Inspector view", selection: $inspector.tab) {
            ForEach(Array(InspectorTab.all.enumerated()), id: \.offset) { index, tab in
              // Each icon names its own tab, with the count, for VoiceOver, the UI tests and its
              // tooltip; the image's description says the same.
              Image(nsImage: InspectorTab.icon(tab.symbol, named: titles[index]))
                .accessibilityLabel(titles[index])
                .help(titles[index])
                .tag(tab.tab)
            }
          }
          .frame(minWidth: 0, maxWidth: .infinity)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .tint(nil)
      // The room the picker has, measured on the frame, which minWidth 0 keeps at the bar's width
      // even while the segments inside want more.
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabBarWidth = $0 }
      Button {
        Task { await inspector.refresh() }
      } label: {
        // As Electron's spinning icon: a spinner while the status loads.
        if inspector.loading {
          ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
          Label("Refresh changes", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            .frame(width: 16, height: 16)
        }
      }
      .buttonStyle(.borderless)
      .disabled(inspector.loading || workspace.project.isEmpty)
      .help("Refresh changes")
      .accessibilityLabel("Refresh changes")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inspector-tabs")
  }

  /// Electron's footer: the project in Finder, in Terminal, or in the full Muse Code CLI. Off with
  /// no project.
  private var footer: some View {
    HStack {
      Button {
        revealInFinder()
      } label: {
        Label("Finder", systemImage: "folder")
      }
      .help("Open the project in Finder")
      .accessibilityIdentifier("inspector-finder")
      Spacer()
      Button {
        Task { await workspace.openProjectInTerminal() }
      } label: {
        Label("Terminal", systemImage: "terminal")
      }
      .help("Open Terminal in the project folder")
      .accessibilityIdentifier("inspector-terminal")
      Spacer()
      Button("Muse Code") {
        Task { await workspace.openProjectInMuseCode() }
      }
      .help("Open the full Muse Code CLI in Terminal, in the project folder")
      .accessibilityIdentifier("inspector-muse-code")
    }
    .buttonStyle(.borderless)
    .labelStyle(.titleAndIcon)
    // One line each, so the three fit the column at its minimum width.
    .lineLimit(1)
    .font(.callout)
    .foregroundStyle(.themeMuted)
    .disabled(workspace.project.isEmpty)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  /// As Electron's `reveal-project`: opens the folder itself in Finder.
  private func revealInFinder() {
    workspace.revealProject { NSWorkspace.shared.open($0) }
  }

  private func gaugeColor(_ tint: ContextGauge.Tint) -> Color {
    switch tint {
    case .normal: appearance.colors.secondary
    case .warning: .orange
    case .blocked: .red
    }
  }

  /// What makes the inspector read the project again.
  struct RefreshKey: Equatable {
    let project: String
    let status: String?
  }
}

/// The inspector's six tabs, in order, with the icon each shows when the bar is narrow.
struct InspectorTab {
  let tab: Inspector.Tab
  let title: String
  let symbol: String

  static let all = [
    InspectorTab(tab: .changes, title: "Changes", symbol: "plusminus"),
    InspectorTab(tab: .files, title: "Files", symbol: "folder"),
    InspectorTab(tab: .activity, title: "Activity", symbol: "terminal"),
    InspectorTab(tab: .tasks, title: "Tasks", symbol: "checklist"),
    InspectorTab(tab: .agents, title: "Agents", symbol: "person.2"),
    InspectorTab(tab: .preview, title: "Preview", symbol: "globe"),
  ]

  /// Room around each title in a segment: an estimate on the generous side, so titles show only
  /// when they fit uncut.
  static let segmentPadding: CGFloat = 24

  /// The width six titled segments need at the control's font.
  @MainActor static func titledWidth(_ titles: [String]) -> CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    return titles.reduce(0) { total, title in
      total + ceil((title as NSString).size(withAttributes: [.font: font]).width) + segmentPadding
    }
  }

  /// A segment's icon, described by its name.
  @MainActor static func icon(_ symbol: String, named name: String) -> NSImage {
    NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage()
  }
}

/// "3 changed" or "Clean", as Electron's project-card pill.
struct GitBadgeView: View {
  let status: GitStatus

  var body: some View {
    Text(GitBadge.changes(status))
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .foregroundStyle(.primary)
      .background((status.changes.isEmpty ? Color.green : Color.orange).opacity(0.15), in: Capsule())
  }
}

/// The Activity tab: tools, file edits, reminders and hooks, as Electron lists them.
struct ActivityView: View {
  let entries: [ActivityEntry]

  var body: some View {
    if entries.isEmpty {
      ContentUnavailableView(
        "No activity yet", systemImage: "terminal",
        description: Text("Tool calls, file edits, and agent activity appear here.").foregroundStyle(.themeSecondary))
    } else {
      List(entries) { entry in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          ActivityStatusIcon(status: entry.status)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).bold().lineLimit(1)
            Text(entry.detail).font(.caption).foregroundStyle(.themeSecondary).lineLimit(2)
          }
        }
        .accessibilityElement(children: .combine)
      }
      .listStyle(.inset)
    }
  }
}

/// The Tasks tab: the agent's todo list, replaced whole on every change.
struct TasksView: View {
  let rows: [TodoRow]

  var body: some View {
    if rows.isEmpty {
      ContentUnavailableView(
        "No tasks yet", systemImage: "checklist",
        description: Text("Muse\u{2019}s task list appears here when it makes one.").foregroundStyle(.themeSecondary))
    } else {
      List(rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          TodoStatusIcon(status: row.status)
          Text(row.title).strikethrough(row.status == "completed" || row.status == "cancelled")
        }
        .accessibilityElement(children: .combine)
      }
      .listStyle(.inset)
      .accessibilityIdentifier("tasks-list")
    }
  }
}

struct TodoStatusIcon: View {
  let status: String

  var body: some View {
    switch status {
    case "inProgress": ProgressView().controlSize(.mini).accessibilityLabel("In progress")
    case "completed": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Completed")
    case "cancelled": Image(systemName: "xmark.circle").foregroundStyle(.themeSecondary).accessibilityLabel("Cancelled")
    default: Image(systemName: "circle").foregroundStyle(.themeSecondary).accessibilityLabel("Pending")
    }
  }
}

/// The Agents tab: the subagents this conversation ran. A row opens its session read-only.
struct AgentsView: View {
  let rows: [AgentRow]
  let controller: AppController
  let workspace: Workspace

  var body: some View {
    if rows.isEmpty {
      ContentUnavailableView(
        "No subagents yet", systemImage: "person.2",
        description: Text("Subagents Muse starts in this conversation appear here.").foregroundStyle(.themeSecondary))
    } else {
      List(rows) { row in
        Button {
          guard let child = row.childSessionId else { return }
          Task {
            await workspace.openChild(child)
            controller.sheets.child = true
          }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            AgentPhaseIcon(phase: row.phase, status: row.status)
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title).bold().lineLimit(1)
              Text(row.detail.isEmpty ? row.status : "\(row.status) · \(row.detail)")
                .font(.caption).foregroundStyle(.themeSecondary).lineLimit(1)
            }
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(row.childSessionId == nil)
        .accessibilityElement(children: .combine)
      }
      .listStyle(.inset)
      .accessibilityIdentifier("agents-list")
    }
  }
}

struct AgentPhaseIcon: View {
  let phase: AgentRow.Phase
  let status: String

  var body: some View {
    switch phase {
    case .running: ProgressView().controlSize(.mini).accessibilityLabel("Running")
    case .done: Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Completed")
    case .other: Image(systemName: "xmark").foregroundStyle(.red).accessibilityLabel(StatusIcon.spoken(status))
    }
  }
}

/// Electron's three activity icons: a spinner, a check, and a cross for anything else.
struct ActivityStatusIcon: View {
  let status: String

  var body: some View {
    switch status {
    case "inProgress": ProgressView().controlSize(.mini).accessibilityLabel("Running")
    case "completed": Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Completed")
    default: Image(systemName: "xmark").foregroundStyle(.red).accessibilityLabel(StatusIcon.spoken(status))
    }
  }
}

/// The conversation's token counts, as Electron's "SESSION USAGE" panel.
struct UsagePanel: View {
  let usage: Usage

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("SESSION USAGE").font(.caption2.bold()).foregroundStyle(.themeSecondary)
        .accessibilityAddTraits(.isHeader)
      row("Input", usage.input)
      row("Output", usage.output)
      row("Total tokens", usage.total)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ title: String, _ value: Int) -> some View {
    HStack {
      Text(title).foregroundStyle(.themeSecondary)
      Spacer()
      Text(value.formatted()).monospacedDigit()
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
  }
}
