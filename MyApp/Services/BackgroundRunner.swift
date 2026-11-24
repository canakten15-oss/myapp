import AVFoundation
import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Keeps a batch running when the user leaves the app (iOS 26 "continued processing"):
/// iOS shows its own progress (Dynamic Island / Lock Screen) and the user can stop it there.
/// On older iOS the app must stay open, as before.
/// Also: a local notification when a batch finishes in the background, and the finish sound/haptic.
@MainActor
final class BackgroundRunner {
    static let shared = BackgroundRunner()

    private var registered = false
    private var task: AnyObject?            // BGContinuedProcessingTask (iOS 26+)
    var onExpire: (() -> Void)?             // called when iOS stops the background work

    private var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "app.slash") + ".batch"
    }

    // MARK: background task

    /// Call when a batch starts. Silently does nothing where unsupported.
    func batchStarted(total: Int) {
        guard #available(iOS 26.0, *) else { return }
        registerIfNeeded()
        let request = BGContinuedProcessingTaskRequest(
            identifier: "\(identifierPrefix).\(UUID().uuidString)",
            title: String(localized: "Slash is compressing"),
            subtitle: String(localized: "\(total) videos")
        )
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[background] submit failed: \(error.localizedDescription)")
        }
    }

    /// Progress 0...1 for the system's progress display.
    func update(progress: Double, subtitle: String) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(min(max(progress, 0), 1) * 1000)
        task.updateTitle(String(localized: "Slash is compressing"), subtitle: subtitle)
    }

    func batchEnded(success: Bool) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.setTaskCompleted(success: success)
        self.task = nil
    }

    @available(iOS 26.0, *)
    private func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "\(identifierPrefix).*", using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                self?.task = task
                task.expirationHandler = { [weak self] in
                    // Only stop the work if Slash is really in the background. While the app is open,
                    // the batch keeps running in the foreground even if iOS ends the background task.
                    Task { @MainActor in
                        guard let self else { return }
                        self.task = nil
                        if UIApplication.shared.applicationState == .background { self.onExpire?() }
                    }
                }
            }
        }
    }

    // MARK: notification

    func requestNotificationPermissionIfNeeded() {
        guard #available(iOS 26.0, *) else { return }   // only useful when work continues in the background
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyFinishedIfInBackground(savedBytes: Int64, count: Int) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Done: \(Format.bytes(savedBytes)) to free")
        content.body = String(localized: "\(count) videos shrunk. Open Slash to compare and delete the originals.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "batch-finished", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: finish sound + haptic

    private var player: AVAudioPlayer?

    func playFinished() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard UIApplication.shared.applicationState == .active,
              let url = Bundle.main.url(forResource: "done", withExtension: "wav") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)   // respects the silent switch
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.6
        player?.play()
    }
}
