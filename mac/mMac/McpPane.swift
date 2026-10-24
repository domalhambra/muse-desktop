import AppKit
import MuseBackend
import MuseKit
import SwiftUI

/// Electron's MCP servers tab. Every action goes through `SettingsModel`, so its errors show on
/// the Settings window. The Add server form is a sheet, which shows its own error.
struct McpPane: View {
  let settings: SettingsModel
  @State private var adding = false

  var body: some View {
    Form {
      Section {
        Text("Tools Muse Code can use. These live in Muse’s own settings file, so the CLI and mMac share them.")
          .foregroundStyle(.themeSecondary)
        if settings.needsReconnect {
          HStack {
            Text("Reconnect Muse Code to apply your changes.")
            Spacer()
            Button("Reconnect") { Task { await settings.reconnect() } }
          }
        }
      } header: {
        Text("MCP servers")
      }
      Section {
        // As Electron: the empty line hides while the form is open.
        if settings.servers.isEmpty && !adding {
          Text("No MCP servers are configured yet.").foregroundStyle(.themeSecondary)
        }
        ForEach(settings.servers) { server in McpRow(settings: settings, server: server) }
      }
      Section {
        HStack {
          // Electron shows it only once the list names a file.
          if !settings.settingsFile.isEmpty {
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.settingsFile)])
            } label: {
              Label("Show settings file", systemImage: "doc.text.magnifyingglass")
            }
          }
          Spacer()
          Button {
            adding = true
          } label: {
            Label("Add server", systemImage: "plus")
          }
          .buttonStyle(.primary)
          .accessibilityIdentifier("mcp-add-server")
        }
      }
    }
    .formStyle(.grouped)
    .task { await settings.loadServers() }
    .sheet(isPresented: $adding) { McpAddSheet(settings: settings) { adding = false } }
  }
}

private struct McpRow: View {
  let settings: SettingsModel
  let server: McpServer

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(server.name).font(.headline)
          Text(server.isRemote ? "Remote" : "Local")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.themeSecondary)
            .padding(.horizontal, 5)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
        }
        Text(server.detail)
          .font(.caption.monospaced())
          .foregroundStyle(.themeSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(server.detail)
        if !server.secretNames.isEmpty {
          // Names only, never values.
          Text("\(server.isRemote ? "Headers" : "Environment"): \(server.secretNames.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.themeSecondary)
        }
      }
      Spacer(minLength: 8)
      if server.isRemote {
        Button {
          Task { await settings.signIn(server.name) }
        } label: {
          Image(systemName: "key")
        }
        .buttonStyle(.borderless)
        .help("Sign in with OAuth (runs muse mcp login in Terminal)")
        .accessibilityLabel("Sign in to \(server.name)")
      }
      Button {
        Task { await remove() }
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove")
      .accessibilityLabel("Remove \(server.name)")
      Toggle(
        "Enable \(server.name)",
        isOn: Binding(
          get: { server.enabled },
          set: { on in Task { await settings.setEnabled(server.name, on) } })
      )
      .labelsHidden()
      .toggleStyle(.switch)
    }
  }

  /// Electron's `window.confirm`, as a sheet on the Settings window. Cancel is the default, so
  /// Return and Escape both keep the server.
  private func remove() async {
    let choice = await SheetAlert.present(
      title: "Remove the MCP server \(server.name)?", message: "", buttons: ["Remove", "Cancel"],
      preferringKey: true)
    if choice == 0 { await settings.remove(server.name) }
  }
}

/// The Add server form. A refused server keeps the form as typed and shows the error under it.
private struct McpAddSheet: View {
  let settings: SettingsModel
  let close: () -> Void
  @State private var form = McpForm()
  @State private var error: String?
  @State private var saving = false
  /// While a multi-line field has focus, Return makes a new line there, so Add server gives up
  /// the Return key. A key equivalent is matched before the field sees the key, so the field
  /// cannot keep Return for itself while the button holds it.
  @State private var editorFocused = false
  @Environment(\.appearance) private var appearance

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Server type", selection: $form.kind) {
        ForEach(McpForm.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      // The stock selected segment: the theme's light accent under a white label is unreadable.
      .tint(nil)
      field("Name") {
        PlainTextField(accessibilityLabel: "Name", text: $form.name, placeholder: "filesystem")
      }
      switch form.kind {
      case .local:
        field("Command") {
          PlainTextField(accessibilityLabel: "Command", text: $form.command, placeholder: "npx")
        }
        LinesField(label: "Arguments, one per line", text: $form.arguments, lines: 3, focused: $editorFocused)
        LinesField(
          label: "Environment, one KEY=value per line", text: $form.environment, lines: 2, focused: $editorFocused)
      case .remote:
        field("URL") {
          PlainTextField(accessibilityLabel: "URL", text: $form.url, placeholder: "https://example.com/mcp")
        }
        LinesField(label: "Headers, one Name: value per line", text: $form.headers, lines: 2, focused: $editorFocused)
        Text("Leave headers empty for servers that use OAuth, then use the key button to sign in.")
          .font(.caption)
          .foregroundStyle(.themeSecondary)
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(Color(hex: appearance.palette.red))
      }
      HStack {
        Spacer()
        // Disabled while saving, so a refusal always has the form to show in.
        Button("Cancel", action: close)
          .keyboardShortcut(.cancelAction)
          .disabled(saving)
        Button("Add server", action: add)
          .keyboardShortcut(editorFocused ? nil : .defaultAction)
          .buttonStyle(.primary)
          .disabled(saving)
          .accessibilityIdentifier("mcp-add-confirm")
      }
    }
    .padding(20)
    .frame(width: 460)
    .background(appearance.colors.dialog)
    .onChange(of: form) { error = nil }
  }

  /// A label above its field, as Electron's form lays them out.
  private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).accessibilityHidden(true)
      content()
    }
  }

  private func add() {
    guard !saving else { return }
    saving = true
    error = nil
    Task {
      guard let refusal = await settings.addServer(form) else {
        close()
        return
      }
      error = refusal
      saving = false
    }
  }
}

/// A multi-line field with a visible border and a label VoiceOver reads. It shows `lines` lines
/// and scrolls past them.
private struct LinesField: View {
  let label: String
  @Binding var text: String
  let lines: Int
  @Binding var focused: Bool
  @Environment(\.appearance) private var appearance

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).accessibilityHidden(true)
      PlainTextEditor(text: $text, accessibilityLabel: label) { focused = $0 }
        .frame(height: PlainTextEditor.height(lines: lines))
        .background(appearance.colors.input, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
    }
  }
}
