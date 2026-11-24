import SwiftUI

/// The image people share after a batch: "I freed 8.4 GB with Slash".
struct ShareCard: View {
    let savedBytes: Int64
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SLASH")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .tracking(4)
                .foregroundStyle(Color(red: 0.31, green: 0.86, blue: 0.55))
            Text("I just freed")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(Format.bytes(savedBytes))
                .font(.system(size: 92, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
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
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }

    @MainActor
    func render() -> Image? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1
        guard let ui = renderer.uiImage else { return nil }
        return Image(uiImage: ui)
    }
}
