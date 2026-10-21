import MuseKit
import SwiftUI

struct RootView: View {
  let controller: AppController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Group {
      switch controller.phase {
      case .starting:
        ProgressView("Starting the Muse backend…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .setupFailed(let message, let details):
        ProblemView(title: "mMac could not start the Muse backend", message: message, details: details) {
          Button("Try again") { Task { await controller.start() } }
          Button("Choose checkout…") { Task { await controller.chooseRepository() } }
        }
      case .stopped(let message, let details):
        ProblemView(title: "The Muse backend stopped", message: message, details: details) {
          Button("Restart") { Task { await controller.start() } }
        }
      case .running:
        if let workspace = controller.workspace {
          MainView(controller: controller, workspace: workspace)
        }
      }
    }
    .sheet(item: Binding(get: { controller.asks.current }, set: { _ in })) { pending in
      AskSheet(ask: pending.ask) { controller.asks.answer($0, to: pending.id) }
    }
    // The controller reopens this window for an Ask or a Dock click after it was closed.
    .onAppear { controller.showWindow = { [openWindow] in openWindow(id: MMacApp.mainWindow) } }
  }
}

struct MainView: View {
  let controller: AppController
  @Bindable var workspace: Workspace

  var body: some View {
    NavigationSplitView {
      SidebarView(controller: controller, workspace: workspace)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
    } detail: {
      ConversationView(controller: controller, workspace: workspace)
    }
    .alert(
      "Muse",
      isPresented: Binding(
        get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })
    ) {
      Button("OK") { workspace.errorMessage = nil }
    } message: {
      Text(workspace.errorMessage ?? "")
    }
  }
}

/// A full-window problem with a message, the backend's last error lines and actions.
struct ProblemView<Actions: View>: View {
  let title: String
  let message: String
  let details: String
  let actions: Actions

  init(title: String, message: String, details: String, @ViewBuilder actions: () -> Actions) {
    self.title = title
    self.message = message
    self.details = details
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: 16) {
      ContentUnavailableView {
        Label(title, systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        actions
      }
      if !details.isEmpty {
        DisclosureGroup("Details") {
          ScrollView {
            Text(details)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 180)
        }
        .frame(maxWidth: 560)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
