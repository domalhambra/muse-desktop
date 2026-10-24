import MuseBackend
import MuseKit
import SwiftUI

struct RootView: View {
  let controller: AppController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.appearance) private var appearance

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
    .background(ThemeBackground(palette: appearance.palette))
    .background { if !MMacApp.keepsWindowState { WindowStateGuard() } }
    // The controller reopens this window for an Ask or a Dock click after it was closed.
    .onAppear { controller.showWindow = { [openWindow] in openWindow(id: MMacApp.mainWindow) } }
  }
}

struct MainView: View {
  let controller: AppController
  @Bindable var workspace: Workspace
  /// Remembered between launches. Electron starts with its inspector closed each time.
  @AppStorage("inspectorShown") private var inspectorShown = false
  @Environment(\.openSettings) private var openSettings
  // The store is named here, as the sidebar and banner name it, so all of them share one value.
  @AppStorage(SettingsView.paneKey, store: MMacApp.appStorage) private var settingsPane: SettingsView.Pane = .appearance

  var body: some View {
    @Bindable var sheets = controller.sheets
    NavigationSplitView {
      SidebarView(controller: controller, workspace: workspace)
        .navigationSplitViewColumnWidth(
          min: WindowMetrics.sidebarMin, ideal: WindowMetrics.sidebarIdeal, max: WindowMetrics.sidebarMax)
    } detail: {
      ConversationView(controller: controller, workspace: workspace)
        // Before the inspector, so the floor is the conversation's own and not the inspector's too.
        .frame(minWidth: WindowMetrics.contentMin)
        .inspector(isPresented: $inspectorShown) {
          InspectorView(controller: controller, workspace: workspace, inspector: workspace.inspector)
            .inspectorColumnWidth(
              min: WindowMetrics.inspectorMin, ideal: WindowMetrics.inspectorIdeal, max: WindowMetrics.inspectorMax)
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button {
              inspectorShown.toggle()
            } label: {
              Label("Toggle project inspector", systemImage: "sidebar.trailing")
            }
            .accessibilityValue(inspectorShown ? "Shown" : "Hidden")
            .help(inspectorShown ? "Hide the project inspector (⌥⌘I)" : "Show the project inspector (⌥⌘I)")
          }
        }
    }
    .themedToolbar()
    // The split views exist only from here on.
    .background { if !MMacApp.keepsWindowState { WindowStateGuard() } }
    // Success notices, at the top of the window. Errors keep the alert below.
    .overlay(alignment: .top) {
      ToastView(workspace: workspace).padding(.top, 10)
    }
    .sheet(isPresented: $sheets.commandMenu, onDismiss: runChosen) {
      CommandMenuView(controller: controller, workspace: workspace)
    }
    // Here rather than on the composer, so a composer that goes away cannot leave `help` set.
    .sheet(isPresented: $sheets.help) {
      HelpSheet { controller.sheets.help = false }
    }
    .sheet(isPresented: $sheets.proposedChanges) {
      ProposedChangesSheet(workspace: workspace) { controller.sheets.proposedChanges = false }
    }
    .modifier(VoiceCancellation(voice: controller.voice))
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

  /// Runs the ⌘K result once its sheet has closed, as Electron closes the menu first.
  private func runChosen() {
    guard let action = controller.sheets.chosen else { return }
    controller.sheets.chosen = nil
    switch action {
    case .newConversation:
      workspace.startNew()
    case .openProject:
      Task { await controller.openProject() }
    case .openSettings:
      settingsPane = .appearance
      openSettings()
    case .open(let id):
      // `open` follows the conversation's folder, as Electron's `openSession` does.
      Task { await workspace.open(id) }
    case .theme(let theme):
      Task { await workspace.save(PreferencesPatch(theme: theme)) }
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
        Text(message).foregroundStyle(.themeSecondary)
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
