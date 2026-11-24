import SwiftUI

/// The three blues to choose from. Switch in Settings; the choice is stored.
enum AppTheme: String, CaseIterable, Identifiable {
    case electric, estoril, royal
    var id: String { rawValue }

    /// Fills: buttons, bars, selection. White text sits on it.
    var color: Color {
        switch self {
        case .electric: return Color(hex: 0x2B6CFF)
        case .estoril:  return Color(hex: 0x1F57B5)
        case .royal:    return Color(hex: 0x4169E1)
        }
    }

    /// Lighter tint for text and numbers on the dark background (readable).
    var text: Color {
        switch self {
        case .electric: return Color(hex: 0x6E9BFF)
        case .estoril:  return Color(hex: 0x7FA6E6)
        case .royal:    return Color(hex: 0x93ABF2)
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .electric: return "Electric blue"
        case .estoril:  return "Estoril blue"
        case .royal:    return "Royal blue"
        }
    }

    static let storageKey = "theme"
    static let `default`: AppTheme = .estoril
}

/// Fixed dark palette around the blue.
enum Palette {
    static let background = Color(hex: 0x07090E)
    static let surface = Color(hex: 0x10141D)
    static let surface2 = Color(hex: 0x151A24)
    static let stroke = Color(hex: 0x232A38)
    static let track = Color(hex: 0x1C2230)
    static let text = Color(hex: 0xF2F4F8)
    static let secondary = Color(hex: 0x9AA3B5)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .default
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Type

extension Font {
    /// Big condensed numbers: "38.4 GB".
    static func slashNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.condensed)
    }
    /// Slanted condensed wordmark / button text: "SLASH 3 VIDEOS".
    static func slashDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black).width(.condensed).italic()
    }
}

// MARK: - Identity

/// The mark: a rounded square cut by a diagonal slash.
struct SlashMark: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(theme.color)
            .overlay(
                Rectangle()
                    .fill(Palette.background)
                    .frame(width: size * 0.19, height: size * 1.4)
                    .rotationEffect(.degrees(24))
                    .offset(x: size * 0.02)
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SlashWordmark: View {
    var size: CGFloat = 30
    var body: some View {
        HStack(spacing: size * 0.27) {
            SlashMark(size: size * 0.87)
            Text(verbatim: "SLASH")
                .font(.slashDisplay(size))
                .tracking(1)
                .foregroundStyle(Palette.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Slash"))
    }
}

/// A shape whose right edge is cut diagonally, filling `progress` of the width.
struct SlashCut: Shape {
    var progress: Double
    var slant: CGFloat = 0.3   // horizontal run of the cut, as a share of the height

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let run = rect.height * slant
        let top = rect.minX + (rect.width + run) * min(max(progress, 0), 1)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: min(top, rect.maxX + run), y: rect.minY))
        p.addLine(to: CGPoint(x: top - run, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Just the diagonal line at the cut, for a bright edge.
struct SlashEdge: Shape {
    var progress: Double
    var slant: CGFloat = 0.3

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let run = rect.height * slant
        let top = rect.minX + (rect.width + run) * min(max(progress, 0), 1)
        var p = Path()
        p.move(to: CGPoint(x: top, y: rect.minY))
        p.addLine(to: CGPoint(x: top - run, y: rect.maxY))
        return p
    }
}

/// Diagonal hatching for the part that gets cut away.
struct Hatching: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.track))
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height * 0.6, y: 0))
                ctx.stroke(p, with: .color(Color(hex: 0x262E3F)), lineWidth: 5)
                x += 14
            }
        }
        .accessibilityHidden(true)
    }
}

/// Before → after: the full size, with the kept part in blue and the rest slashed away.
struct ShrinkBar: View {
    @Environment(\.theme) private var theme
    let before: Int64
    let after: Int64
    var height: CGFloat = 44

    private var share: Double { before > 0 ? Double(after) / Double(before) : 1 }

    var body: some View {
        ZStack(alignment: .leading) {
            Hatching()
            SlashCut(progress: share, slant: 0.45)
                .fill(theme.color)
            HStack {
                Text(Format.bytes(after))
                    .font(.slashNumber(22))
                    .foregroundStyle(.white)
                    .padding(.leading, 14)
                Spacer()
                Text(verbatim: "−" + Format.bytes(max(before - after, 0)))
                    .font(.slashNumber(22))
                    .foregroundStyle(Palette.secondary)
                    .padding(.trailing, 14)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.spring(duration: 0.45), value: share)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Format.bytes(before)) → \(Format.bytes(after))"))
    }
}

/// Filled capsule button in the theme colour, with slanted text.
struct SlashButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.slashDisplay(24))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(isEnabled ? .white : Palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(isEnabled ? theme.color : Palette.surface2,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Dark rounded panel.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Swatches to switch between the three blues.
struct ThemePicker: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.default.rawValue

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppTheme.allCases) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { themeRaw = t.rawValue }
                } label: {
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(t.color)
                            .frame(height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white, lineWidth: themeRaw == t.rawValue ? 3 : 0)
                            )
                        Text(t.name).font(.caption.weight(.semibold)).foregroundStyle(Palette.text)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(themeRaw == t.rawValue ? .isSelected : [])
                .accessibilityIdentifier("theme-\(t.rawValue)")
            }
        }
    }
}
