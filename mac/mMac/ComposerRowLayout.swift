import MuseKit
import SwiftUI

/// What the composer's row does with a view when the row is narrower than its views' ideal widths:
/// see `ComposerRowFit.Kind`.
typealias ComposerRowRole = ComposerRowFit.Kind

private struct ComposerRowRoleKey: LayoutValueKey {
  static let defaultValue = ComposerRowRole.fixed
}

extension View {
  func composerRowRole(_ role: ComposerRowRole) -> some View {
    layoutValue(key: ComposerRowRoleKey.self, value: role)
  }
}

/// The composer's control row. Every view gets its ideal width while the row is wide enough.
/// When it is not, the hint goes first, then the pickers' labels, then the pickers compress
/// toward their minimums. The buttons keep their size, and Send stays at the trailing edge, inside
/// the window. Spare width goes before the hint and Send.
///
/// A hidden view is proposed zero width: `ComposerRowLabel` then draws nothing.
struct ComposerRowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let available = Self.finite(proposal.width)
    let widths = Self.widths(for: available, subviews: subviews, spacing: spacing)
    let total = Self.total(widths, spacing: spacing)
    let height = zip(subviews, widths).map { $1 > 0 ? $0.sizeThatFits(.init(width: $1, height: nil)).height : 0 }
      .max() ?? 0
    return CGSize(width: max(available ?? total, total), height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let widths = Self.widths(for: bounds.width, subviews: subviews, spacing: spacing)
    let spare = max(bounds.width - Self.total(widths, spacing: spacing), 0)
    var x = bounds.minX
    var spareGiven = false
    var placedAny = false
    for (subview, width) in zip(subviews, widths) {
      let role = subview[ComposerRowRoleKey.self]
      if !spareGiven, role == .hint || role == .send {
        x += spare
        spareGiven = true
      }
      guard width > 0 else {
        subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .init(width: 0, height: 0))
        continue
      }
      if placedAny { x += spacing }
      subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .init(width: width, height: nil))
      x += width
      placedAny = true
    }
  }

  /// Nil for no proposal or an infinite one: both mean "your ideal width".
  private static func finite(_ width: CGFloat?) -> CGFloat? {
    guard let width, width.isFinite else { return nil }
    return width
  }

  private static func total(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
    ComposerRowFit.total(widths, spacing: spacing)
  }

  /// Each view's width in a row `available` wide, from `ComposerRowFit`. A picker's minimum is
  /// its width when proposed zero.
  static func widths(for available: CGFloat?, subviews: Subviews, spacing: CGFloat) -> [CGFloat] {
    let items = subviews.map { subview in
      let kind = subview[ComposerRowRoleKey.self]
      let ideal = subview.sizeThatFits(.unspecified).width
      let minimum = kind == .picker ? subview.sizeThatFits(.init(width: 0, height: nil)).width : ideal
      return ComposerRowFit.Item(minimum: minimum, ideal: ideal, kind: kind)
    }
    return ComposerRowFit.widths(available: available, spacing: spacing, items: items)
  }
}

/// A label or hint for `ComposerRowLayout`: its text on one line when the row gives it its full
/// width, and nothing when the row hides it. Never wrapped or cut.
struct ComposerRowLabel: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      Text(text).lineLimit(1).fixedSize()
      Color.clear.frame(width: 0, height: 0)
    }
  }
}
