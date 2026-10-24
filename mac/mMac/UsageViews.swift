import MuseBackend
import MuseKit
import SwiftUI

/// The sidebar's limits line, as Desktop's usage ring, and its popover.
struct UsageFooter: View {
  let limits: SubscriptionLimits
  @State private var showing = false
  @Environment(\.appearance) private var appearance

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Button { showing.toggle() } label: {
        HStack(spacing: 6) {
          // The warning colour goes on the icon only: amber caption text fails contrast.
          Image(systemName: "gauge.with.dots.needle.33percent")
            .foregroundStyle(color(UsageRules.footerLevel(limits, now: context.date)))
          Text(UsageRules.footer(limits, now: context.date))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.themeSecondary)
          Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("usage-footer")
      .accessibilityLabel("Usage limits")
      .accessibilityValue(UsageRules.spokenFooter(limits, now: context.date))
      .popover(isPresented: $showing, arrowEdge: .trailing) {
        UsagePopover(limits: limits, now: context.date)
      }
    }
  }

  private func color(_ level: UsageRules.Level) -> Color {
    switch level {
    case .normal: appearance.colors.secondary
    case .warning: .orange
    case .full: .red
    }
  }
}

struct UsagePopover: View {
  let limits: SubscriptionLimits
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      row("Session limit", percent: limits.window.usedPercent, resetsAt: limits.window.resetsAt)
      row("Weekly limit", percent: limits.weekly.usedPercent, resetsAt: limits.weekly.resetsAt)
      Text("as of \(observed) \u{00B7} tier: \(limits.tier)")
        .font(.caption)
        .foregroundStyle(.themeSecondary)
    }
    .padding(14)
    .frame(width: 260)
  }

  private var observed: String {
    Date(timeIntervalSince1970: limits.observedAt / 1000).formatted(date: .omitted, time: .shortened)
  }

  @ViewBuilder private func row(_ name: String, percent: Int, resetsAt: Double) -> some View {
    let stale = UsageRules.isStale(resetsAt: resetsAt, observedAt: limits.observedAt, now: now)
    let reset = UsageRules.resetText(resetsAt, now: now)
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(name).bold()
        Spacer()
        Text(stale ? "reset since last update" : "\(percent)%").monospacedDigit()
      }
      if !stale {
        ProgressView(value: Double(min(percent, 100)), total: 100)
          .tint(tint(UsageRules.level(percent)))
        Text(reset).font(.caption).foregroundStyle(.themeSecondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      stale
        ? "\(name), reset since last update"
        : UsageRules.spoken(name: name, percent: percent, reset: reset))
  }

  private func tint(_ level: UsageRules.Level) -> Color {
    switch level {
    case .normal: .accentColor
    case .warning: .orange
    case .full: .red
    }
  }
}
