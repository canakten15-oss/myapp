import SwiftUI

/// The image people share after a batch: "I freed 8.4 GB with Slash".
struct ShareCard: View {
    let savedBytes: Int64
    let count: Int
    var theme: AppTheme = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                SlashMark(size: 52)
                Text(verbatim: "SLASH").font(.slashDisplay(56)).foregroundStyle(.white)
            }
            .environment(\.theme, theme)
            Text("I just freed")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(Format.bytes(savedBytes))
                .font(.slashNumber(190))
                .foregroundStyle(theme.text)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("\(count) videos · no visible difference")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text("Free · no subscription · nothing leaves the iPhone")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(56)
        .frame(width: 1080, height: 1080, alignment: .topLeading)
        .background(Palette.background)
    }

    @MainActor
    func render() -> Image? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1
        guard let ui = renderer.uiImage else { return nil }
        return Image(uiImage: ui)
    }
}
