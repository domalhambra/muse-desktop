import MuseBackend
import MuseKit
import SwiftUI

/// The detail column: the connection banner, the transcript and cards, and the composer.
struct ConversationView: View {
  let controller: AppController
  let workspace: Workspace
  @State private var renaming = false
  @State private var newName = ""

  var body: some View {
    VStack(spacing: 0) {
      if !workspace.isConnected, workspace.status.state != "connecting" {
        ConnectionBanner(controller: controller, workspace: workspace)
      }
      Group {
        if let view = workspace.view {
          TranscriptView(workspace: workspace, view: view).id(view.session.sessionId)
        } else if workspace.openingSessionId != nil {
          ProgressView("Loading conversation…")
        } else {
          ContentUnavailableView(
            "Start a conversation", systemImage: "bubble.left.and.bubble.right",
            description: Text("Ask a question or describe what you want to build."))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      ComposerView(controller: controller, workspace: workspace)
    }
    .navigationTitle(workspace.view.map { SessionTitle.of($0.session) } ?? "New conversation")
    .navigationSubtitle(
      workspace.project.isEmpty ? "" : ProjectPath.name(of: ProjectPath.root(of: workspace.project)))
    .toolbar {
      if let session = workspace.view?.session {
        ToolbarItem {
          Menu {
            Button("Rename conversation…") {
              newName = session.name ?? SessionTitle.of(session)
              renaming = true
            }
          } label: {
            Label("Conversation actions", systemImage: "ellipsis.circle")
          }
        }
      }
    }
    .sheet(isPresented: $renaming) {
      RenameSheet(name: $newName, workspace: workspace) { renaming = false }
    }
  }
}

struct ConnectionBanner: View {
  let controller: AppController
  let workspace: Workspace

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
      // As Electron's `status.message || …`: an empty message counts as none.
      Text(workspace.status.message.flatMap { $0.isEmpty ? nil : $0 } ?? "Connect Muse Code to get started.")
        .lineLimit(3)
      Spacer()
      Button("Reconnect") { Task { await workspace.reconnect() } }
      MuseCodeSettingsButton { Text("Set up") }
      Button("Choose Muse Code…") {
        Task {
          guard let path = await AppController.chooseCLIPath() else { return }
          await workspace.setCLIPath(path)
        }
      }
      if !workspace.preferences.cliPath.isEmpty {
        Button("Use automatic detection") { Task { await workspace.setCLIPath("") } }
      }
    }
    .padding(10)
    .background(.yellow.opacity(0.12))
  }
}

struct RenameSheet: View {
  @Binding var name: String
  let workspace: Workspace
  let close: () -> Void
  @State private var error: String?
  @State private var saving = false

  /// The backend's limit, counted as it counts: in UTF-16 units.
  static let limit = 200

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename conversation").font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        // No onSubmit: Return reaches the Save button's default action, so it saves once.
        TextField("Conversation name", text: $name)
          .textFieldStyle(.roundedBorder)
          .onChange(of: name) {
            if name.utf16.count > Self.limit { name = name.prefix(utf16Units: Self.limit) }
            error = nil
          }
        if let error {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }
      HStack {
        Spacer()
        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        Button("Save", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func save() {
    guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    saving = true
    error = nil
    Task {
      if await workspace.rename(name) {
        close()
        return
      }
      // Shown here, under the field. Cleared on the Workspace, so the window's alert does not
      // show it a second time behind the sheet.
      error = workspace.errorMessage ?? "Muse could not rename this conversation."
      workspace.errorMessage = nil
      saving = false
    }
  }
}
