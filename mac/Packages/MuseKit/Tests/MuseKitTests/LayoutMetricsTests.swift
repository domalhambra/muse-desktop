import Foundation
import Testing
@testable import MuseKit

// The arithmetic behind the composer's row, the window's columns and the inspector's tabs, proved
// without a window.

private typealias Item = ComposerRowFit.Item

/// A composer row as the app builds it, with every optional control shown. The widths are
/// ESTIMATES, written down here because no window measures them: borderless SF Symbol buttons at
/// body size about 20 points (Attach, Voice), the separator 1, the worktree toggle as a bordered
/// button about 32, Send at `.title2` about 24. The pop-up pickers' minimum (proposed zero width)
/// is about 40, an arrow and its bezel; their ideals hold "Claude Sonnet 4.5", "Medium" and
/// "Auto-edit". The labels at the system font and the hint at `.caption` use estimated text widths.
private let realisticRow: [Item] = [
  Item(minimum: 20, ideal: 20, kind: .fixed),  // Attach
  Item(minimum: 1, ideal: 1, kind: .fixed),  // separator
  Item(minimum: 20, ideal: 20, kind: .fixed),  // Voice
  Item(minimum: 0, ideal: 37, kind: .label),  // "Model"
  Item(minimum: 40, ideal: 150, kind: .picker),  // model
  Item(minimum: 0, ideal: 105, kind: .label),  // "Reasoning effort"
  Item(minimum: 40, ideal: 90, kind: .picker),  // effort
  Item(minimum: 0, ideal: 34, kind: .label),  // "Mode"
  Item(minimum: 40, ideal: 110, kind: .picker),  // mode
  Item(minimum: 32, ideal: 32, kind: .fixed),  // worktree toggle
  Item(minimum: 0, ideal: 130, kind: .hint),  // "↵ Send · ⇧ ↵ New line"
  Item(minimum: 24, ideal: 24, kind: .send),  // Send
]
private let spacing: CGFloat = 8
private let ideal = ComposerRowFit.idealWidth(realisticRow, spacing: spacing)
private let minimum = ComposerRowFit.minimumWidth(realisticRow, spacing: spacing)

private func indices(_ kind: ComposerRowFit.Kind) -> [Int] {
  realisticRow.indices.filter { realisticRow[$0].kind == kind }
}

@Test func atTheRowsIdealWidthNothingDrops() {
  let widths = ComposerRowFit.widths(available: ideal, spacing: spacing, items: realisticRow)
  #expect(widths == realisticRow.map(\.ideal))
}

@Test func justBelowTheIdealWidthOnlyTheHintDrops() {
  let widths = ComposerRowFit.widths(available: ideal - 1, spacing: spacing, items: realisticRow)
  for index in realisticRow.indices {
    #expect(widths[index] == (realisticRow[index].kind == .hint ? 0 : realisticRow[index].ideal))
  }
}

@Test func narrowerTheLabelsDropAndThePickersKeepTheirIdeal() {
  let noHint = ideal - 130 - spacing
  let widths = ComposerRowFit.widths(available: noHint - 1, spacing: spacing, items: realisticRow)
  for index in indices(.label) + indices(.hint) { #expect(widths[index] == 0) }
  for index in indices(.picker) { #expect(widths[index] == realisticRow[index].ideal) }
}

@Test func narrowerStillThePickersShrinkInProportionButNeverBelowTheirMinimum() {
  let noLabels = ideal - (130 + 37 + 105 + 34) - 4 * spacing
  let widths = ComposerRowFit.widths(available: noLabels - 80, spacing: spacing, items: realisticRow)
  // Room: 110 + 50 + 70 = 230; each gives 80 / 230 of its own.
  let pickers = indices(.picker)
  for index in pickers {
    let item = realisticRow[index]
    #expect(widths[index] < item.ideal)
    #expect(abs(widths[index] - (item.ideal - (item.ideal - item.minimum) * 80 / 230)) < 0.0001)
  }
  for width in stride(from: minimum - 50, through: noLabels, by: 7) {
    let widths = ComposerRowFit.widths(available: width, spacing: spacing, items: realisticRow)
    for index in pickers { #expect(widths[index] >= realisticRow[index].minimum) }
  }
}

@Test func fixedControlsAndSendKeepTheirWidthAndTheRowFitsAtEveryWidthFromItsMinimum() {
  for width in stride(from: minimum, through: ideal + 40, by: 0.5) {
    let widths = ComposerRowFit.widths(available: width, spacing: spacing, items: realisticRow)
    for index in indices(.fixed) + indices(.send) { #expect(widths[index] == realisticRow[index].ideal) }
    #expect(ComposerRowFit.total(widths, spacing: spacing) <= width + 0.0001)
  }
}

@Test func anUnboundedProposalGivesTheIdealAndZeroGivesTheMinimum() {
  #expect(ComposerRowFit.widths(available: nil, spacing: spacing, items: realisticRow) == realisticRow.map(\.ideal))
  #expect(
    ComposerRowFit.widths(available: .infinity, spacing: spacing, items: realisticRow) == realisticRow.map(\.ideal))
  let zero = ComposerRowFit.widths(available: 0, spacing: spacing, items: realisticRow)
  #expect(ComposerRowFit.total(zero, spacing: spacing) == minimum)
  for index in indices(.picker) { #expect(zero[index] == realisticRow[index].minimum) }
  // 20 + 1 + 20 + 40 × 3 + 32 + 24, and seven gaps.
  #expect(minimum == 217 + 7 * spacing)
}

@Test func aPickerWhoseMinimumExceedsItsIdealKeepsItsIdeal() {
  let items = [Item(minimum: 90, ideal: 60, kind: .picker), Item(minimum: 20, ideal: 20, kind: .send)]
  #expect(ComposerRowFit.widths(available: 0, spacing: spacing, items: items) == [60, 20])
}

@Test func theWindowMinimumIsTheColumnsMinimumsAndTheDividers() {
  #expect(WindowMetrics.sidebarMin == 240)
  #expect(WindowMetrics.contentMin == 360)
  #expect(WindowMetrics.inspectorMin == 280)
  #expect(WindowMetrics.dividers == 2)
  #expect(
    WindowMetrics.windowMinWidth
      == WindowMetrics.sidebarMin + WindowMetrics.contentMin + WindowMetrics.inspectorMin + WindowMetrics.dividers)
  #expect(WindowMetrics.windowMinWidth == 882)
  #expect(WindowMetrics.defaultWidth >= WindowMetrics.windowMinWidth)
  #expect(WindowMetrics.defaultHeight >= WindowMetrics.windowMinHeight)
  #expect(WindowMetrics.defaultWidth == 900)
  #expect(WindowMetrics.defaultHeight == 620)
}

@Test func theComposerRowsMinimumFitsTheConversationColumnsMinimum() {
  // Proves the fit for the estimated widths above; the end-of-build UI test checks the real controls.
  #expect(minimum <= WindowMetrics.contentMin - 2 * WindowMetrics.composerPadding)
}

@Test func theInspectorShowsTitlesOnlyWhenEverySegmentFits() {
  // Six illustrative title widths with fractions, not measured ones; each is rounded up.
  let titles: [CGFloat] = [54.2, 27.6, 46.1, 34.9, 43.3, 47.0]
  let needed = InspectorTabFit.titledWidth(titles)
  #expect(needed == 55 + 28 + 47 + 35 + 44 + 47 + 6 * InspectorTabFit.segmentPadding)
  #expect(InspectorTabFit.segmentPadding == 24)
  #expect(InspectorTabFit.showsTitles(available: needed, titleWidths: titles))
  #expect(!InspectorTabFit.showsTitles(available: needed - 0.5, titleWidths: titles))
  // Not measured yet: titles, as the bar first draws.
  #expect(InspectorTabFit.showsTitles(available: 0, titleWidths: titles))
}

// The split view's overflow, as the live check measured it: 979 points in a 900-point window.
private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)

@Test func aWindowGrowsByTheSplitViewsOverflow() {
  let window = CGRect(x: 341, y: 198, width: 900, height: 648)
  let grown = WindowFit.grown(window: window, contentWidth: 900, splitWidth: 979, screen: screen)
  #expect(grown == CGRect(x: 341, y: 198, width: 979, height: 648))
}

@Test func aSplitViewThatFitsLeavesTheWindowAlone() {
  let window = CGRect(x: 341, y: 198, width: 900, height: 648)
  #expect(WindowFit.grown(window: window, contentWidth: 900, splitWidth: 900, screen: screen) == nil)
  #expect(WindowFit.grown(window: window, contentWidth: 900, splitWidth: 900.4, screen: screen) == nil)
  #expect(WindowFit.grown(window: window, contentWidth: 900, splitWidth: 640, screen: screen) == nil)
}

@Test func aWindowNearTheRightEdgeMovesLeftToGrow() {
  let window = CGRect(x: 600, y: 100, width: 900, height: 620)
  let grown = WindowFit.grown(window: window, contentWidth: 900, splitWidth: 979, screen: screen)
  #expect(grown == CGRect(x: 1512 - 979, y: 100, width: 979, height: 620))
}

@Test func aWindowNeverGrowsPastTheScreen() {
  let window = CGRect(x: 0, y: 0, width: 1500, height: 620)
  let grown = WindowFit.grown(window: window, contentWidth: 1500, splitWidth: 1600, screen: screen)
  #expect(grown == CGRect(x: 0, y: 0, width: 1512, height: 620))
  let full = CGRect(x: 0, y: 0, width: 1512, height: 620)
  #expect(WindowFit.grown(window: full, contentWidth: 1512, splitWidth: 1600, screen: screen) == nil)
}
