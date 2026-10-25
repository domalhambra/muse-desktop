import MuseBackend
import MuseKit
import SwiftUI

/// The Files tab, as Electron's Files page: breadcrumbs, a filter, the folder's entries, and a
/// preview of the chosen file.
struct FilesView: View {
  let controller: AppController
  let workspace: Workspace
  @Bindable var inspector: Inspector
  @Environment(\.appearance) private var appearance

  var body: some View {
    if workspace.project.isEmpty {
      ContentUnavailableView {
        Label("Files", systemImage: "folder")
      } description: {
        Text("Choose a project to explore its files and bring context into a conversation.")
          .foregroundStyle(.themeSecondary)
      } actions: {
        Button("Open project") { Task { await controller.openProject() } }
      }
    } else {
      VSplitView {
        browser.frame(minHeight: 160)
        preview.frame(minHeight: 120)
      }
      // The split view takes the inspector's width and never asks for more.
      .frame(minWidth: 0, maxWidth: .infinity)
      // A returning tab lists its folder again, so a read cut short when it went away runs again.
      .task(id: workspace.project) { await inspector.open(directory: inspector.directory) }
    }
  }

  private var browser: some View {
    VStack(alignment: .leading, spacing: 6) {
      breadcrumbs
      HStack(spacing: 4) {
        TextField("Find in this folder…", text: $inspector.query)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Filter files")
        if !inspector.query.isEmpty {
          Button("Clear filter", systemImage: "xmark.circle.fill") { inspector.query = "" }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.themeSecondary)
            .help("Clear filter")
        }
      }
      List {
        if !inspector.directory.isEmpty {
          Button {
            Task { await inspector.openParent() }
          } label: {
            Label("Parent folder", systemImage: "arrow.left")
          }
          .buttonStyle(.plain)
        }
        if let error = inspector.filesError {
          Text(error).foregroundStyle(.red)
        }
        if inspector.filesLoading {
          Text("Opening folder…").foregroundStyle(.themeSecondary)
        } else {
          ForEach(inspector.visibleFiles) { file in
            let selected = inspector.previewPath == file.path
            Button {
              Task { await inspector.choose(file) }
            } label: {
              FileRow(file: file)
            }
            .buttonStyle(.plain)
            .help(file.path)
            // As Electron's `aria-label={file.name}`; the hidden chevron's meaning goes in the hint.
            .accessibilityLabel(file.name)
            .accessibilityHint(file.directory ? "Opens this folder" : "Shows this file's preview")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .listRowBackground(selected ? appearance.colors.accent.opacity(0.15) : nil)
            .filePathMenu(file.path, directory: file.directory, workspace: workspace)
          }
          if inspector.filesError == nil, inspector.visibleFiles.isEmpty {
            Text(inspector.query.isEmpty ? "This folder is empty." : "No matching files.")
              .foregroundStyle(.themeSecondary)
          }
        }
      }
      .listStyle(.inset)
      Text("\(inspector.files.count) entries · build dependencies hidden")
        .font(.caption)
        .foregroundStyle(.themeSecondary)
    }
    .padding(8)
  }

  private var breadcrumbs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        Button {
          Task { await inspector.open(directory: "") }
        } label: {
          Label(ProjectPath.name(of: workspace.project), systemImage: "folder")
        }
        .buttonStyle(.borderless)
        .disabled(inspector.directory.isEmpty)
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.themeMuted).accessibilityHidden(true)
        let trail = Breadcrumb.trail(inspector.directory)
        if trail.isEmpty {
          Text("Project root").foregroundStyle(.themeSecondary)
        }
        ForEach(Array(trail.enumerated()), id: \.element.id) { index, crumb in
          if index > 0 {
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.themeMuted)
              .accessibilityHidden(true)
          }
          Button(crumb.name) { Task { await inspector.open(directory: crumb.path) } }
            .buttonStyle(.borderless)
            .disabled(crumb.path == inspector.directory)
        }
      }
      .font(.caption)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Folder path")
  }

  @ViewBuilder private var preview: some View {
    if let path = inspector.previewPath {
      VStack(spacing: 0) {
        HStack(spacing: 6) {
          Image(systemName: FileKind.of(name: Self.fileName(path), directory: false).symbol)
            .foregroundStyle(.themeSecondary)
            .accessibilityHidden(true)
          Text(path).lineLimit(1).truncationMode(.head).help(path)
            .filePathMenu(path, workspace: workspace)
          if case .loaded(let text) = inspector.preview, !text.isEmpty {
            Text("\(FilePreview.lineCount(text)) lines").font(.caption).foregroundStyle(.themeSecondary)
          }
          Spacer(minLength: 4)
          Button {
            workspace.askAboutFile(path)
          } label: {
            Label("Ask Muse", systemImage: "arrow.up.right")
          }
          .controlSize(.small)
          .help("Ask Muse about this file")
        }
        .padding(8)
        Divider()
        switch inspector.preview {
        case .idle, .loading:
          ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
          Text(message)
            .foregroundStyle(.themeSecondary)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .loaded(let text):
          ReadOnlyTextView(text: text, identifier: "file-preview", label: "File preview")
        }
      }
    } else {
      ContentUnavailableView(
        "File preview", systemImage: "doc.text",
        description: Text("Select a file to inspect its contents or reference it in chat.").foregroundStyle(.themeSecondary))
    }
  }
}

extension FilesView {
  /// The last part of a project-relative path, which the backend writes with `/`.
  static func fileName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}

struct FileRow: View {
  @Environment(\.appearance) private var appearance
  let file: ProjectFile

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: FileKind.of(file).symbol)
        .foregroundStyle(file.directory ? appearance.colors.accent : appearance.colors.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(file.name).lineLimit(1)
      Spacer(minLength: 4)
      if file.directory {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.themeMuted).accessibilityHidden(true)
      }
    }
    .contentShape(.rect)
  }
}
