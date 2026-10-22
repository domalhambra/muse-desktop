import AppKit
import MuseBackend
import MuseKit
import SwiftUI

/// The open conversation, as Electron's `Transcript.tsx`.
struct TranscriptView: View {
  let workspace: Workspace
  let view: SessionView
  /// True while Dom is near the bottom, so new output scrolls into view.
  @State private var following = true
  /// True while Dom's own scrolling moves the transcript, so growth never pulls against it.
  @State private var scrolling = false
  private static let bottom = "transcript-bottom"

  var body: some View {
    let entries = TranscriptEntry.build(view.items)
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          if let notice = view.historyNotice {
            Text(notice).font(.callout).foregroundStyle(.secondary)
          }
          if entries.isEmpty, view.approvals.isEmpty, view.questions.isEmpty, view.error == nil {
            ContentUnavailableView(
              "Start a conversation", systemImage: "bubble.left.and.bubble.right",
              description: Text("Ask a question or describe what you want to build."))
          }
          ForEach(entries) { entry in EntryView(entry: entry, workspace: workspace) }
          ForEach(view.approvals) { approval in ApprovalCard(approval: approval, workspace: workspace) }
          ForEach(view.questions) { question in QuestionCard(question: question, workspace: workspace) }
          if let error = view.error { TurnErrorView(message: error) }
          Color.clear.frame(height: 1).id(Self.bottom)
        }
        .padding(20)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
      }
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .onScrollPhaseChange { _, phase in
        scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        // Growth during a gesture is not followed; catch up once it ends.
        if phase == .idle, following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
      }
      .onScrollGeometryChange(for: ScrollPlace.self) { geometry in
        ScrollPlace(
          nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 110,
          offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height)
      } action: { old, new in
        // Only Dom scrolling up stops following. Output that grows past the bottom moves
        // neither the offset nor the decision.
        if new.offset < old.offset, !new.nearBottom {
          if following { following = false }
        } else if new.nearBottom, !following {
          following = true
        }
        // New output, an expanded row, a resize or growth in an earlier in-progress item all
        // grow the content: keep the latest output in view while following.
        if following, !scrolling, new.contentHeight > old.contentHeight {
          proxy.scrollTo(Self.bottom, anchor: .bottom)
        }
      }
      .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
      // Announced when the error arrives, not each time the lazy row is drawn again.
      .onChange(of: view.error) { old, new in
        if old == nil, let new {
          AccessibilityNotification.Announcement("Muse couldn’t finish this turn. \(new)").post()
        }
      }
      .overlay(alignment: .bottom) {
        if !following {
          Button("Jump to latest message", systemImage: "arrow.down") {
            following = true
            withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
          }
          .buttonStyle(.borderedProminent)
          .padding()
        }
      }
    }
  }
}

/// Where the transcript is scrolled, for following new output.
private struct ScrollPlace: Equatable {
  let nearBottom: Bool
  let offset: CGFloat
  let contentHeight: CGFloat
}

struct EntryView: View {
  let entry: TranscriptEntry
  let workspace: Workspace

  var body: some View {
    switch entry {
    case .user(let item): UserMessageView(item: item)
    case .agent(let item): AgentMessageView(item: item)
    case .reasoning(let item): ReasoningView(item: item)
    case .tool(let item): ToolView(item: item, workspace: workspace)
    case .toolGroup(let items): ToolGroupView(items: items, workspace: workspace)
    }
  }
}

struct MessageHeader: View {
  let name: String
  /// Only user messages show their time, as in Electron.
  var recordedAt: String?
  var composing = false
  let copyText: String

  var body: some View {
    HStack(spacing: 8) {
      Text(name).font(.subheadline.bold())
      if let recordedAt, let date = RelativeTime.date(recordedAt) {
        Text(date.formatted(date: .omitted, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if composing { Text("Composing").font(.caption).foregroundStyle(.secondary) }
      Spacer()
      CopyButton(text: copyText)
    }
  }
}

/// An icon-only Copy button for a whole message.
struct CopyButton: View {
  let text: String
  @State private var copied = false
  @State private var failed = false
  @State private var reset: Task<Void, Never>?

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(text, forType: .string) else {
        failed = true
        return
      }
      failed = false
      copied = true
      reset?.cancel()
      reset = Task {
        try? await Task.sleep(for: .seconds(1.8))
        if !Task.isCancelled { copied = false }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
        if failed { Text("Select to copy").font(.caption) }
      }
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(copied ? "Copied" : "Copy")
    .help(failed ? "Could not copy. Select and copy the text." : "Copy")
  }
}

struct UserMessageView: View {
  let item: TranscriptItem

  var body: some View {
    let text = ToolPresentation.messageText(item)
    VStack(alignment: .leading, spacing: 6) {
      MessageHeader(name: "You", recordedAt: item.recordedAt, copyText: text)
      Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct AgentMessageView: View {
  let item: TranscriptItem
  /// Bumped after a pause in a streamed reply. `MarkdownCache` parses an in-progress item at most
  /// once per 100 ms, so without it the last text received could stay unparsed until the next
  /// update, or forever for an item that never leaves "inProgress".
  @State private var catchUp = 0

  var body: some View {
    let text = item.text ?? ""
    let _ = catchUp
    VStack(alignment: .leading, spacing: 6) {
      MessageHeader(name: "Muse", composing: item.status == "inProgress", copyText: text)
      if text.isEmpty, item.status == "inProgress" {
        Text("…").foregroundStyle(.secondary)
      } else {
        MarkdownView(
          blocks: MarkdownCache.shared.blocks(id: item.itemId, text: text, final: item.status != "inProgress"))
      }
    }
    .task(id: text) {
      guard item.status == "inProgress" else { return }
      try? await Task.sleep(for: .milliseconds(110))
      if !Task.isCancelled { catchUp += 1 }
    }
  }
}

/// A row that expands, as Electron's whole-row button: a click anywhere on its width toggles
/// it, and the content shows below while expanded.
struct ExpandableRow<RowLabel: View, Content: View>: View {
  @Binding var expanded: Bool
  @ViewBuilder let label: () -> RowLabel
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.easeInOut(duration: 0.15), value: expanded)
            .accessibilityHidden(true)
          label()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      if expanded {
        content().padding(.leading, 18)
      }
    }
  }
}

struct ReasoningView: View {
  let item: TranscriptItem
  @State private var expanded = false

  var body: some View {
    ExpandableRow(expanded: $expanded) {
      HStack(spacing: 6) {
        if item.status == "inProgress" {
          ProgressView().controlSize(.mini).accessibilityHidden(true)
          Text("Thinking")
        } else {
          Image(systemName: "checkmark.circle").accessibilityHidden(true)
          Text("Reasoning summary")
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    } content: {
      MarkdownView(
        blocks: MarkdownCache.shared.blocks(id: item.itemId, text: ToolPresentation.reasoningText(item)))
    }
  }
}

struct StatusIcon: View {
  let status: String

  var body: some View {
    switch status {
    case "inProgress":
      ProgressView().controlSize(.mini).accessibilityLabel("In progress")
    case "completed":
      Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityLabel("Completed")
    case "failed":
      Image(systemName: "xmark.circle").foregroundStyle(.red).accessibilityLabel("Failed")
    default:
      Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel(Self.spoken(status))
    }
  }

  /// A status as words: "cancelled" stays, "notStarted" reads "not started".
  static func spoken(_ status: String) -> String {
    status.reduce(into: "") { words, character in
      if character.isUppercase {
        words += " " + character.lowercased()
      } else {
        words.append(character)
      }
    }
  }
}

struct ToolLabel: View {
  let item: TranscriptItem

  var body: some View {
    HStack(spacing: 6) {
      StatusIcon(status: item.status)
      Image(systemName: item.kind == "subagent" ? "person.2" : item.kind == "toolCall" ? "terminal" : "doc.text")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(ToolPresentation.title(item)).bold()
      if let summary = ToolPresentation.summary(item) {
        Text(summary).foregroundStyle(.secondary).lineLimit(1)
      }
      if let patch = ToolPresentation.patch(item) {
        Text(patch).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
    }
    .font(.callout)
  }
}

struct ToolView: View {
  let item: TranscriptItem
  let workspace: Workspace
  @State private var expanded = false

  var body: some View {
    ExpandableRow(expanded: $expanded) {
      ToolLabel(item: item)
    } content: {
      VStack(alignment: .leading, spacing: 8) {
        if let objective = item.objective, !objective.isEmpty { Text(objective) }
        if let args = item.args, !args.isEmpty {
          Text("INPUT").font(.caption2.bold()).foregroundStyle(.secondary)
          MonospacedBox(text: ToolPresentation.formattedArgs(args))
        }
        if let output = ToolPresentation.output(item, stored: workspace.storedOutput[item.itemId]) {
          MonospacedBox(text: output)
        }
        if item.truncated == true {
          Text("Muse shortened the displayed output.").font(.caption).foregroundStyle(.secondary)
        }
        if item.outputRef != nil, workspace.storedOutput[item.itemId] == nil {
          let loading = workspace.loadingOutput.contains(item.itemId)
          Button(loading ? "Loading…" : "Read stored output") {
            Task { await workspace.readOutput(item) }
          }
          .disabled(loading)
        }
        Text(ToolPresentation.footer(item)).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct ToolGroupView: View {
  let items: [TranscriptItem]
  let workspace: Workspace
  @State private var expanded = false

  var body: some View {
    ExpandableRow(expanded: $expanded) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityHidden(true)
        Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).accessibilityHidden(true)
        Text(ToolPresentation.groupTitle(items)).bold()
        Text(ToolPresentation.groupDetail(items)).foregroundStyle(.secondary).lineLimit(1)
        if let patch = ToolPresentation.groupPatch(items) {
          Text(patch).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
      }
      .font(.callout)
    } content: {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(items) { item in ToolView(item: item, workspace: workspace) }
      }
    }
  }
}

/// Tool input or output: monospaced, selectable, scrolling past 320 points. Shows at most the
/// first 256 KB, so a 1 MB stored output stays quick to draw.
struct MonospacedBox: View {
  let text: String

  static let limit = 256 * 1024

  var body: some View {
    let (shown, cut) = Self.prefix(text)
    VStack(alignment: .leading, spacing: 4) {
      ScrollView([.horizontal, .vertical]) {
        Text(shown)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize()
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 320)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      if cut {
        Text("Showing the first 256 KB of this output.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  /// The first `limit` UTF-8 bytes of `text`, cut back to a whole character, and whether it cut.
  static func prefix(_ text: String) -> (String, Bool) {
    let bytes = text.utf8
    guard bytes.count > limit else { return (text, false) }
    var end = bytes.index(bytes.startIndex, offsetBy: limit)
    while end > bytes.startIndex, end.samePosition(in: text) == nil {
      end = bytes.index(before: end)
    }
    return (String(text[..<end]), true)
  }
}

struct TurnErrorView: View {
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Muse couldn’t finish this turn.", systemImage: "exclamationmark.triangle").bold()
      Text(message).textSelection(.enabled)
      Text("Your conversation is saved. You can send a follow-up or reconnect.")
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }
}
