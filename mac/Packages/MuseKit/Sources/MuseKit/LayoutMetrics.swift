import CoreGraphics
import Foundation

// The arithmetic of mMac's layout: the composer's row, the window's columns and the inspector's
// tabs. The app measures its views and asks these; swift test proves them without a window.

/// How the composer's row shares its width. Every item gets its ideal width while the row is wide
/// enough. When it is not, the hint goes first, then the pickers' labels, then the pickers compress
/// toward their minimums in proportion to what each can give. Fixed controls and Send keep their
/// ideal width at every width.
public enum ComposerRowFit {
  /// What the row does with an item when the row is narrower than the items' ideal widths.
  public enum Kind: Sendable {
    /// Keeps its ideal width: the buttons and toggles.
    case fixed
    /// Gives up width down to its minimum, last: the model, effort and mode pickers.
    case picker
    /// Drops, second: a picker's visible label.
    case label
    /// Drops, first: the "↵ Send · ⇧ ↵ New line" hint.
    case hint
    /// Keeps its ideal width at the row's trailing edge: Send.
    case send
  }

  /// One view in the row. Only a picker reads `minimum`, and never past its `ideal`.
  public struct Item: Sendable, Equatable {
    public var minimum: CGFloat
    public var ideal: CGFloat
    public var kind: Kind

    public init(minimum: CGFloat, ideal: CGFloat, kind: Kind) {
      self.minimum = minimum
      self.ideal = ideal
      self.kind = kind
    }
  }

  /// The widths plus one spacing between each two items that show.
  public static func total(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
    let shown = widths.filter { $0 > 0 }.count
    return widths.reduce(0, +) + spacing * CGFloat(max(shown - 1, 0))
  }

  /// Each item's width in a row `available` wide, 0 for a dropped item. Nil or infinite means
  /// "your ideal width". Below the row's minimum the result is the minimum, and overflows.
  public static func widths(available: CGFloat?, spacing: CGFloat, items: [Item]) -> [CGFloat] {
    let ideals = items.map(\.ideal)
    var widths = ideals
    guard let available, available.isFinite else { return widths }
    for dropped in [Kind.hint, .label] where total(widths, spacing: spacing) > available {
      for index in items.indices where items[index].kind == dropped { widths[index] = 0 }
    }
    let excess = total(widths, spacing: spacing) - available
    guard excess > 0 else { return widths }
    let pickers = items.indices.filter { items[$0].kind == .picker }
    let give = { (index: Int) in max(ideals[index] - items[index].minimum, 0) }
    let room = pickers.reduce(0) { $0 + give($1) }
    guard room > 0 else { return widths }
    let share = min(excess / room, 1)
    for index in pickers { widths[index] = ideals[index] - give(index) * share }
    return widths
  }

  /// The row's width with every item at its ideal.
  public static func idealWidth(_ items: [Item], spacing: CGFloat) -> CGFloat {
    total(widths(available: nil, spacing: spacing, items: items), spacing: spacing)
  }

  /// The narrowest the row gets: no hint, no labels, the pickers at their minimums.
  public static func minimumWidth(_ items: [Item], spacing: CGFloat) -> CGFloat {
    total(widths(available: 0, spacing: spacing, items: items), spacing: spacing)
  }
}

/// The window's and the columns' widths. The window's minimum is the sum of the three columns'
/// minimums and the two dividers. A column whose content wants more than its minimum must
/// compress or clip that content, as the composer's row and the inspector's tabs do. The split
/// view does not shrink the sidebar to make room for the inspector: it opens the inspector at its
/// ideal width and runs past the window's edges instead (979 points in a 900-point window, seen
/// on 2026-10-24). `WindowFit` gives the window the width the split view takes.
public enum WindowMetrics {
  public static let sidebarMin: CGFloat = 240
  public static let sidebarIdeal: CGFloat = 260
  public static let sidebarMax: CGFloat = 420
  public static let contentMin: CGFloat = 360
  public static let inspectorMin: CGFloat = 280
  public static let inspectorIdeal: CGFloat = 340
  public static let inspectorMax: CGFloat = 420
  /// The split view's two dividers.
  public static let dividers: CGFloat = 2
  public static let windowMinWidth = sidebarMin + contentMin + inspectorMin + dividers
  public static let windowMinHeight: CGFloat = 560
  /// The size a window opens at when it has no saved frame, as the UI tests open it.
  public static let defaultWidth: CGFloat = 900
  public static let defaultHeight: CGFloat = 620
  /// The composer's padding on each side, inside the conversation column.
  public static let composerPadding: CGFloat = 12
}

/// The window frame that holds a split view wider than the window's content. The window grows by
/// the overflow, as far as the screen allows, and keeps its left edge unless that would put its
/// right edge off the screen. The height and the vertical position do not change.
public enum WindowFit {
  /// The frame for `window`, whose content is `contentWidth` wide and holds a split view
  /// `splitWidth` wide, on a screen whose visible frame is `screen`. Nil when the split view
  /// fits, or when the window cannot grow.
  public static func grown(window: CGRect, contentWidth: CGFloat, splitWidth: CGFloat, screen: CGRect) -> CGRect? {
    let overflow = splitWidth - contentWidth
    // Half a point is rounding, not overflow.
    guard overflow > 0.5 else { return nil }
    let width = min(window.width + overflow.rounded(.up), screen.width)
    guard width > window.width else { return nil }
    var x = window.minX
    if x + width > screen.maxX { x = max(screen.minX, screen.maxX - width) }
    return CGRect(x: x, y: window.minY, width: width, height: window.height)
  }
}

/// The inspector's tab bar: titled segments when all of them fit, icons otherwise.
public enum InspectorTabFit {
  /// Room around each title in a segment: an estimate on the generous side, so titles show only
  /// when they fit uncut.
  public static let segmentPadding: CGFloat = 24

  /// The width the titled segments need, from each title's measured width.
  public static func titledWidth(_ titleWidths: [CGFloat]) -> CGFloat {
    titleWidths.reduce(0) { $0 + $1.rounded(.up) + segmentPadding }
  }

  /// Whether the bar, `available` wide, shows titles. Zero means not measured yet: titles.
  public static func showsTitles(available: CGFloat, titleWidths: [CGFloat]) -> Bool {
    available == 0 || available >= titledWidth(titleWidths)
  }
}
