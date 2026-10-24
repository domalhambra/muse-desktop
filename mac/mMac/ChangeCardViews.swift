import MuseBackend
import MuseKit
import SwiftUI

/// A pull request as a change card on a delivery track (parity spec, "Change cards"). The track
/// and the buttons wrap, so the card fits the inspector at its narrowest.
struct ChangeCardView: View {
  let pr: PullRequest
  let all: [PullRequest]
  let workspace: Workspace
  /// True for the open conversation's own card in Changes, which can merge when ready and archive.
  var conversationCard = false
  @Environment(\.openURL) private var openURL

  var body: some View {
    let track = ChangeCardRules.track(pr)
    let risk = ChangeCardRules.risk(pr.files)
    let blocker = ChangeCardRules.blocker(of: pr, in: all)
    VStack(alignment: .leading, spacing: 10) {
      Text(ChangeCardRules.headline(title: pr.title, body: pr.body))
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      let pictures = ChangeCardRules.pictures(pr.body)
      if !pictures.isEmpty {
        HStack(spacing: 8) {
          ForEach(pictures, id: \.self) { url in
            // A picture that fails to load, or is still loading, takes no room.
            AsyncImage(url: url) { phase in
              if let image = phase.image {
                image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 160)
              }
            }
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Before and after")
      }
      TrackView(track: track, acceptedText: track.step == .accepted ? ChangeCardRules.acceptedText(pr) : nil)
      HStack(spacing: 6) {
        Circle().fill(color(risk.light)).frame(width: 9, height: 9)
        Text(risk.reason).font(.caption).lineLimit(2)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Risk: \(risk.reason)")
      if let blocker {
        Label(blocker, systemImage: "arrow.turn.up.left")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(1)
          .accessibilityLabel(blocker)
      }
      FlowLayout(spacing: 6) {
        Button("Accept") { Task { await workspace.accept(pr) } }
          .disabled(track.step != .ready || blocker != nil)
          .accessibilityLabel("Accept PR \(pr.number)")
          .accessibilityIdentifier("change-accept-\(pr.number)")
        Button("Ask why") { Task { await workspace.askWhy(pr) } }
          .accessibilityLabel("Ask why PR \(pr.number) was made")
          .accessibilityIdentifier("change-why-\(pr.number)")
        if track.failing, workspace.view != nil {
          Button("Ask Muse to fix") { Task { await workspace.autoFix(pr) } }
            .accessibilityLabel("Ask Muse to fix the failing checks")
            .accessibilityIdentifier("change-fix-\(pr.number)")
        }
        if conversationCard, pr.state == "OPEN", track.step == .checked, !track.failing {
          Button("Merge when ready") { Task { await workspace.mergeWhenReady(pr) } }
            .accessibilityLabel("Merge PR \(pr.number) when its checks pass")
            .accessibilityIdentifier("change-merge-when-ready-\(pr.number)")
        }
        if conversationCard, track.step.rawValue >= ChangeCardRules.Step.accepted.rawValue,
          let session = workspace.view?.session, session.worktree != nil
        {
          Button("Archive conversation") { Task { await workspace.toggleArchive(session.sessionId) } }
            .accessibilityLabel("Archive this conversation")
            .accessibilityIdentifier("change-archive-\(pr.number)")
        }
      }
      .controlSize(.small)
      DisclosureGroup("Show details") {
        VStack(alignment: .leading, spacing: 4) {
          Text("Draft copy: \(pr.headRefName)  \u{2192}  master copy: \(pr.baseRefName)")
            .font(.caption.monospaced())
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Text(PullRequestRules.summary(pr.checks).text).font(.caption)
          ForEach(pr.checks, id: \.name) { check in
            Text("\(check.name): \(check.state)").font(.caption).lineLimit(1).truncationMode(.middle)
          }
          if let url = URL(string: pr.url), !pr.url.isEmpty {
            Button("Open on GitHub") { openURL(url) }
              .controlSize(.small)
              .accessibilityLabel("Open PR \(pr.number) on GitHub")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.caption)
      .accessibilityLabel("Show details")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("change-card-\(pr.number)")
  }

  private func color(_ light: ChangeCardRules.Light) -> Color {
    switch light {
    case .green: .green
    case .amber: .orange
    case .red: .red
    }
  }
}

/// The five steps, the current one lit; a failing Checked step shows red.
struct TrackView: View {
  let track: ChangeCardRules.Track
  let acceptedText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      FlowLayout(spacing: 4) {
        ForEach(ChangeCardRules.Step.allCases, id: \.self) { step in
          let lit = step == track.step
          // The step and its chevron wrap together.
          HStack(spacing: 4) {
            Text(step.title)
              .font(.caption2.weight(lit ? .bold : .regular))
              .lineLimit(1)
              .fixedSize()
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(
                (lit ? (track.failing ? Color.red : Color.accentColor) : Color.secondary).opacity(lit ? 0.35 : 0.12),
                in: Capsule())
            if step != .live {
              Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
          }
        }
      }
      if let acceptedText {
        Text(acceptedText).font(.caption).foregroundStyle(.themeSecondary).lineLimit(1).truncationMode(.middle)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Step: \(track.step.title)\(track.failing ? ", a check fails" : "")\(acceptedText.map { ", \($0)" } ?? "")")
  }
}

/// The project's change cards, in dependency order.
struct ProposedChangesSheet: View {
  let workspace: Workspace
  let done: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Proposed changes").font(.headline).accessibilityAddTraits(.isHeader)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if workspace.changeCards.isEmpty {
            Text("No proposed changes.").foregroundStyle(.themeSecondary)
          }
          ForEach(ChangeCardRules.ordered(workspace.changeCards)) { pr in
            ChangeCardView(pr: pr, all: workspace.changeCards, workspace: workspace)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Done", action: done)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.primary)
      }
    }
    .padding(20)
    .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
    .onExitCommand(perform: done)
    .accessibilityIdentifier("proposed-changes-sheet")
    .task { await workspace.loadChangeCards() }
  }
}
