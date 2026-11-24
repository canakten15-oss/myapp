import Photos
import StoreKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.requestReview) private var requestReview
    @AppStorage("onboarded") private var onboarded = false
    @State private var showSettings = false

    var body: some View {
        if !onboarded && model.authorization == .notDetermined {
            OnboardingView { withAnimation { onboarded = true } }
        } else {
            main
        }
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
            .navigationTitle(model.isRunning ? "" : "Slash")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings")
                        .disabled(model.isRunning)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $model.batchResult) { result in
                BatchResultView(result: result)
                    .presentationDetents([.large])
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
        .tint(.accentColor)
        .onChange(of: model.shouldAskForReview) { _, ask in
            guard ask else { return }
            model.shouldAskForReview = false
            requestReview()
        }
    }
}

// MARK: - Library (three sections)

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var compare: ShrunkRecord?

    var body: some View {
        Group {
            if model.isRunning {
                WorkingView()
            } else {
                listView
                    .safeAreaInset(edge: .bottom) { ActionBar() }
            }
        }
        .task { if model.items.isEmpty { await model.scan() } }
    }

    private var listView: some View {
        List {
            if !model.resumableIDs.isEmpty {
                Section { ResumeCard() }
            }

            Section { OverviewCard() }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Section {
                if model.isScanning && model.items.isEmpty {
                    HStack(spacing: 10) { ProgressView(); Text("Looking for big videos…").foregroundStyle(.secondary) }
                } else if model.items.isEmpty {
                    Text("No videos over \(model.minSizeMB) MB left to shrink.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.items) { item in
                        VideoRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { model.toggle(item) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                            .accessibilityIdentifier("videoRow")
                    }
                }
            } header: {
                HStack {
                    Text("To do · \(model.items.count)")
                    Spacer()
                    if !model.items.isEmpty {
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
                            Label("Select", systemImage: "checklist").labelStyle(.titleAndIcon)
                        }
                        .accessibilityIdentifier("selectMenu")
                    }
                }
                .font(.footnote.weight(.semibold))
            }

            if !model.shrunk.isEmpty {
                Section {
                    ForEach(model.shrunk) { r in
                        Button { compare = r } label: { ShrunkRow(record: r) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("shrunkRow")
                    }
                } header: {
                    Text("Shrunk · \(model.shrunk.count)").font(.footnote.weight(.semibold))
                } footer: {
                    Text("Copies are also in the album “\(PhotoLibraryService.compressedAlbumTitle)”.")
                }
            }

            if !model.rejected.isEmpty {
                Section {
                    ForEach(model.rejected) { RejectedRow(record: $0) }
                } header: {
                    Text("Can't shrink · \(model.rejected.count)").font(.footnote.weight(.semibold))
                } footer: {
                    Text("These would lose visible quality, so the originals were kept. Swipe to try again.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.scan() }
        .sheet(item: $compare) { r in CompareView(originalID: r.originalID, copyID: r.copyID) }
    }
}

/// Library overview, space already freed, and originals waiting to be deleted.
struct OverviewCard: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.allVideosBytes > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your videos").font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.bytes(model.allVideosBytes))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("in \(model.allVideosCount) videos").foregroundStyle(.secondary)
                    }
                    if model.potentialSavings > 0 {
                        Text("Slash could free about \(Format.bytes(model.potentialSavings))")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } else if model.isScanning {
                HStack(spacing: 10) { ProgressView(); Text("Looking at your videos…").foregroundStyle(.secondary) }
            }

            if model.freedBytes > 0 {
                Label("\(Format.bytes(model.freedBytes)) freed so far", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if !model.pendingDeleteIDs.isEmpty {
                Divider()
                Text("\(model.pendingDeleteIDs.count) originals still in your library. Delete them to free \(Format.bytes(model.pendingSavedBytes)).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task { await model.deleteOriginals() }
                } label: {
                    Label("Delete originals", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("deleteOriginalsAll")
            }
        }
        .padding(.vertical, 6)
    }
}

/// Offers to continue a batch that was interrupted.
struct ResumeCard: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(model.resumableIDs.count) videos left from your last run", systemImage: "arrow.clockwise.circle.fill")
                .font(.subheadline.weight(.semibold))
            HStack {
                Button("Continue") { model.resume() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("resumeButton")
                Button("Not now") { model.dismissResume() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Bottom bar: level + live estimate + button, all in one place

struct ActionBar: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 10) {
            Picker("Level", selection: Binding(get: { model.quality }, set: { model.quality = $0 })) {
                ForEach(CompressionQuality.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .firstTextBaseline) {
                if model.selectedItems.isEmpty {
                    Text(model.quality.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("≈ \(Format.bytes(model.estimatedSavings)) saved")
                            .font(.headline)
                            .contentTransition(.numericText())
                        if model.estimatedSavingsOnPhone < model.estimatedSavings {
                            Text(model.estimatedSavingsOnPhone > 0
                                 ? "\(Format.bytes(model.estimatedSavingsOnPhone)) on this iPhone, the rest in iCloud"
                                 : "Frees iCloud storage. These videos are only stored in iCloud.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(model.selectedItems.count) videos · \(Format.bytes(model.selectedBytes)) · \(model.quality.explanation)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .animation(.default, value: model.estimatedSavings)

            Button { model.start() } label: {
                Text(model.selectedItems.isEmpty ? "Select videos to compress"
                     : "Compress \(model.selectedItems.count) videos")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedItems.isEmpty || model.isScanning)
            .accessibilityIdentifier("compressButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

// MARK: - Rows

struct Thumbnail: View {
    let asset: PHAsset?
    var size: CGFloat = 64
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
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

struct VideoRow: View {
    let item: VideoItem

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(asset: item.asset)
                Text(Format.duration(item.asset.duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Format.bytes(item.fileSize)).font(.headline)
                    if !item.isLocal {
                        Image(systemName: "icloud")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Stored in iCloud")
                    }
                }
                if let date = item.asset.creationDate {
                    Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                StatusLine(status: item.status)
            }

            Spacer()

            if !item.status.isFinished {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ShrunkRow: View {
    let record: ShrunkRecord

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(asset: PhotoLibraryService.asset(record.copyID), size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(Format.bytes(record.inputBytes)) → \(Format.bytes(record.outputBytes))").font(.subheadline.weight(.semibold))
                    Text("−\(record.savedPercent)%")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Text(record.originalDeleted ? "\(record.level) · original deleted"
                                            : "\(record.level) · original still in library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if record.originalDeleted {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor).accessibilityLabel("Done")
            } else {
                Image(systemName: "play.circle").font(.title3).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Compare")
            }
        }
        .padding(.vertical, 2)
    }
}

struct RejectedRow: View {
    @EnvironmentObject private var model: LibraryViewModel
    let record: RejectedRecord

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(asset: PhotoLibraryService.asset(record.originalID), size: 52)
                .opacity(0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.bytes(record.fileSize)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(record.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .swipeActions {
            Button("Try again") { model.retry(record) }.tint(.accentColor)
        }
    }
}

struct StatusLine: View {
    let status: ItemStatus

    var body: some View {
        switch status {
        case .pending:
            EmptyView()
        case .working(let phase, let p):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: p)
                Text(phase.label).font(.caption).foregroundStyle(.secondary)
            }
        case .done(let saved):
            Label("Saved \(Format.bytes(saved))", systemImage: "checkmark").font(.caption).foregroundStyle(Color.accentColor)
        case .skipped(let reason):
            Label(reason, systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Working screen (the only place ads ever appear)

struct WorkingView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @ObservedObject private var ads = AdService.shared

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Compressing").font(.title2.bold()).accessibilityIdentifier("workingTitle")
                    Spacer()
                    Text("\(min(model.batchDone + 1, model.batchTotal)) of \(model.batchTotal)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: model.batchProgress)
                    .scaleEffect(x: 1, y: 1.6, anchor: .center)
                    .animation(.linear(duration: 0.3), value: model.batchProgress)

                HStack {
                    Text(model.currentItem.map { phaseLabel($0.status) } ?? "Preparing")
                        .font(.subheadline)
                    Spacer()
                    Text(model.etaText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    if let item = model.currentItem {
                        Label(Format.bytes(item.fileSize), systemImage: "film")
                    }
                    Label("Saved \(Format.bytes(model.lastBatchSaved))", systemImage: "arrow.down.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.footnote.monospacedDigit())

                if let pause = model.pauseText {
                    Label(pause, systemImage: "pause.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Text(Self.backgroundHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            if ads.isEnabled && ads.playAdReady {
                Button { ads.showPlayAd() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "gamecontroller.fill").font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Play something while you wait").font(.subheadline.weight(.semibold))
                            Text("Optional ad · compression keeps running").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if ads.isEnabled {
                VStack(spacing: 4) {
                    Text("Advertisement").font(.caption2).foregroundStyle(.secondary)
                    WorkingAdBanner().frame(width: 300, height: 250)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 24)

            Button(role: .cancel) { model.cancel() } label: {
                Text("Stop").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("stopButton")
        }
        .padding()
    }

    static var backgroundHint: LocalizedStringKey {
        if #available(iOS 26.0, *) {
            return "You can leave Slash. It keeps working and shows its progress on the Lock Screen."
        }
        return "Keep the app open. The screen stays on while this runs."
    }

    private func phaseLabel(_ status: ItemStatus) -> String {
        if case .working(let phase, _) = status { return phase.label }
        return "Preparing"
    }
}

// MARK: - Result screen after a batch: watch first, then share or delete

struct BatchResultView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    let result: LibraryViewModel.BatchResult
    @State private var compare: ShrunkRecord?
    @State private var shareImage: Image?

    private var records: [ShrunkRecord] {
        let ids = Set(result.shrunkIDs)
        return model.shrunk.filter { ids.contains($0.originalID) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: result.shrunkIDs.isEmpty ? "info.circle" : "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(result.shrunkIDs.isEmpty ? Color.secondary : Color.accentColor)
                        .accessibilityHidden(true)

                    if result.shrunkIDs.isEmpty {
                        Text("Nothing to save this time").font(.title2.bold())
                    } else {
                        Text("\(Format.bytes(result.savedBytes)) to free").font(.title.bold())
                        Text("Watch the copies first. They're in your library with the same date, place and albums.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    if result.rejectedCount + result.failedCount > 0 {
                        Text("\(result.rejectedCount + result.failedCount) kept as they are (see “Can't shrink”).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // 1. watch
                    if !records.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(records) { r in
                                Button { compare = r } label: {
                                    HStack(spacing: 12) {
                                        Thumbnail(asset: PhotoLibraryService.asset(r.copyID), size: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(Format.bytes(r.inputBytes)) → \(Format.bytes(r.outputBytes))")
                                                .font(.subheadline.weight(.semibold))
                                            Text("−\(r.savedPercent)%").font(.caption).foregroundStyle(Color.accentColor)
                                        }
                                        Spacer()
                                        Label("Compare", systemImage: "play.circle.fill")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("compareButton")
                                if r.id != records.last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // 2. share
                    if !result.shrunkIDs.isEmpty, let image = shareImage {
                        ShareLink(item: image, preview: SharePreview("I freed \(Format.bytes(result.savedBytes)) with Slash", image: image)) {
                            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    // 3. delete
                    if !result.shrunkIDs.isEmpty {
                        Button(role: .destructive) {
                            Task { await model.deleteOriginals(result.shrunkIDs) }
                        } label: {
                            Text("Delete \(result.shrunkIDs.count) originals")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .accessibilityIdentifier("deleteOriginals")
                        Text("iOS asks you to confirm. Deleted videos stay in “Recently Deleted” for 30 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("Later") { dismiss() }
                        .controlSize(.large)
                }
                .padding(24)
            }
        }
        .sheet(item: $compare) { r in CompareView(originalID: r.originalID, copyID: r.copyID) }
        .task {
            if !result.shrunkIDs.isEmpty {
                shareImage = ShareCard(savedBytes: result.savedBytes, count: result.shrunkIDs.count).render()
            }
        }
    }
}

// MARK: - Access

struct AccessView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Slash the size. Keep the shot.").font(.title2.bold()).multilineTextAlignment(.center)
            Text("Slash makes smaller copies of your biggest videos on this iPhone. Nothing is uploaded, and nothing is deleted without your confirmation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Allow access to videos") { Task { await model.requestAccess() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("allowAccess")
        }
        .padding(32)
    }
}

struct DeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("No access to your library").font(.title3.bold())
            Text("Allow full access in Settings to find and shrink large videos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
