import SwiftUI

/// What the composer's row does with a view when the row is narrower than its views' ideal widths.
enum ComposerRowRole {
  /// Keeps its intrinsic width: the buttons and toggles.
  case fixed
  /// Gives up width down to its minimum, last: the model, effort and mode pickers.
  case picker
  /// Hides, second: a picker's visible label.
  case label
  /// Hides, first: the "↵ Send · ⇧ ↵ New line" hint.
  case hint
  /// Keeps its intrinsic width at the row's trailing edge: Send.
  case send
}

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

  /// The views' widths plus one spacing between each two that show.
  private static func total(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
    let shown = widths.filter { $0 > 0 }.count
    return widths.reduce(0, +) + spacing * CGFloat(max(shown - 1, 0))
  }

  /// Each view's width in a row `available` wide: ideal widths, then without the hint, then
  /// without the labels, then with the pickers compressed in proportion to what each can give.
  static func widths(for available: CGFloat?, subviews: Subviews, spacing: CGFloat) -> [CGFloat] {
    let roles = subviews.map { $0[ComposerRowRoleKey.self] }
    let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
    let minimums = subviews.indices.map { index in
      roles[index] == .picker ? min(subviews[index].sizeThatFits(.init(width: 0, height: nil)).width, ideals[index]) : 0
    }
    return fit(available: available, roles: roles, ideals: ideals, minimums: minimums, spacing: spacing)
  }

  /// The arithmetic of `widths`, apart from SwiftUI's subviews.
  static func fit(
    available: CGFloat?, roles: [ComposerRowRole], ideals: [CGFloat], minimums: [CGFloat], spacing: CGFloat
  ) -> [CGFloat] {
    var widths = ideals
    guard let available else { return widths }
    for dropped in [ComposerRowRole.hint, .label] where total(widths, spacing: spacing) > available {
      for index in roles.indices where roles[index] == dropped { widths[index] = 0 }
    }
    let excess = total(widths, spacing: spacing) - available
    guard excess > 0 else { return widths }
    let pickers = roles.indices.filter { roles[$0] == .picker }
    let room = pickers.reduce(0) { $0 + max(ideals[$1] - minimums[$1], 0) }
    guard room > 0 else { return widths }
    let share = min(excess / room, 1)
    for index in pickers {
      widths[index] = ideals[index] - max(ideals[index] - minimums[index], 0) * share
    }
    return widths
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
