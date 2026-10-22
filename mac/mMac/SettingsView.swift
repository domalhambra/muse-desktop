import MuseKit
import SwiftUI

/// The Settings window: Electron's Settings dialog as four macOS panes. About is macOS's own panel.
struct SettingsView: View {
  enum Pane: String, CaseIterable, Identifiable {
    case appearance, museCode, mcp, bridges
    var id: String { rawValue }
    var title: String {
      switch self {
      case .appearance: "Appearance"
      case .museCode: "Muse Code"
      case .mcp: "MCP servers"
      case .bridges: "Bridges"
      }
    }
    var symbol: String {
      switch self {
      case .appearance: "paintpalette"
      case .museCode: "terminal"
      case .mcp: "puzzlepiece.extension"
      case .bridges: "point.3.connected.trianglepath.dotted"
      }
    }
  }

  /// The `@AppStorage` key for the pane last shown. The sidebar status and the banner's "Set up"
  /// set it to open Settings on the Muse Code pane.
  static let paneKey = "settingsPane"

  let controller: AppController
  @Environment(\.appearance) private var appearance
  // The store is named here, as the sidebar and banner name it, so all three share one value.
  @AppStorage(Self.paneKey, store: MMacApp.appStorage) private var pane: Pane = .appearance

  var body: some View {
    TabView(selection: $pane) {
      ForEach(Pane.allCases) { pane in
        content(pane)
          .tabItem { Label(pane.title, systemImage: pane.symbol) }
          .tag(pane)
      }
    }
    .frame(width: 560)
    .frame(minHeight: 360)
    // Electron's Settings dialog sits on `--dialog`.
    .scrollContentBackground(.hidden)
    .background(appearance.colors.dialog)
    .alert(
      "Muse",
      isPresented: Binding(
        get: { controller.settings?.errorMessage != nil },
        set: { if !$0 { controller.settings?.errorMessage = nil } })
    ) {
      Button("OK") { controller.settings?.errorMessage = nil }
    } message: {
      Text(controller.settings?.errorMessage ?? "")
    }
  }

  @ViewBuilder private func content(_ pane: Pane) -> some View {
    if let settings = controller.settings {
      switch pane {
      case .appearance: AppearancePane(settings: settings, notifications: controller.notifications)
      case .museCode: MuseCodePane(settings: settings)
      case .mcp: McpPane(settings: settings)
      case .bridges: BridgesPane(settings: settings)
      }
    } else {
      ContentUnavailableView(
        "Settings are available while the Muse backend runs.", systemImage: "bolt.horizontal.circle")
    }
  }
}

/// A button that opens Settings on the Muse Code pane, as Electron's status pill and banner open
/// its connection tab.
struct MuseCodeSettingsButton<Label: View>: View {
  @ViewBuilder let label: () -> Label
  @AppStorage(SettingsView.paneKey, store: MMacApp.appStorage) private var pane: SettingsView.Pane = .appearance
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button {
      pane = .museCode
      openSettings()
    } label: {
      label()
    }
  }
}

// A placeholder until its pane is written. It is replaced by its own file.

struct BridgesPane: View {
  let settings: SettingsModel
  var body: some View { Text("Bridges") }
}
