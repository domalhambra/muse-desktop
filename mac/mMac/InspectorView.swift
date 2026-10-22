import MuseBackend
import MuseKit
import SwiftUI

/// The project inspector, as Electron's `Inspector.tsx`: the project and its branch, the Changes,
/// Files and Activity tabs, and the conversation's token usage.
struct InspectorView: View {
  let controller: AppController
  let workspace: Workspace
  @Bindable var inspector: Inspector

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      tabs
      Divider()
      Group {
        switch inspector.tab {
        case .changes: Text("Changes").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .files: Text("Files").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .activity: ActivityView(items: workspace.view?.items ?? [])
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      if let usage = workspace.view?.usage {
        Divider()
        UsagePanel(usage: usage)
      }
    }
    // As Electron: read again when the project changes and when the open conversation's status
    // does, so a turn that ends shows what it changed.
    .task(id: RefreshKey(project: workspace.project, status: workspace.view?.session.status)) {
      await inspector.refresh()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Project inspector")
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(workspace.project.isEmpty ? "No project selected" : ProjectPath.name(of: workspace.project))
          .font(.headline)
          .lineLimit(1)
        if let git = inspector.git, git.isRepository {
          HStack(spacing: 6) {
            Label(git.branch, systemImage: "arrow.triangle.branch")
            GitBadgeView(status: git)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text("Local project").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .help(workspace.project)
  }

  private var tabs: some View {
    HStack(spacing: 8) {
      Picker("Inspector view", selection: $inspector.tab) {
        Text(Self.counted("Changes", inspector.git?.changes.count ?? 0)).tag(Inspector.Tab.changes)
        Text("Files").tag(Inspector.Tab.files)
        Text(Self.counted("Activity", ActivityEntry.build(workspace.view?.items ?? []).count))
          .tag(Inspector.Tab.activity)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Button("Refresh changes", systemImage: "arrow.clockwise") { Task { await inspector.refresh() } }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(inspector.loading || workspace.project.isEmpty)
        .help("Refresh changes")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// "Changes 3", or "Changes" at zero, as Electron's tab badges.
  static func counted(_ title: String, _ count: Int) -> String { count > 0 ? "\(title) \(count)" : title }
}

/// What makes the inspector read the project again.
struct RefreshKey: Equatable {
  let project: String
  let status: String?
}

/// "3 changed" or "Clean", as Electron's project-card pill.
struct GitBadgeView: View {
  let status: GitStatus

  var body: some View {
    Text(GitBadge.changes(status))
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .foregroundStyle(status.changes.isEmpty ? .green : .orange)
      .background((status.changes.isEmpty ? Color.green : Color.orange).opacity(0.15), in: Capsule())
  }
}

/// The Activity tab: tools, file edits, reminders and hooks, as Electron lists them.
struct ActivityView: View {
  let items: [TranscriptItem]

  var body: some View {
    let entries = ActivityEntry.build(items)
    if entries.isEmpty {
      ContentUnavailableView(
        "No activity yet", systemImage: "terminal",
        description: Text("Tool calls, file edits, and agent activity appear here."))
    } else {
      List(entries) { entry in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          ActivityStatusIcon(status: entry.status)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).bold().lineLimit(1)
            Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
      }
      .listStyle(.inset)
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
      Text("SESSION USAGE").font(.caption2.bold()).foregroundStyle(.secondary)
      row("Input", usage.input)
      row("Output", usage.output)
      row("Total tokens", usage.total)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ title: String, _ value: Int) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value.formatted()).monospacedDigit()
    }
    .font(.caption)
  }
}
