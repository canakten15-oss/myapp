import Foundation
import UIKit

/// Keeps long batches from harming the phone: pauses between videos while the iPhone is
/// too hot or the battery is low and not charging, and resumes on its own.
@MainActor
enum SafetyMonitor {

    enum PauseReason: Equatable {
        case hot, lowBattery

        var label: String {
            switch self {
            case .hot: return String(localized: "Paused: your iPhone is warm. Continues when it has cooled down.")
            case .lowBattery: return String(localized: "Paused: battery below 20%. Plug in your charger to continue.")
            }
        }
    }

    static func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// nil = safe to work.
    static var pauseReason: PauseReason? {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return .hot }
        let device = UIDevice.current
        if device.isBatteryMonitoringEnabled,
           device.batteryLevel >= 0, device.batteryLevel < 0.2,
           device.batteryState == .unplugged {
            return .lowBattery
        }
        return nil
    }

    /// Waits until it is safe to continue. `onPause` reports the reason (or nil when it continues).
    static func waitUntilSafe(onPause: (PauseReason?) -> Void) async {
        guard var reason = pauseReason else { return }
        onPause(reason)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let r = pauseReason else { break }
            if r != reason { reason = r; onPause(r) }
        }
        onPause(nil)
    }
}
