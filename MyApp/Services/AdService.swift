import SwiftUI
import UIKit

#if canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
import AppTrackingTransparency
import GoogleMobileAds
import UserMessagingPlatform
#endif

/// Ad policy of this app (do not change without good reason):
///  - Ads appear ONLY while a compression batch is running, on the working screen.
///  - Default: one 300x250 banner under the progress panel.
///  - Optional: a "Play something while you wait" button. ONLY when the user taps it,
///    a full-screen ad opens (video switched off in the AdMob console -> playables/display).
///    Compression keeps running behind it.
///  - Never an automatic full-screen ad, never before a job, never after a job.
///  - Everything disappears the moment the batch ends or is stopped.
///
/// Ads are compiled in only when the Google packages are added (see docs/MONETIZATION.md).
/// Without them `isEnabled` stays false and no ad slot is shown at all.
@MainActor
final class AdService: NSObject, ObservableObject {
    static let shared = AdService()

    /// Google's official TEST units. Replace with your own unit IDs for release.
    static let bannerUnitID = "ca-app-pub-3940256099942544/2435281174"
    static let playUnitID = "ca-app-pub-3940256099942544/4411468910"   // interstitial unit, video OFF in console

    @Published private(set) var isEnabled = false
    /// True when an opt-in full-screen ad is loaded and a batch is running.
    @Published private(set) var playAdReady = false
    private var batchRunning = false

    #if canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
    func start() async {
        // 1. GDPR/consent form (shown only where required, e.g. EU)
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
        } catch {
            print("Consent error: \(error.localizedDescription)")
        }
        guard ConsentInformation.shared.canRequestAds else { return }

        // 2. Apple tracking prompt (only affects personalization; ads work either way)
        _ = await ATTrackingManager.requestTrackingAuthorization()

        // 3. Start SDK
        _ = await MobileAds.shared.start()
        isEnabled = true
    }

    // MARK: opt-in full-screen ("Play something while you wait")

    private var playAd: InterstitialAd?

    func batchStarted() {
        batchRunning = true
        Task { await loadPlayAd() }
    }

    func batchEnded() {
        batchRunning = false
        playAd = nil
        playAdReady = false
    }

    private func loadPlayAd() async {
        guard isEnabled, batchRunning, playAd == nil else { return }
        do {
            let ad = try await InterstitialAd.load(with: Self.playUnitID, request: Request())
            ad.fullScreenContentDelegate = self
            guard batchRunning else { return }   // batch finished while loading: drop it
            playAd = ad
            playAdReady = true
        } catch {
            playAdReady = false
        }
    }

    /// Called ONLY from the user's tap on the opt-in button.
    func showPlayAd() {
        guard batchRunning, let ad = playAd, let root = Self.rootViewController() else { return }
        playAd = nil
        playAdReady = false
        ad.present(from: root)
    }

    private func playAdClosed() {
        // offer another one only while the batch is still running
        Task { await loadPlayAd() }
    }

    /// Lets users change their consent later (required by GDPR when ads are enabled).
    func showPrivacyOptions() async {
        guard let root = Self.rootViewController() else { return }
        try? await ConsentForm.presentPrivacyOptionsForm(from: root)
    }
    #else
    func start() async {}
    func showPrivacyOptions() async {}
    func batchStarted() {}
    func batchEnded() {}
    func showPlayAd() {}
    #endif

    static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}

#if canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
extension AdService: FullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in AdService.shared.playAdClosed() }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in AdService.shared.playAdClosed() }
    }
}
#endif

// MARK: - Banner view (300x250, image or muted video)

#if canImport(GoogleMobileAds) && canImport(UserMessagingPlatform)
struct WorkingAdBanner: UIViewRepresentable {
    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeMediumRectangle)
        banner.adUnitID = AdService.bannerUnitID
        banner.rootViewController = AdService.rootViewController()
        // Loaded only when the view appears on screen (no preloading of banners).
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}
#else
struct WorkingAdBanner: View {
    var body: some View { EmptyView() }
}
#endif
