import Foundation
import Photos

enum ItemStatus: Equatable {
    case pending
    case downloading(Double)
    case compressing(Double)
    case saving
    case done(savedBytes: Int64)
    case skipped(String)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .done, .skipped, .failed: return true
        default: return false
        }
    }
}

struct VideoItem: Identifiable, Equatable {
    var id: String { asset.localIdentifier }
    let asset: PHAsset
    let fileSize: Int64
    var isSelected: Bool = false   // user picks; nothing is pre-selected
    var status: ItemStatus = .pending

    static func == (lhs: VideoItem, rhs: VideoItem) -> Bool {
        lhs.id == rhs.id && lhs.isSelected == rhs.isSelected && lhs.status == rhs.status
    }
}

/// The two compression levels the user chooses between before each batch.
enum CompressionQuality: String, CaseIterable, Identifiable {
    case maxSavings, bestQuality
    var id: String { rawValue }

    var label: String {
        switch self {
        case .maxSavings: return "Max savings"
        case .bestQuality: return "Best quality"
        }
    }

    var explanation: String {
        switch self {
        case .maxSavings: return "Smallest files. Looks great on a phone, slight softness possible in fast motion on a big TV."
        case .bestQuality: return "Hard to tell apart from the original, even on a TV. Saves less space."
        }
    }

    /// Bitrate ladder as a share of the source bitrate: first rung, then one retry if the
    /// quality check fails. Calibrated with the real-footage benchmark (bench.yml).
    var bitrateRatios: [Double] {
        switch self {
        case .maxSavings: return [0.35, 0.50]
        case .bestQuality: return [0.55, 0.70]
        }
    }

    /// Bits per pixel per frame, used only when the source bitrate is unknown.
    var fallbackBPP: [Double] {
        switch self {
        case .maxSavings: return [0.035, 0.05]
        case .bestQuality: return [0.055, 0.07]
        }
    }

    /// Minimum similarity (SSIM on luma at FULL resolution, 10 frames) between original and copy.
    /// Below this the rung is rejected; if all rungs fail, the original is kept.
    /// Benchmark: full-res SSIM 0.975 ≈ VMAF 92, 0.946 ≈ VMAF 84, 0.902 ≈ VMAF 67.
    var minSSIM: Double {
        switch self {
        case .maxSavings: return 0.95
        case .bestQuality: return 0.97
        }
    }

    /// Rough share of space saved on typical iPhone videos (for the estimate only).
    var typicalSavings: Double {
        switch self {
        case .maxSavings: return 0.65
        case .bestQuality: return 0.4
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        n <= 0 ? "0 MB" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum AppError: LocalizedError {
    case loadFailed, noVideoTrack, notEnoughSpace, writerFailed(String), verifyFailed(String), qualityTooLow(Double)

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "Could not load the original video"
        case .noVideoTrack: return "No video track found"
        case .notEnoughSpace: return "Not enough free space on this device"
        case .writerFailed(let m): return "Encoding failed: \(m)"
        case .verifyFailed(let m): return m
        case .qualityTooLow(let s): return String(format: "Quality check failed (%.0f%% similar), original kept", s * 100)
        }
    }
}

/// Mutable reference used inside escaping/@Sendable callbacks.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
