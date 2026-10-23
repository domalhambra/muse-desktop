import AppKit
import MuseBackend
import MuseKit
import UniformTypeIdentifiers

/// "Export as Markdown": a save panel as a sheet on the window, then the backend writes the file.
@MainActor
enum ExportPanel {
  /// Exports the open conversation. Cancel does nothing; success shows the toast. When another
  /// conversation opened while the panel showed, nothing is exported.
  static func run(_ workspace: Workspace) async {
    guard let session = workspace.view?.session, let url = await chooseFile(for: session) else { return }
    _ = await workspace.exportConversation(to: url, sessionId: session.sessionId)
  }

  private static func chooseFile(for session: Session) async -> URL? {
    #if DEBUG
      // The UI tests cannot drive a save panel, so Debug builds take MMAC_TEST_EXPORT instead.
      if let path = ProcessInfo.processInfo.environment["MMAC_TEST_EXPORT"], !path.isEmpty {
        return URL(fileURLWithPath: path)
      }
    #endif
    let panel = NSSavePanel()
    // As Electron's dialog. macOS does not show a save panel's title.
    panel.title = "Export conversation"
    panel.nameFieldStringValue = ExportName.defaultFileName(for: session)
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.canCreateDirectories = true
    return await SheetAlert.run(panel)
  }
}
