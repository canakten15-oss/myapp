import Photos
import StoreKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.requestReview) private var requestReview
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.default.rawValue

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .default }

    var body: some View {
        Group {
            if !onboarded && model.authorization == .notDetermined {
                OnboardingView { withAnimation { onboarded = true } }
            } else {
                main
            }
        }
        .environment(\.theme, theme)
        .tint(theme.color)
        .preferredColorScheme(.dark)
        .background(Palette.background.ignoresSafeArea())
    }

    private var main: some View {
        NavigationStack {
            Group {
                switch model.authorization {
                case .authorized, .limited:
                    LibraryView()
                case .notDetermined:
                    AccessView()
                default:
                    DeniedView()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(Palette.background.ignoresSafeArea())
            .sheet(item: $model.batchResult) { result in
                BatchResultView(result: result)
                    .presentationDetents([.large])
                    .environment(\.theme, theme)
            }
            .alert("Info", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .onChange(of: model.shouldAskForReview) { _, ask in
            guard ask else { return }
            model.shouldAskForReview = false
            requestReview()
        }
    }
}

// MARK: - Library

enum LibraryTab: Hashable { case todo, shrunk, rejected }

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.theme) private var theme
    @State private var tab: LibraryTab = .todo
    @State private var compare: ShrunkRecord?
    @State private var showSettings = false
    @State private var visible: Set<String> = []
    @State private var heldID: String?

    var body: some View {
        Group {
            if model.isRunning {
                WorkingView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if !model.resumableIDs.isEmpty { ResumeCard() }
                        HeroView()
                        tabs
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.scan() }
                .safeAreaInset(edge: .bottom) {
                    if tab == .todo { ActionPanel() }
                }
            }
        }
        .task { if model.items.isEmpty { await model.scan() } }
        .sheet(isPresented: $showSettings) { SettingsView().environment(\.theme, theme) }
        .sheet(item: $compare) { r in CompareView(originalID: r.originalID, copyID: r.copyID) }
    }

    private var header: some View {
        HStack {
            SlashWordmark()
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.text.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .background(Palette.surface2, in: Circle())
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings")
        }
        .padding(.top, 8)
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                TabChip(title: "To do · \(model.items.count)", selected: tab == .todo) { tab = .todo }
                    .accessibilityIdentifier("tabTodo")
                TabChip(title: "Shrunk · \(model.shrunk.count)", selected: tab == .shrunk) { tab = .shrunk }
                    .accessibilityIdentifier("tabShrunk")
                if !model.rejected.isEmpty {
                    TabChip(title: "Can't shrink · \(model.rejected.count)", selected: tab == .rejected) { tab = .rejected }
                        .accessibilityIdentifier("tabRejected")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    @ViewBuilder private var content: some View {
        switch tab {
        case .todo: todo
        case .shrunk: shrunkGrid
        case .rejected: rejectedGrid
        }
    }

    /// The tile that plays its preview: the first fully visible one on the phone, or the one held down.
    private var previewID: String? {
        if let heldID { return heldID }
        return model.items.first { visible.contains($0.id) && $0.isLocal && !$0.status.isFinished }?.id
    }

    @ViewBuilder private var todo: some View {
        if model.isScanning && model.items.isEmpty {
            HStack(spacing: 10) { ProgressView(); Text("Looking for big videos…").foregroundStyle(Palette.secondary) }
                .padding(.vertical, 30)
        } else if model.items.isEmpty {
            Text("No videos over \(model.minSizeMB) MB left to shrink.")
                .foregroundStyle(Palette.secondary)
                .padding(.vertical, 30)
        } else {
            HStack {
                Text("Tap to select · hold to preview").font(.footnote).foregroundStyle(Palette.secondary)
                Spacer()
                selectMenu
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.items) { item in
                    VideoTile(item: item, playing: previewID == item.id)
                        .onTapGesture { model.toggle(item) }
                        .onLongPressGesture(minimumDuration: 0.25, pressing: { down in
                            heldID = down && item.isLocal ? item.id : nil
                        }, perform: {})
                        .modifier(VisibilityTracker(id: item.id, visible: $visible))
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                        .accessibilityIdentifier("videoRow")
                }
            }
        }
    }

    private var selectMenu: some View {
        Menu {
            Button("Biggest 5") { model.selectBiggest(5) }
            Button("Biggest 10") { model.selectBiggest(10) }
            Button("All over 1 GB") { model.selectOver(1_000_000_000) }
            if !model.years.isEmpty {
                Menu("By year") {
                    ForEach(model.years, id: \.self) { y in
                        Button(String(y)) { model.selectYear(y) }
                    }
                }
            }
            Divider()
            Button("All") { model.setAll(selected: true) }
            Button("None") { model.setAll(selected: false) }
        } label: {
            Label("Select", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Palette.surface2, in: Capsule())
        }
        .accessibilityIdentifier("selectMenu")
    }

    @ViewBuilder private var shrunkGrid: some View {
        if model.shrunk.isEmpty {
            Text("Shrunk videos show up here, so you can compare them with the original.")
                .foregroundStyle(Palette.secondary)
                .padding(.vertical, 30)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.shrunk) { r in
                    Button { compare = r } label: { ShrunkTile(record: r) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("shrunkRow")
                }
            }
            Text("Copies are also in the album “\(PhotoLibraryService.compressedAlbumTitle)”.")
                .font(.footnote).foregroundStyle(Palette.secondary)
        }
    }

    private var rejectedGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These would lose visible quality, so the originals were kept.")
                .font(.footnote).foregroundStyle(Palette.secondary)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.rejected) { RejectedTile(record: $0) }
            }
        }
    }
}

/// Keeps track of which tiles are fully on screen (iOS 18+; on iOS 17 only hold-to-preview).
private struct VisibilityTracker: ViewModifier {
    let id: String
    @Binding var visible: Set<String>

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.95) { isVisible in
                if isVisible { visible.insert(id) } else { visible.remove(id) }
            }
        } else {
            content
        }
    }
}

struct TabChip: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .bold : .medium))
                .foregroundStyle(selected ? Palette.background : Palette.text.opacity(0.85))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(selected ? Palette.text : Palette.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Big number on top: what Slash could free, plus what is already freed / waiting.
struct HeroView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.allVideosBytes > 0 {
                Text("Slash could free").font(.subheadline).foregroundStyle(Palette.secondary)
                Text(Format.bytes(model.potentialSavings))
                    .font(.slashNumber(72))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                Text("of \(Format.bytes(model.allVideosBytes)) in \(model.allVideosCount) videos")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            } else if model.isScanning {
                HStack(spacing: 10) { ProgressView(); Text("Looking at your videos…").foregroundStyle(Palette.secondary) }
            }

            if model.freedBytes > 0 {
                Label("\(Format.bytes(model.freedBytes)) freed so far", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text)
                    .padding(.top, 4)
            }

            if !model.pendingDeleteIDs.isEmpty {
                Panel(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(model.pendingDeleteIDs.count) originals still in your library. Delete them to free \(Format.bytes(model.pendingSavedBytes)).")
                            .font(.subheadline)
                            .foregroundStyle(Palette.text)
                        Button {
                            Task { await model.deleteOriginals() }
                        } label: {
                            Label("Delete originals", systemImage: "trash")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.text)
                        .accessibilityIdentifier("deleteOriginalsAll")
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

/// Offers to continue a batch that was interrupted.
struct ResumeCard: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label("\(model.resumableIDs.count) videos left from your last run", systemImage: "arrow.clockwise.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.text)
                HStack(spacing: 10) {
                    Button("Continue") { model.resume() }
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16).frame(height: 40)
                        .background(theme.color, in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("resumeButton")
                    Button("Not now") { model.dismissResume() }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).frame(height: 40)
                        .background(Palette.surface2, in: Capsule())
                        .foregroundStyle(Palette.text)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Bottom panel: the cut, the level, the button

struct ActionPanel: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.selectedItems.isEmpty {
                Text("Select videos to see how much they shrink.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(model.selectedItems.count) videos · \(Format.bytes(model.selectedBytes))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("after ≈ \(Format.bytes(model.selectedBytes - model.estimatedSavings))")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                }
                ShrinkBar(before: model.selectedBytes, after: model.selectedBytes - model.estimatedSavings)
            }

            HStack(spacing: 10) {
                ForEach(CompressionQuality.allCases) { q in
                    LevelCard(quality: q, selected: model.quality == q) {
                        withAnimation(.spring(duration: 0.35)) { model.quality = q }
                    }
                }
            }

            if !model.selectedItems.isEmpty, model.estimatedSavingsOnPhone < model.estimatedSavings {
                Label(model.estimatedSavingsOnPhone > 0
                      ? "\(Format.bytes(model.estimatedSavingsOnPhone)) on this iPhone, the rest in iCloud"
                      : "Frees iCloud storage. These videos are only stored in iCloud.",
                      systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }

            Button { model.start() } label: {
                if model.selectedItems.isEmpty {
                    Text("Select videos")
                } else {
                    Text("Slash \(model.selectedItems.count) videos")
                }
            }
            .buttonStyle(SlashButtonStyle())
            .disabled(model.selectedItems.isEmpty || model.isScanning)
            .accessibilityIdentifier("compressButton")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.55), radius: 20, y: -8)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

struct LevelCard: View {
    @Environment(\.theme) private var theme
    let quality: CompressionQuality
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(quality.label).font(.subheadline.weight(.bold))
                    Spacer(minLength: 4)
                    Text(verbatim: "−\(Int(quality.typicalSavings * 100))%")
                        .font(.slashNumber(20))
                        .foregroundStyle(selected ? theme.text : Palette.secondary)
                }
                Text(quality.explanation)
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(Palette.text)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.color.opacity(0.2) : Palette.surface2,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? theme.color : Palette.stroke, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(quality.label))
        .accessibilityHint(Text(quality.explanation))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Tiles

struct Thumbnail: View {
    let asset: PHAsset?
    var size: CGFloat = 64
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Palette.surface2
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            guard image == nil, let asset else { return }
            PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: size * 3, height: size * 3)) { image = $0 }
        }
    }
}

/// Fills its frame with the video's poster image.
struct PosterImage: View {
    let asset: PHAsset?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.surface2
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .onAppear {
                guard image == nil, let asset else { return }
                let px = max(geo.size.width, geo.size.height) * 2.5
                PhotoLibraryService.thumbnail(for: asset, size: CGSize(width: px, height: px)) { image = $0 }
            }
        }
    }
}

private let tileShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

struct VideoTile: View {
    @Environment(\.theme) private var theme
    let item: VideoItem
    let playing: Bool

    var body: some View {
        ZStack {
            PosterImage(asset: item.asset)
            if playing { VideoPreview(asset: item.asset) }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    if playing {
                        Badge { Circle().fill(theme.text).frame(width: 6, height: 6); Text("Preview") }
                    } else if !item.isLocal {
                        Badge { Image(systemName: "icloud"); Text(verbatim: "iCloud") }
                            .accessibilityLabel("Stored in iCloud")
                    }
                    Spacer()
                    if !item.status.isFinished {
                        ZStack {
                            Circle().fill(item.isSelected ? theme.color : Color.black.opacity(0.35))
                            Circle().stroke(Color.white, lineWidth: 2)
                            if item.isSelected {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                    }
                }
                Spacer()
                StatusLine(status: item.status)
                HStack(alignment: .lastTextBaseline) {
                    Text(Format.bytes(item.fileSize)).font(.slashNumber(26)).foregroundStyle(.white)
                    Spacer()
                    Text(tileMeta).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(10)
        }
        .frame(height: 214)
        .clipShape(tileShape)
        .overlay(tileShape.strokeBorder(item.isSelected ? theme.color : .clear, lineWidth: 3))
        .contentShape(tileShape)
        .animation(.easeOut(duration: 0.15), value: item.isSelected)
    }

    private var tileMeta: String {
        let a = item.asset
        let res = max(a.pixelWidth, a.pixelHeight) >= 3800 ? "4K" : "\(min(a.pixelWidth, a.pixelHeight))p"
        return "\(res) · \(Format.duration(a.duration))"
    }
}

struct Badge<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 5) { content }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

struct ShrunkTile: View {
    @Environment(\.theme) private var theme
    let record: ShrunkRecord

    var body: some View {
        ZStack {
            PosterImage(asset: PhotoLibraryService.asset(record.copyID))
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading) {
                HStack {
                    Badge {
                        Image(systemName: record.originalDeleted ? "checkmark.seal.fill" : "play.fill")
                        Text(record.originalDeleted ? "Done" : "Compare")
                    }
                    Spacer()
                    Text(verbatim: "−\(record.savedPercent)%")
                        .font(.slashNumber(20))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(theme.color, in: Capsule())
                }
                Spacer()
                Text("\(Format.bytes(record.inputBytes)) → \(Format.bytes(record.outputBytes))")
                    .font(.slashNumber(20)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(record.originalDeleted ? "\(record.level) · original deleted"
                                            : "\(record.level) · original still in library")
                    .font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
            .padding(10)
        }
        .frame(height: 214)
        .clipShape(tileShape)
        .contentShape(tileShape)
    }
}

struct RejectedTile: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.theme) private var theme
    let record: RejectedRecord

    var body: some View {
        ZStack {
            PosterImage(asset: PhotoLibraryService.asset(record.originalID)).opacity(0.45)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(Format.bytes(record.fileSize)).font(.slashNumber(24)).foregroundStyle(.white)
                Text(record.reason).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                Button { model.retry(record) } label: {
                    Text("Try again")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Palette.surface2, in: Capsule())
                        .foregroundStyle(theme.text)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
        }
        .frame(height: 214)
        .clipShape(tileShape)
    }
}

struct StatusLine: View {
    let status: ItemStatus

    var body: some View {
        switch status {
        case .pending, .done:
            EmptyView()
        case .working(let phase, let p):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: p)
                Text(phase.label).font(.caption2)
            }
            .foregroundStyle(.white)
        case .skipped(let reason):
            Label(reason, systemImage: "minus.circle").font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange).lineLimit(2)
        }
    }
}

// MARK: - Working screen (the only place ads ever appear)

struct WorkingView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.theme) private var theme
    @ObservedObject private var ads = AdService.shared

    private var itemProgress: Double {
        if let item = model.currentItem, case .working(_, let p) = item.status { return p }
        return 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Video \(min(model.batchDone + 1, model.batchTotal)) of \(model.batchTotal)")
                        .font(.slashDisplay(26))
                        .textCase(.uppercase)
                        .accessibilityIdentifier("workingTitle")
                    Spacer()
                    Button { model.cancel() } label: {
                        Text("Stop")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(Palette.surface2, in: Capsule())
                            .foregroundStyle(Palette.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stopButton")
                }

                // the video, with the slash moving across it
                ZStack(alignment: .bottomLeading) {
                    PosterImage(asset: model.currentItem?.asset)
                    SlashCut(progress: itemProgress, slant: 0.25).fill(theme.color.opacity(0.6))
                    SlashEdge(progress: itemProgress, slant: 0.25).stroke(Color.white, lineWidth: 4)
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    Text(verbatim: "\(Int(itemProgress * 100))%")
                        .font(.slashNumber(64))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .padding(16)
                    if let item = model.currentItem {
                        VStack { HStack { Spacer(); Badge { Text(Format.bytes(item.fileSize)) } }; Spacer() }
                            .padding(12)
                    }
                }
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .animation(.linear(duration: 0.4), value: itemProgress)

                HStack(alignment: .firstTextBaseline) {
                    Text(model.currentItem.map { phaseLabel($0.status) } ?? String(localized: "Preparing"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(model.etaText).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track)
                            Capsule().fill(theme.color).frame(width: geo.size.width * model.batchProgress)
                        }
                    }
                    .frame(height: 10)
                    .animation(.linear(duration: 0.3), value: model.batchProgress)
                    HStack {
                        Text("All \(model.batchTotal) videos")
                        Spacer()
                        if model.lastBatchSaved > 0 {
                            Text("\(Format.bytes(model.lastBatchSaved)) slashed so far")
                                .foregroundStyle(theme.text).fontWeight(.semibold)
                        } else {
                            Text("≈ \(Format.bytes(model.batchExpectedSaved)) expected")
                        }
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                }

                if let pause = model.pauseText {
                    Label(pause, systemImage: "pause.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Text("Keep Slash open. The screen stays on while it works. If you leave, it continues when you come back.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)

                if ads.isEnabled && ads.playAdReady {
                    Button { ads.showPlayAd() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "gamecontroller.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Play something while you wait").font(.subheadline.weight(.semibold))
                                Text("Optional ad · compression keeps running").font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                        }
                        .foregroundStyle(Palette.text)
                        .padding(14)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.color, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }

                if ads.isEnabled {
                    VStack(spacing: 4) {
                        Text("Advertisement").font(.caption2).foregroundStyle(Palette.secondary)
                        WorkingAdBanner().frame(width: 300, height: 250)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(Palette.text)
    }

    private func phaseLabel(_ status: ItemStatus) -> String {
        if case .working(let phase, _) = status { return phase.label }
        return String(localized: "Preparing")
    }
}

// MARK: - Result screen after a batch: watch first, then share or delete

struct BatchResultView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let result: LibraryViewModel.BatchResult
    @State private var compare: ShrunkRecord?
    @State private var shareImage: Image?

    private var records: [ShrunkRecord] {
        let ids = Set(result.shrunkIDs)
        return model.shrunk.filter { ids.contains($0.originalID) }
    }
    private var before: Int64 { records.reduce(0) { $0 + $1.inputBytes } }
    private var after: Int64 { records.reduce(0) { $0 + $1.outputBytes } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if result.shrunkIDs.isEmpty {
                    Text("Nothing to save this time").font(.slashDisplay(34)).padding(.top, 20)
                } else {
                    Text("\(result.shrunkIDs.count) videos slashed · ready to free")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                        .padding(.top, 20)
                    Text(Format.bytes(result.savedBytes))
                        .font(.slashNumber(84))
                        .foregroundStyle(theme.text)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    ShrinkBar(before: before, after: after, height: 36)
                    Text("Watch the copies first. They're in your library with the same date, place and albums.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                }
                if result.rejectedCount + result.failedCount > 0 {
                    Text("\(result.rejectedCount + result.failedCount) kept as they are (see “Can't shrink”).")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                }

                // 1. watch
                ForEach(records) { r in
                    Button { compare = r } label: {
                        HStack(spacing: 12) {
                            Thumbnail(asset: PhotoLibraryService.asset(r.copyID), size: 64)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Format.bytes(r.inputBytes)) → \(Format.bytes(r.outputBytes))")
                                    .font(.slashNumber(22))
                                Text(verbatim: "−\(r.savedPercent)%").font(.caption.weight(.bold)).foregroundStyle(theme.text)
                            }
                            Spacer()
                            Label("Compare", systemImage: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14).frame(height: 38)
                                .background(Palette.surface2, in: Capsule())
                                .foregroundStyle(theme.text)
                        }
                        .padding(10)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compareButton")
                }

                // 2. share + 3. delete
                if !result.shrunkIDs.isEmpty {
                    HStack(spacing: 10) {
                        if let image = shareImage {
                            ShareLink(item: image, preview: SharePreview("I freed \(Format.bytes(result.savedBytes)) with Slash", image: image)) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(width: 56, height: 56)
                                    .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .foregroundStyle(Palette.text)
                            }
                            .accessibilityLabel("Share")
                        }
                        Button {
                            Task { await model.deleteOriginals(result.shrunkIDs) }
                        } label: {
                            Text("Delete \(result.shrunkIDs.count) originals")
                        }
                        .buttonStyle(SlashButtonStyle())
                        .accessibilityIdentifier("deleteOriginals")
                    }
                    Text("iOS asks you to confirm. Deleted videos stay in “Recently Deleted” for 30 days.")
                        .font(.caption)
                        .foregroundStyle(Palette.secondary)
                }
                Button { dismiss() } label: {
                    Text("Later").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondary)
            }
            .padding(20)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.background.ignoresSafeArea())
        .sheet(item: $compare) { r in CompareView(originalID: r.originalID, copyID: r.copyID) }
        .task {
            if !result.shrunkIDs.isEmpty {
                shareImage = ShareCard(savedBytes: result.savedBytes, count: result.shrunkIDs.count, theme: theme).render()
            }
        }
    }
}

// MARK: - Access

struct AccessView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            SlashWordmark(size: 40)
            Text("Slash the size. Keep the shot.").font(.slashDisplay(36))
            Text("Slash makes smaller copies of your biggest videos on this iPhone. Nothing is uploaded, and nothing is deleted without your confirmation.")
                .foregroundStyle(Palette.secondary)
            Spacer()
            Button("Allow access to videos") { Task { await model.requestAccess() } }
                .buttonStyle(SlashButtonStyle())
                .accessibilityIdentifier("allowAccess")
        }
        .foregroundStyle(Palette.text)
        .padding(28)
    }
}

struct DeniedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            SlashWordmark()
            Text("No access to your library").font(.slashDisplay(30))
            Text("Allow full access in Settings to find and shrink large videos.")
                .foregroundStyle(Palette.secondary)
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(SlashButtonStyle())
        }
        .foregroundStyle(Palette.text)
        .padding(28)
    }
}
