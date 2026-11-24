import AVKit
import Photos
import SwiftUI

/// Watch the copy before deleting anything. "Original ↔ Copy" jumps between both at the same moment.
struct CompareView: View {
    let originalID: String
    let copyID: String
    @Environment(\.dismiss) private var dismiss

    @StateObject private var players = ComparePlayers()
    @State private var showingOriginal = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    Color.black
                    if let player = showingOriginal ? players.original : players.copy {
                        VideoPlayer(player: player)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if players.originalMissing {
                    Text("The original is already deleted. You're watching the copy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Show", selection: Binding(
                        get: { showingOriginal },
                        set: { players.switchTo(original: $0); showingOriginal = $0 }
                    )) {
                        Text("Copy").tag(false)
                        Text("Original").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compareSwitch")
                    Text("Pause and switch to compare the same moment. Pinch to zoom.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await players.load(originalID: originalID, copyID: copyID) }
        .onDisappear { players.stop() }
    }
}

@MainActor
final class ComparePlayers: ObservableObject {
    @Published var copy: AVPlayer?
    @Published var original: AVPlayer?
    @Published var originalMissing = false
    private var active: AVPlayer? { showingOriginal ? original : copy }
    private var showingOriginal = false

    func load(originalID: String, copyID: String) async {
        if let c = PhotoLibraryService.asset(copyID), let item = await Self.playerItem(for: c) {
            copy = AVPlayer(playerItem: item)
            copy?.play()
        }
        if let o = PhotoLibraryService.asset(originalID), let item = await Self.playerItem(for: o) {
            original = AVPlayer(playerItem: item)
        } else {
            originalMissing = true
        }
    }

    /// Hands over position and play state, so both show the same moment.
    func switchTo(original wantOriginal: Bool) {
        guard let from = active, let to = wantOriginal ? original : copy, from !== to else { return }
        let playing = from.rate > 0
        from.pause()
        to.seek(to: from.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        if playing { to.play() }
        showingOriginal = wantOriginal
    }

    func stop() {
        copy?.pause()
        original?.pause()
    }

    private static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { cont in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                cont.resume(returning: item)
            }
        }
    }
}
