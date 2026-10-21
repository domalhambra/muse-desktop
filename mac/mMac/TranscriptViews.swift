import AppKit
import MuseBackend
import MuseKit
import SwiftUI

/// The open conversation, as Electron's `Transcript.tsx`.
struct TranscriptView: View {
  @Bindable var workspace: Workspace
  let view: SessionView
  /// True while Dom is near the bottom, so new output scrolls into view.
  @State private var following = true
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
      .onScrollGeometryChange(for: ScrollPlace.self) { geometry in
        ScrollPlace(
          nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 110,
          offset: geometry.contentOffset.y)
      } action: { old, new in
        // Only Dom scrolling up stops following. Output that grows past the bottom moves
        // neither the offset nor the decision, so the next change still scrolls it in.
        if new.nearBottom {
          if !following { following = true }
        } else if new.offset < old.offset, following {
          following = false
        }
      }
      .onChange(of: contentMark) {
        if following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
      }
      .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
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

  /// Changes whenever new output arrives. Streamed deltas leave `revision` alone, so the
  /// last item's growing fields are counted too.
  private var contentMark: ContentMark {
    let last = view.items.last
    return ContentMark(
      items: view.items.count, revision: last?.revision ?? 0, text: last?.text?.count ?? 0,
      output: last?.visibleOutput?.count ?? 0,
      summary: last?.summary?.reduce(0) { $0 + $1.count } ?? 0,
      status: last?.status ?? "", approvals: view.approvals.count,
      questions: view.questions.count, error: view.error != nil)
  }
}

/// Where the transcript is scrolled, for following new output.
private struct ScrollPlace: Equatable {
  let nearBottom: Bool
  let offset: CGFloat
}

private struct ContentMark: Equatable {
  let items: Int
  let revision: Int
  let text: Int
  let output: Int
  let summary: Int
  let status: String
  let approvals: Int
  let questions: Int
  let error: Bool
}

struct EntryView: View {
  let entry: TranscriptEntry
  @Bindable var workspace: Workspace

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

  var body: some View {
    let text = item.text ?? ""
    VStack(alignment: .leading, spacing: 6) {
      MessageHeader(name: "Muse", composing: item.status == "inProgress", copyText: text)
      if text.isEmpty, item.status == "inProgress" {
        Text("…").foregroundStyle(.secondary)
      } else {
        MarkdownView(blocks: MarkdownCache.shared.blocks(id: item.itemId, text: text))
      }
    }
  }
}

/// Lets a click anywhere on a disclosure row's label open it, as Electron's whole-row button.
private struct TogglesOnClick: ViewModifier {
  @Binding var expanded: Bool

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
  }
}

struct ReasoningView: View {
  let item: TranscriptItem
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      MarkdownView(
        blocks: MarkdownCache.shared.blocks(id: item.itemId, text: ToolPresentation.reasoningText(item))
      )
      .padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        if item.status == "inProgress" {
          ProgressView().controlSize(.mini)
          Text("Thinking")
        } else {
          Image(systemName: "checkmark.circle")
          Text("Reasoning summary")
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .modifier(TogglesOnClick(expanded: $expanded))
    }
  }
}

struct StatusIcon: View {
  let status: String

  var body: some View {
    switch status {
    case "inProgress": ProgressView().controlSize(.mini)
    case "completed": Image(systemName: "checkmark.circle").foregroundStyle(.green)
    default: Image(systemName: "xmark.circle").foregroundStyle(.red)
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
  @Bindable var workspace: Workspace
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
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
      .padding(.top, 4)
    } label: {
      ToolLabel(item: item).modifier(TogglesOnClick(expanded: $expanded))
    }
  }
}

struct ToolGroupView: View {
  let items: [TranscriptItem]
  @Bindable var workspace: Workspace
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(items) { item in ToolView(item: item, workspace: workspace) }
      }
      .padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle").foregroundStyle(.green)
        Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
        Text(ToolPresentation.groupTitle(items)).bold()
        Text(ToolPresentation.groupDetail(items)).foregroundStyle(.secondary).lineLimit(1)
        if let patch = ToolPresentation.groupPatch(items) {
          Text(patch).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
      }
      .font(.callout)
      .modifier(TogglesOnClick(expanded: $expanded))
    }
  }
}

/// Tool input or output: monospaced, selectable, scrolling past 320 points.
struct MonospacedBox: View {
  let text: String

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(text)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize()
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 320)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
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
