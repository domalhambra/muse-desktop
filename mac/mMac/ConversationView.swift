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
      RenameSheet(name: $newName) { name in
        Task { if await workspace.rename(name) { renaming = false } }
      } cancel: {
        renaming = false
      }
    }
  }
}

struct ConnectionBanner: View {
  let controller: AppController
  let workspace: Workspace

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
      Text(workspace.status.message ?? "Connect Muse Code to get started.").lineLimit(3)
      Spacer()
      Button("Reconnect") { Task { await workspace.reconnect() } }
      Button("Choose Muse Code…") { Task { await controller.chooseCLI() } }
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
  let save: (String) -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename conversation").font(.headline)
      TextField("Conversation name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit { save(name) }
        .onChange(of: name) {
          if name.count > 200 { name = String(name.prefix(200)) }
        }
      HStack {
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button("Save") { save(name) }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}
