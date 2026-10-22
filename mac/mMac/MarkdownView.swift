import AppKit
import MuseKit
import SwiftUI

/// Draws Markdown blocks. Links open only on the web, as Electron allows.
struct MarkdownView: View {
  let blocks: [MarkdownBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(MarkdownBlock.identified(blocks)) { item in BlockView(block: item.block) }
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        ["http", "https"].contains(url.scheme?.lowercased()) ? .systemAction : .discarded
      })
  }
}

struct BlockView: View {
  let block: MarkdownBlock

  var body: some View {
    switch block {
    case .heading(let level, let text):
      Text(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
    case .paragraph(let text):
      LinkedText(text: text)
    case .code(let language, let code):
      CodeBlockView(language: language, code: code)
    case .quote(let blocks):
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
        MarkdownView(blocks: blocks).foregroundStyle(.secondary)
      }
    case .list(let ordered, let start, let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker(ordered: ordered, number: start + index, checked: item.checked))
              .monospacedDigit()
              .foregroundStyle(.secondary)
            MarkdownView(blocks: item.blocks)
          }
        }
      }
    case .table(let header, let rows, let alignments):
      TableBlockView(header: header, rows: rows, alignments: alignments)
    case .rule:
      Divider()
    }
  }

  private func marker(ordered: Bool, number: Int, checked: Bool?) -> String {
    if let checked { return checked ? "☑" : "☐" }
    return ordered ? "\(number)." : "•"
  }
}

/// A paragraph whose links each end with a small external-link icon, as Electron draws them.
struct LinkedText: View {
  let text: AttributedString

  var body: some View {
    Self.compose(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
  }

  static func compose(_ text: AttributedString) -> Text {
    var result = Text(verbatim: "")
    // `runs[\.link]` joins neighbouring runs with the same link, so a bold word inside a link
    // still gets one icon.
    for (link, range) in text.runs[\.link] {
      result = result + Text(AttributedString(text[range]))
      if link != nil {
        // Accessibility gets the icon as an unlabelled attachment character (U+FFFC), not the
        // symbol's name, and a plain-text copy leaves it out. An empty `.accessibilityLabel` on it
        // changes neither.
        result = result + Text(Image(systemName: "arrow.up.right")).font(.caption2).foregroundStyle(.secondary)
      }
    }
    return result
  }
}

/// A fenced code block: the language (or "code"), a Copy button, and the code, unhighlighted.
struct CodeBlockView: View {
  let language: String?
  let code: String
  @State private var copied = false
  @State private var copyFailed = false
  /// Resets "Copied". A second click restarts the 1.8 seconds.
  @State private var reset: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language ?? "code").font(.caption.monospaced()).foregroundStyle(.secondary)
        Spacer()
        Button(copyFailed ? "Select to copy" : copied ? "Copied" : "Copy", action: copy)
          .buttonStyle(.borderless)
          .font(.caption)
          .help(copyFailed ? "Could not copy. Select and copy the text." : "Copy the code")
          // Message headers have a Copy button too; the UI tests tell this one apart by it.
          .accessibilityIdentifier("code-copy")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      Divider()
      ScrollView(.horizontal) {
        Text(code)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
    }
    // Strong enough that the block's edge shows in the dark appearance too.
    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
  }

  private func copy() {
    let board = NSPasteboard.general
    board.clearContents()
    guard board.setString(code, forType: .string) else {
      copyFailed = true
      return
    }
    copyFailed = false
    copied = true
    reset?.cancel()
    reset = Task {
      try? await Task.sleep(for: .seconds(1.8))
      if !Task.isCancelled { copied = false }
    }
  }
}

struct TableBlockView: View {
  let header: [AttributedString]
  let rows: [[AttributedString]]
  /// Each column's alignment. A `Grid` column takes the alignment of its first row's cell.
  let alignments: [TableAlignment]

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
            Text(cell).bold().gridColumnAlignment(alignment(index))
          }
        }
        Divider()
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              Text(cell).textSelection(.enabled)
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func alignment(_ column: Int) -> HorizontalAlignment {
    switch column < alignments.count ? alignments[column] : .leading {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}
