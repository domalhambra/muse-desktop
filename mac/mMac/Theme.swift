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
struct ThemeColors: Equatable {
  let text, heading, secondary, muted, accent: Color
  /// A label on an `accent` fill. Moonlight's is tokens.css's `--on-primary` #182239 (8.61:1 on
  /// its accent). Muse's `--on-primary` #0753dd is only 4.20:1 on Muse's accent #b5d4ff, below
  /// WCAG AA for the small text of a button, so Muse uses its `--base` #062565 (9.47:1).
  let onAccent: Color
  /// The sidebar list, over the window background. Electron's Muse sidebar is a translucent
  /// gradient; this is its solid color, let through.
  let sidebar: Color
  /// tokens.css's `--sidebar-solid`, for what must hide the rows that scroll under it.
  let sidebarSolid: Color
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
    onAccent = Color(hex: muse ? palette.base : palette.onPrimary)
    sidebar = Color(hex: palette.sidebar, opacity: 0.68)
    sidebarSolid = Color(hex: palette.sidebar)
    dialog = Color(hex: palette.dialog)
    input = Color(hex: palette.input, opacity: muse ? Double(0x9c) / 255 : 1)
    selection = Color(hex: palette.selection, opacity: muse ? Double(0x99) / 255 : 1)
    codeBackground = Color(hex: palette.codeBackground, opacity: muse ? Double(0xde) / 255 : 1)
  }
}

/// The current theme and reading size, for views below the root.
struct Appearance: Equatable {
  let theme: ThemeName
  let textSize: TextSize
  let colors: ThemeColors
  /// mMac's Reduce motion, or the system's: `Themed` folds the system setting in.
  var reduceMotion: Bool
  var palette: ThemePalette { theme.palette }

  /// With no preferences yet, Muse at the comfortable size.
  init(_ preferences: Preferences?) {
    theme = preferences.map { ThemeName(preference: $0.theme) } ?? .muse
    textSize = preferences.map { TextSize(preference: $0.fontSize) } ?? .comfortable
    reduceMotion = preferences?.reduceMotion ?? false
    colors = ThemeColors(theme)
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

  /// Read in `body`, so a `preferences` event redraws both scenes at once.
  private var appearance: Appearance {
    var appearance = Appearance(controller.workspace?.preferences)
    appearance.reduceMotion = appearance.reduceMotion || systemReduceMotion
    return appearance
  }

  func body(content: Content) -> some View {
    let appearance = appearance
    let colors = appearance.colors
    let reduceMotion = appearance.reduceMotion
    content
      .environment(\.appearance, appearance)
      .tint(colors.accent)
      // The primary level only. A `Text`'s `.secondary` and `.tertiary` do not take the levels
      // set here, and pop-up buttons fill their bezel with the third level, so views name
      // `.themeSecondary` and `.themeMuted` instead.
      .foregroundStyle(colors.text)
      .preferredColorScheme(.dark)
      // A backstop: the views' own animations read `appearance.reduceMotion` too.
      .transaction { transaction in
        if reduceMotion {
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

  /// The window's toolbar. From macOS 26 it lets the theme's background run under the title,
  /// and scroll views soften their content under it. On macOS 15 the toolbar keeps its own
  /// background, so the transcript never scrolls under a bare title.
  @ViewBuilder func themedToolbar() -> some View {
    if #available(macOS 26, *) {
      toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      self
    }
  }

  /// The soft edge a scroll view shows under a see-through toolbar, from macOS 26.
  @ViewBuilder func softTopScrollEdge() -> some View {
    if #available(macOS 26, *) {
      scrollEdgeEffectStyle(.soft, for: .top)
    } else {
      self
    }
  }
}

/// The theme's secondary text and its muted text, for `.foregroundStyle` and `.fill`. SwiftUI's
/// `.secondary` and `.tertiary` draw the text color at a lower opacity, which falls below WCAG
/// contrast on the themes' backgrounds; these draw the palette's own colors.
struct ThemeStyle: ShapeStyle {
  enum Level { case secondary, muted }
  let level: Level

  func resolve(in environment: EnvironmentValues) -> Color {
    let colors = environment.appearance.colors
    return level == .secondary ? colors.secondary : colors.muted
  }
}

extension ShapeStyle where Self == ThemeStyle {
  /// The palette's `secondary`, in place of `.secondary`.
  static var themeSecondary: ThemeStyle { ThemeStyle(level: .secondary) }
  /// The palette's `muted`, in place of `.tertiary`.
  static var themeMuted: ThemeStyle { ThemeStyle(level: .muted) }
}

/// A primary action, as Electron's `--primary` button: an `accent` fill with a dark label. The
/// system's `.borderedProminent` draws a white label on the tint, which is under 2:1 on both
/// themes' light accents.
struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { PrimaryButton(configuration: configuration) }

  private struct PrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.appearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      configuration.label
        .fontWeight(.semibold)
        .foregroundStyle(appearance.colors.onAccent)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(appearance.colors.accent, in: RoundedRectangle(cornerRadius: 6))
        .brightness(configuration.isPressed ? -0.08 : 0)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(.rect)
    }
  }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
  static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
