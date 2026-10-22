import MuseBackend
import MuseKit
import SwiftUI

extension Color {
  /// `#rrggbb`, with an optional opacity.
  init(hex: String, opacity: Double = 1) {
    let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
    self.init(
      .sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
      blue: Double(value & 0xff) / 255, opacity: opacity)
  }
}

/// A theme's palette as SwiftUI colors. `ThemePalette` keeps six-digit hex; the alpha values
/// tokens.css gives some colors are applied here, so every view draws the same color.
struct ThemeColors {
  let text, heading, secondary, muted, accent: Color
  /// The sidebar list, over the window background. Electron's Muse sidebar is a translucent
  /// gradient; this is its solid color, let through.
  let sidebar: Color
  /// The inspector column.
  let dialog: Color
  /// The composer field.
  let input: Color
  let selection: Color
  /// Fenced code blocks.
  let codeBackground: Color

  init(_ theme: ThemeName) {
    let palette = theme.palette
    // tokens.css: Muse's `--input` is #061d4e9c, `--selection` #397dde99 and `--code-background`
    // #071e50de. Moonlight's three are opaque.
    let muse = theme == .muse
    text = Color(hex: palette.text)
    heading = Color(hex: palette.heading)
    secondary = Color(hex: palette.secondary)
    muted = Color(hex: palette.muted)
    accent = Color(hex: palette.accent)
    sidebar = Color(hex: palette.sidebar, opacity: 0.68)
    dialog = Color(hex: palette.dialog)
    input = Color(hex: palette.input, opacity: muse ? Double(0x9c) / 255 : 1)
    selection = Color(hex: palette.selection, opacity: muse ? Double(0x99) / 255 : 1)
    codeBackground = Color(hex: palette.codeBackground, opacity: muse ? Double(0xde) / 255 : 1)
  }
}

/// The current theme and reading size, for views below the root.
struct Appearance: Equatable {
  var theme: ThemeName = .muse
  var textSize: TextSize = .comfortable
  var reduceMotion = false
  var palette: ThemePalette { theme.palette }
  var colors: ThemeColors { ThemeColors(theme) }

  init(_ preferences: Preferences?) {
    guard let preferences else { return }
    theme = ThemeName(preference: preferences.theme)
    textSize = TextSize(preference: preferences.fontSize)
    reduceMotion = preferences.reduceMotion
  }

  /// A transcript heading's size: level 1 is the largest. Headings scale with the reading size.
  func headingSize(level: Int) -> Double {
    textSize.points * (level == 1 ? 1.35 : level == 2 ? 1.2 : 1.05)
  }
}

extension EnvironmentValues {
  @Entry var appearance = Appearance(nil)
}

/// The window background, as tokens.css's `--app-background`. Muse is
/// `radial-gradient(ellipse at 95% 0%, #0758cd 0%, transparent 62%)` over
/// `linear-gradient(125deg, #082968, #061b52 63%, #072e83)`; Moonlight is a solid color.
struct ThemeBackground: View {
  let palette: ThemePalette

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack {
        if palette.backgroundStops.count > 1 {
          let line = Self.gradientLine(degrees: 125, size: size)
          LinearGradient(gradient: Self.stops(palette.backgroundStops), startPoint: line.start, endPoint: line.end)
        } else {
          Color(hex: palette.backgroundStops.first ?? palette.base)
        }
        if let glow = palette.glow {
          // `ellipse at 95% 0%` takes the default size, farthest-corner: the ellipse has
          // farthest-side's proportions (95% of the width by the full height) and passes through
          // the far corner, so each radius is that side times √2.
          let radiusX = 0.95 * size.width * 2.squareRoot()
          let radiusY = size.height * 2.squareRoot()
          EllipticalGradient(
            gradient: Gradient(stops: [
              .init(color: Color(hex: glow), location: 0),
              .init(color: Color(hex: glow, opacity: 0), location: 0.62),
            ]),
            center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
          )
          .frame(width: radiusX * 2, height: radiusY * 2)
          .position(x: 0.95 * size.width, y: 0)
        }
      }
      .frame(width: size.width, height: size.height)
      .clipped()
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }

  /// Evenly spread stops, except that three stops put the middle one at 63%, as Muse's does.
  private static func stops(_ hexes: [String]) -> Gradient {
    let locations: [Double] =
      hexes.count == 3 ? [0, 0.63, 1] : hexes.indices.map { Double($0) / Double(max(hexes.count - 1, 1)) }
    return Gradient(stops: zip(hexes, locations).map { .init(color: Color(hex: $0), location: $1) })
  }

  /// CSS's gradient line for an angle: through the centre, pointing at the angle (0 degrees up,
  /// 90 right), and long enough that the perpendiculars at its ends touch the far corners.
  static func gradientLine(degrees: Double, size: CGSize) -> (start: UnitPoint, end: UnitPoint) {
    guard size.width > 0, size.height > 0 else { return (.top, .bottom) }
    let angle = degrees * .pi / 180
    let dx = sin(angle)
    let dy = -cos(angle)
    let half = (abs(size.width * dx) + abs(size.height * dy)) / 2
    let start = UnitPoint(x: 0.5 - dx * half / size.width, y: 0.5 - dy * half / size.height)
    let end = UnitPoint(x: 0.5 + dx * half / size.width, y: 0.5 + dy * half / size.height)
    return (start, end)
  }
}

private struct Themed: ViewModifier {
  let controller: AppController
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  func body(content: Content) -> some View {
    // Read here, in a view's body, so a `preferences` event redraws both scenes at once.
    let appearance = Appearance(controller.workspace?.preferences)
    let colors = appearance.colors
    content
      .environment(\.appearance, appearance)
      .tint(colors.accent)
      // `.secondary` and `.tertiary` resolve to these levels below.
      .foregroundStyle(colors.text, colors.secondary, colors.muted)
      .preferredColorScheme(.dark)
      .transaction { transaction in
        if appearance.reduceMotion || systemReduceMotion {
          transaction.disablesAnimations = true
          transaction.animation = nil
        }
      }
  }
}

extension View {
  /// Applies the saved theme, reading size and Reduce motion. With no backend yet, Muse. Both
  /// themes are dark.
  func themed(_ controller: AppController) -> some View { modifier(Themed(controller: controller)) }
}
