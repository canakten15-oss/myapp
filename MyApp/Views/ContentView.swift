import Photos
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var showSettings = false

    var body: some View {
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
                    .presentationDetents([.medium])
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
    }
}

// MARK: - Library (three sections)

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryViewModel

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
            if model.freedBytes > 0 || !model.pendingDeleteIDs.isEmpty {
                Section { OverviewCard() }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

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
                        Button("All") { model.setAll(selected: true) }
                        Text("·").foregroundStyle(.tertiary)
                        Button("None") { model.setAll(selected: false) }
                    }
                }
                .font(.footnote.weight(.semibold))
            }

            if !model.shrunk.isEmpty {
                Section {
                    ForEach(model.shrunk) { ShrunkRow(record: $0) }
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
    }
}

/// Space already saved, and originals waiting to be deleted.
struct OverviewCard: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.freedBytes > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.bytes(model.freedBytes))
                        .font(.system(.title, design: .rounded).weight(.bold))
                    Text("freed so far").foregroundStyle(.secondary)
                }
            }
            if !model.pendingDeleteIDs.isEmpty {
                Text("\(model.pendingDeleteIDs.count) original\(model.pendingDeleteIDs.count == 1 ? "" : "s") still in your library. Delete \(model.pendingDeleteIDs.count == 1 ? "it" : "them") to free \(Format.bytes(model.pendingSavedBytes)).")
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
                        Text("\(model.selectedItems.count) video\(model.selectedItems.count == 1 ? "" : "s") · \(Format.bytes(model.selectedBytes)) · \(model.quality.explanation)")
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
                     : "Compress \(model.selectedItems.count) video\(model.selectedItems.count == 1 ? "" : "s")")
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
                Text(Format.bytes(item.fileSize)).font(.headline)
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

                Text("Keep the app open. The screen stays on while this runs.")
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

    private func phaseLabel(_ status: ItemStatus) -> String {
        if case .working(let phase, _) = status { return phase.label }
        return "Preparing"
    }
}

// MARK: - Result screen after a batch

struct BatchResultView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    let result: LibraryViewModel.BatchResult

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: result.shrunkIDs.isEmpty ? "info.circle" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(result.shrunkIDs.isEmpty ? Color.secondary : Color.accentColor)

            if result.shrunkIDs.isEmpty {
                Text("Nothing to save this time").font(.title2.bold())
            } else {
                Text("\(Format.bytes(result.savedBytes)) to free").font(.title.bold())
                Text("\(result.shrunkIDs.count) video\(result.shrunkIDs.count == 1 ? "" : "s") shrunk. The copies are in your library with the same date, place and albums.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if result.rejectedCount + result.failedCount > 0 {
                Text("\(result.rejectedCount + result.failedCount) kept as they are (see “Can't shrink”).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if !result.shrunkIDs.isEmpty {
                Button(role: .destructive) {
                    Task { await model.deleteOriginals(result.shrunkIDs) }
                } label: {
                    Text("Delete \(result.shrunkIDs.count) original\(result.shrunkIDs.count == 1 ? "" : "s")")
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
