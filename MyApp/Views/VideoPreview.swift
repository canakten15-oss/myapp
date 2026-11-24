import AVFoundation
import Photos
import SwiftUI

/// Muted, looping preview inside a tile. Only for videos already on the phone
/// (never downloads from iCloud), and only one plays at a time.
struct VideoPreview: View {
    let asset: PHAsset
    @StateObject private var loader = PreviewLoader()

    var body: some View {
        PlayerLayerView(player: loader.player)
            .opacity(loader.ready ? 1 : 0)
            .animation(.easeIn(duration: 0.25), value: loader.ready)
            .onAppear { loader.load(asset) }
            .onDisappear { loader.stop() }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
final class PreviewLoader: ObservableObject {
    let player = AVQueuePlayer()
    @Published var ready = false
    private var looper: AVPlayerLooper?
    private var request: PHImageRequestID?
    private var observation: NSKeyValueObservation?

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func load(_ asset: PHAsset) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        request = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, _ in
            guard let item else { return }
            Task { @MainActor in
                guard let self else { return }
                // start a bit into the video, it is usually more interesting than the first frame
                let start = CMTime(seconds: min(asset.duration * 0.3, 8), preferredTimescale: 600)
                let end = CMTime(seconds: min(asset.duration, start.seconds + 6), preferredTimescale: 600)
                self.looper = AVPlayerLooper(player: self.player, templateItem: item,
                                             timeRange: CMTimeRange(start: start, end: end))
                self.observation = self.player.observe(\.timeControlStatus) { p, _ in
                    Task { @MainActor in if p.timeControlStatus == .playing { self.ready = true } }
                }
                self.player.play()
            }
        }
    }

    func stop() {
        if let request { PHImageManager.default().cancelImageRequest(request) }
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
        looper = nil
        observation = nil
        ready = false
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
