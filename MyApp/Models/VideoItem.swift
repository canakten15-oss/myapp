import Foundation
import Photos

/// What the app is doing with one video right now. Shown as a label under the progress bar.
enum WorkPhase: String, Equatable {
    case downloading, testing, compressing, retrying, finishing, checking, saving

    var label: String {
        switch self {
        case .downloading: return "Downloading from iCloud"
        case .testing: return "Quick test on a short piece"
        case .compressing: return "Compressing"
        case .retrying: return "Second try at higher quality"
        case .finishing: return "Finishing file"
        case .checking: return "Checking quality"
        case .saving: return "Saving to Photos"
        }
    }
}

enum ItemStatus: Equatable {
    case pending
    /// progress = this video's overall progress 0...1 (never goes backwards)
    case working(WorkPhase, Double)
    case done(savedBytes: Int64)
    case skipped(String)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .done, .skipped, .failed: return true
        default: return false
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
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

/// A video that was shrunk successfully. Persisted, so it stays in the "Shrunk" section.
struct ShrunkRecord: Codable, Identifiable, Equatable {
    var id: String { originalID }
    let originalID: String
    let copyID: String
    let inputBytes: Int64
    let outputBytes: Int64
    let level: String
    let date: Date
    var originalDeleted: Bool = false

    var savedBytes: Int64 { inputBytes - outputBytes }
    var savedPercent: Int { inputBytes > 0 ? 100 - Int(outputBytes * 100 / inputBytes) : 0 }
}

/// A video that could not be shrunk without visible loss. Persisted, so nobody repeats a long attempt.
struct RejectedRecord: Codable, Identifiable, Equatable {
    var id: String { originalID }
    let originalID: String
    let fileSize: Int64
    let level: String
    let reason: String
    let date: Date
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
        case .maxSavings: return "Smallest files. No visible difference on the phone."
        case .bestQuality: return "Indistinguishable, even on a big TV. Saves less."
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

    /// Minimum similarity (SSIM on luma at FULL resolution, frame-matched) between original and copy.
    /// Below this the rung is rejected; if all rungs fail, the original is kept.
    /// Benchmark: full-res SSIM 0.975 ≈ VMAF 92, 0.946 ≈ VMAF 84, 0.902 ≈ VMAF 67.
    /// Real iPhone tests (v0.7): accepted copies measured 0.976–0.983.
    var minSSIM: Double {
        switch self {
        case .maxSavings: return 0.95
        case .bestQuality: return 0.97
        }
    }

    /// Share of space saved on typical iPhone videos (for the estimate only).
    /// From the v0.7 iPhone test: Max savings −65%, Best quality −45/−46%.
    var typicalSavings: Double {
        switch self {
        case .maxSavings: return 0.60
        case .bestQuality: return 0.45
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

    /// "~4 min left", "~45 s left"
    static func eta(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded()), 1)
        if s < 60 { return "~\(s) s left" }
        let m = Int((Double(s) / 60).rounded())
        return m < 60 ? "~\(m) min left" : "~\(m / 60) h \(m % 60) min left"
    }
}

enum AppError: LocalizedError {
    case loadFailed, noVideoTrack, notEnoughSpace(needed: Int64)
    case writerFailed(String), verifyFailed(String), qualityTooLow(Double)

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "Could not load the original video"
        case .noVideoTrack: return "No video track found"
        case .notEnoughSpace(let n): return "Needs \(Format.bytes(n)) free space"
        case .writerFailed(let m): return "Encoding failed: \(m)"
        case .verifyFailed(let m): return m
        case .qualityTooLow(let s): return String(format: "Can't shrink without visible loss (%.0f%% similar)", s * 100)
        }
    }
}

/// Mutable reference used inside escaping/@Sendable callbacks.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
