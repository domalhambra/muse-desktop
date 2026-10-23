import AppKit
import MuseBackend
import MuseKit
import SwiftUI

/// The paperclip, as Electron's: a multi-select open panel for images and text files.
struct AttachButton: View {
  let workspace: Workspace

  var body: some View {
    Button {
      Task {
        let urls = await Self.chooseFiles()
        guard !urls.isEmpty else { return }
        await workspace.attach(urls)
      }
    } label: {
      Image(systemName: "paperclip")
    }
    .buttonStyle(.borderless)
    .disabled(workspace.submitting)
    .accessibilityLabel("Attach images or text files")
    .help("Attach images or text files")
    .accessibilityIdentifier("attach-button")
  }

  /// The files chosen in the panel, or none on Cancel. Electron sets no type filter.
  static func chooseFiles() async -> [URL] {
    #if DEBUG
      // The UI tests cannot drive an open panel, so Debug builds take MMAC_TEST_ATTACHMENTS instead.
      if let paths = ProcessInfo.processInfo.environment["MMAC_TEST_ATTACHMENTS"], !paths.isEmpty {
        return paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
      }
    #endif
    let panel = NSOpenPanel()
    panel.title = "Add context to your message"
    // A sheet has no title bar, so the message carries the same words.
    panel.message = "Add context to your message"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    return await SheetAlert.runMultiple(panel)
  }
}

/// The composer's attachments, as Electron's chips. They belong to the composer, not to a
/// conversation.
struct AttachmentChips: View {
  let workspace: Workspace

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(workspace.attachments) { attachment in
        // A chip in the send in flight cannot go: the backend is reading it.
        AttachmentChip(attachment: attachment, canRemove: !workspace.isSending(attachment.id)) {
          Task { await workspace.removeAttachment(attachment.id) }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Attachments")
    .accessibilityIdentifier("attachment-chips")
  }
}

/// One chip: an icon, the name and a remove button.
struct AttachmentChip: View {
  let attachment: Attachment
  var canRemove = true
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: attachment.kind == "image" ? "photo" : "doc.text").accessibilityHidden(true)
      Text(attachment.name).lineLimit(1).truncationMode(.middle)
      Button(action: remove) {
        Image(systemName: "xmark").font(.caption2.weight(.semibold))
      }
      .buttonStyle(.borderless)
      .disabled(!canRemove)
      .accessibilityLabel("Remove \(attachment.name)")
      .help("Remove \(attachment.name)")
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    // Electron's chips stop at 200 pixels; a long name loses its middle.
    .frame(maxWidth: 200, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("attachment-chip")
  }
}

/// Lays its views out in rows and wraps onto a new row when one is full, as Electron's `flex-wrap`.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(within: proposal.width ?? .infinity, subviews)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    // With no width, or an infinite one, the widest row.
    let widest = rows.map(\.width).max() ?? 0
    let width = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(within: bounds.width, subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        // Never wider than the row, so a chip in a narrow composer shrinks rather than overflows.
        let width = min(size.width, bounds.width)
        subviews[index].place(
          at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
        x += width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func rows(within maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
        rows.append(current)
        current = Row()
      }
      current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
