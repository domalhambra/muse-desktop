import AppKit
import MuseKit
import SwiftUI

/// The right-click menu on a project path: attach it, open it in an editor, show it in Finder,
/// or copy a path. `path` is project-relative, as the backend writes it.
struct FilePathMenu: ViewModifier {
  let path: String
  let directory: Bool
  let workspace: Workspace

  func body(content: Content) -> some View {
    content.contextMenu {
      let url = FileMenuRules.absolute(path, in: workspace.project)
      if !directory {
        Button("Attach as context") { Task { await workspace.drop([url]) } }
        let editors = Self.editors(for: url)
        if !editors.isEmpty {
          Menu("Open in") {
            ForEach(editors) { app in
              Button(app.name) {
                NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
              }
            }
          }
        }
      }
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      Menu("Copy") {
        Button("Absolute path") { Self.copy(url.path) }
        Button("Relative path") { Self.copy(path) }
        Button("Filename") { Self.copy(FileMenuRules.fileName(path)) }
      }
    }
  }

  static func editors(for url: URL) -> [EditorApp] {
    let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { appURL -> EditorApp? in
      guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier else { return nil }
      let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
        ?? (bundle.infoDictionary?["CFBundleName"] as? String) ?? appURL.deletingPathExtension().lastPathComponent
      return EditorApp(name: name, bundleId: id, url: appURL)
    }
    return FileMenuRules.editors(apps)
  }

  static func copy(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
  }
}

extension View {
  func filePathMenu(_ path: String, directory: Bool = false, workspace: Workspace) -> some View {
    modifier(FilePathMenu(path: path, directory: directory, workspace: workspace))
  }
}
