import SwiftUI

/// Three short pages before the photo-access question: what Slash does, privacy, and that the user decides.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let icon: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let pages: [Page] = [
        Page(id: 0, icon: "film.stack",
             title: "Slash the size. Keep the shot.",
             text: "Slash makes smaller copies of your biggest videos, often half the size or less, with no visible difference on your iPhone."),
        Page(id: 1, icon: "lock.iphone",
             title: "Nothing leaves your iPhone",
             text: "Every video is compressed on this iPhone. Nothing is uploaded, there is no account, and HDR, date, place and albums are kept."),
        Page(id: 2, icon: "hand.tap",
             title: "You decide",
             text: "Nothing is selected for you. A copy that looks worse is thrown away. Originals are only deleted after you've watched the copy and confirmed. Free: a small ad only appears while it works."),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages) { p in
                    VStack(spacing: 20) {
                        Image(systemName: p.icon)
                            .font(.system(size: 60, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(p.title).font(.title.bold()).multilineTextAlignment(.center)
                        Text(p.text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .tag(p.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { onDone() }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .accessibilityIdentifier(page < pages.count - 1 ? "onboardingNext" : "onboardingDone")

            Button("Skip") { onDone() }
                .font(.subheadline)
                .padding(.bottom, 8)
                .accessibilityIdentifier("onboardingSkip")
        }
    }
}
