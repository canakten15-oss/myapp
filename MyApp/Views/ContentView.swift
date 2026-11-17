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
            .navigationTitle("MyApp")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("settings")
                        .disabled(model.isRunning)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Info", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        Group {
            if model.isRunning {
                WorkingView()
            } else {
                listView
            }
        }
        .safeAreaInset(edge: .bottom) { ActionBar() }
    }

    private var listView: some View {
        List {
            Section {
                SummaryCard()
            }

            if model.pendingDeleteIDs.count > 0 && !model.isRunning {
                Section {
                    DeleteOriginalsCard()
                }
            }

            Section {
                if model.isScanning {
                    HStack { ProgressView(); Text("Scanning library...").foregroundStyle(.secondary) }
                } else if model.items.isEmpty {
                    Text("No videos over \(model.minSizeMB) MB that can be compressed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.items) { item in
                        VideoRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { if !model.isRunning { model.toggle(item) } }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                            .accessibilityIdentifier("videoRow")
                    }
                }
            } header: {
                HStack {
                    Text("Biggest videos")
                    Spacer()
                    if !model.isRunning && !model.items.isEmpty {
                        Button("All") { model.setAll(selected: true) }.font(.caption)
                        Button("None") { model.setAll(selected: false) }.font(.caption)
                    }
                }
            }
        }
        .refreshable { await model.scan() }
        .task { if model.items.isEmpty { await model.scan() } }
    }
}

// MARK: - Working screen (the only place ads ever appear)

struct WorkingView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @ObservedObject private var ads = AdService.shared

    var body: some View {
        VStack(spacing: 16) {
            // --- progress panel (real app content)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Compressing").font(.headline).accessibilityIdentifier("workingTitle")
                    Spacer()
                    Text("\(min(model.batchDone + 1, model.batchTotal)) of \(model.batchTotal)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: model.batchProgress)
                    .tint(.accentColor)

                if let item = model.currentItem {
                    HStack(spacing: 8) {
                        StatusLine(status: item.status)
                        Spacer()
                        Text(Format.bytes(item.fileSize))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        Label("Saved \(Format.bytes(model.lastBatchSaved))", systemImage: "arrow.down.circle")
                            .foregroundStyle(.green)
                        Spacer()
                        if let left = model.timeRemaining {
                            Text("~\(Format.duration(left)) left")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote.monospacedDigit())
                }

                Text("Keep the app open. Your screen won't turn off while this runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

            // --- opt-in full-screen ad: only on the user's tap
            if ads.isEnabled && ads.playAdReady {
                Button { ads.showPlayAd() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gamecontroller.fill").font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Play something while you wait").font(.subheadline.weight(.semibold))
                            Text("Optional ad · compression keeps running").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            // --- banner slot: fixed position, labelled, never covers content
            if ads.isEnabled {
                VStack(spacing: 4) {
                    Text("Advertisement")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WorkingAdBanner()
                        .frame(width: 300, height: 250)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 24)   // keeps distance between ad and the Stop button
        }
        .padding()
    }
}

struct SummaryCard: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRunning {
                Text("Working - keep the app open").font(.headline)
                Text("Saved so far: \(Format.bytes(model.lastBatchSaved))")
                    .foregroundStyle(.secondary)
            } else {
                if model.selectedItems.isEmpty {
                    Text("Tap the videos you want to shrink").font(.headline)
                    Text("Nothing happens until you press Compress.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(model.selectedItems.count) videos selected · \(Format.bytes(model.selectedBytes))")
                        .font(.headline)
                    Text("Estimated space saved: ~\(Format.bytes(model.estimatedSavings))")
                        .foregroundStyle(.secondary)
                }
            }
            if model.totalSavedBytes > 0 {
                Text("Total saved with MyApp: \(Format.bytes(Int64(model.totalSavedBytes)))")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeleteOriginalsCard: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.pendingDeleteIDs.count) originals ready to delete")
                .font(.headline)
            Text("Smaller copies are saved with the same date, place, favorite and albums. Deleting the originals frees \(Format.bytes(model.pendingDeleteBytes)). They stay in Recently Deleted for 30 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                Task { await model.deleteOriginals() }
            } label: {
                Label("Delete originals", systemImage: "trash")
            }
            .accessibilityIdentifier("deleteOriginals")
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.vertical, 4)
    }
}

struct ActionBar: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 8) {
            if model.isRunning {
                Button(role: .cancel) { model.cancel() } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("stopButton")
                .buttonStyle(.bordered)
            } else {
                Picker("Compression", selection: Binding(
                    get: { model.quality },
                    set: { model.quality = $0 }
                )) {
                    ForEach(CompressionQuality.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(model.quality.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button { model.start() } label: {
                    Text(model.selectedItems.isEmpty
                         ? "Select videos to compress"
                         : "Compress \(model.selectedItems.count) videos").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("compressButton")
                .disabled(model.selectedItems.isEmpty || model.isScanning)
            }
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }
}

// MARK: - Row

struct VideoRow: View {
    let item: VideoItem
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(Format.duration(item.asset.duration))
                    .font(.caption2.monospacedDigit())
                    .padding(2)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }

            VStack(alignment: .leading, spacing: 4) {
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
                    .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
            }
        }
        .onAppear {
            PhotoLibraryService.thumbnail(for: item.asset, size: CGSize(width: 160, height: 160)) {
                thumbnail = $0
            }
        }
    }
}

struct StatusLine: View {
    let status: ItemStatus

    var body: some View {
        switch status {
        case .pending:
            EmptyView()
        case .downloading(let p):
            ProgressView("Downloading from iCloud", value: p).font(.caption)
        case .compressing(let p) where p >= 1:
            Text("Checking quality...").font(.caption).foregroundStyle(.secondary)
        case .compressing(let p):
            ProgressView("Compressing \(Int(p * 100))%", value: p).font(.caption)
        case .saving:
            Text("Saving...").font(.caption).foregroundStyle(.secondary)
        case .done(let saved):
            Label("Saved \(Format.bytes(saved))", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        case .skipped(let reason):
            Label(reason, systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Access

struct AccessView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Shrink your videos, keep your memories").font(.title2.bold()).multilineTextAlignment(.center)
            Text("MyApp makes smaller copies of your biggest videos on this iPhone. Nothing is uploaded, and nothing is deleted without your confirmation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Allow access to videos") { Task { await model.requestAccess() } }
                .accessibilityIdentifier("allowAccess")
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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
