import AVFoundation
import Photos
import XCTest
@testable import MyApp

/// Encoder + quality check on real video files (Fixtures/).
final class CompressorTests: XCTestCase {

    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mov"), "missing fixture \(name)")
    }

    func bytes(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Copy of a fixture with iPhone-style QuickTime metadata (GPS, make, model, date).
    /// ffmpeg writes its tags where AVFoundation reads them as iTunes tags, so add them the Apple way.
    func iPhoneStyle(_ name: String) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-iphone-\(UUID().uuidString).mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: try fixture(name)),
                                                         presetName: AVAssetExportPresetPassthrough))
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            return m
        }
        session.metadata = [
            item(.quickTimeMetadataLocationISO6709, "+53.5511+009.9937+010.000/"),
            item(.quickTimeMetadataMake, "Apple"),
            item(.quickTimeMetadataModel, "iPhone 16 Pro"),
            item(.quickTimeMetadataCreationDate, "2026-08-01T12:00:00+0200"),
        ]
        try await session.export(to: out, as: .mov)
        return out
    }

    func compress(_ name: String, _ quality: CompressionQuality, qualityMode: Bool = true,
                  file: StaticString = #filePath, line: UInt = #line) async throws -> (VideoCompressor.Result, AVURLAsset) {
        let src = name == "sdr_1080p" ? try await iPhoneStyle(name) : try fixture(name)
        let compressor = VideoCompressor()
        compressor.preferQualityMode = qualityMode
        let outcome = try await compressor.compress(
            asset: AVURLAsset(url: src), originalBytes: bytes(src), quality: quality, progress: { _ in })
        guard case .compressed(let result) = outcome else {
            XCTFail("\(name) was skipped as already efficient", file: file, line: line)
            throw XCTSkip("no output")
        }
        print("[TEST] \(name) \(quality.label) mode=\(result.usedQualityMode ? "quality" : "bitrate") "
              + "\(result.inputBytes) -> \(result.outputBytes) bytes "
              + "(\(100 - result.outputBytes * 100 / max(result.inputBytes, 1))% smaller) ssim=\(String(format: "%.4f", result.similarity))")
        return (result, AVURLAsset(url: result.url))
    }

    func testSDRBothLevels() async throws {
        for q in CompressionQuality.allCases {
            let (r, out) = try await compress("sdr_1080p", q)
            defer { try? FileManager.default.removeItem(at: r.url) }

            XCTAssertLessThan(r.outputBytes, r.inputBytes * 8 / 10, "not ≥20% smaller")
            XCTAssertGreaterThanOrEqual(r.similarity, q.minSSIM)

            let track = try await XCTUnwrapAsync(try await out.loadTracks(withMediaType: .video).first)
            let format = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC, "not HEVC")

            let srcDur = try await AVURLAsset(url: fixture("sdr_1080p")).load(.duration).seconds
            let outDur = try await out.load(.duration).seconds
            XCTAssertEqual(outDur, srcDur, accuracy: 0.1, "duration changed")

            let audio = try await out.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1, "audio track lost")

            let meta = try await out.load(.metadata)
            let ids = meta.compactMap { $0.identifier?.rawValue }
            XCTAssertTrue(ids.contains { $0.contains("location.ISO6709") }, "GPS lost. Metadata: \(ids)")
            XCTAssertTrue(ids.contains { $0.contains("quicktime.model") }, "camera model lost. Metadata: \(ids)")
        }
    }

    func testFallbackBitrateMode() async throws {
        let (r, _) = try await compress("sdr_1080p", .bestQuality, qualityMode: false)
        defer { try? FileManager.default.removeItem(at: r.url) }
        XCTAssertFalse(r.usedQualityMode)
        XCTAssertLessThan(r.outputBytes, r.inputBytes * 8 / 10)
    }

    func testHDRStaysHDR() async throws {
        let srcTrack = try await XCTUnwrapAsync(
            try await AVURLAsset(url: fixture("hdr_hlg")).loadTracks(withMediaType: .video).first)
        let srcHDR = try await srcTrack.load(.mediaCharacteristics).contains(.containsHDRVideo)
        XCTAssertTrue(srcHDR, "fixture not detected as HDR - test setup problem")

        let (r, out) = try await compress("hdr_hlg", .bestQuality)
        defer { try? FileManager.default.removeItem(at: r.url) }
        let track = try await XCTUnwrapAsync(try await out.loadTracks(withMediaType: .video).first)
        let chars = try await track.load(.mediaCharacteristics)
        XCTAssertTrue(chars.contains(.containsHDRVideo), "HDR lost")
        let format = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        XCTAssertEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    func testPortraitOrientationKept() async throws {
        let srcTrack = try await XCTUnwrapAsync(
            try await AVURLAsset(url: fixture("portrait")).loadTracks(withMediaType: .video).first)
        let srcT = try await srcTrack.load(.preferredTransform)
        XCTAssertNotEqual(srcT, .identity, "fixture has no rotation - test setup problem")

        let (r, out) = try await compress("portrait", .bestQuality)
        defer { try? FileManager.default.removeItem(at: r.url) }
        let track = try await XCTUnwrapAsync(try await out.loadTracks(withMediaType: .video).first)
        let t = try await track.load(.preferredTransform)
        XCTAssertEqual(t, srcT, "orientation changed")
    }

    // MARK: quality check

    func testQualityCheckScores() async throws {
        let src = AVURLAsset(url: try fixture("sdr_1080p"))
        let same = try await XCTUnwrapAsync(await QualityCheck.similarity(original: src, compressed: src))
        XCTAssertGreaterThan(same, 0.999, "identical video should score ~1")

        // A heavily degraded copy must fail both thresholds
        let bad = try await degradedCopy(of: try fixture("sdr_1080p"))
        defer { try? FileManager.default.removeItem(at: bad) }
        let score = try await XCTUnwrapAsync(await QualityCheck.similarity(original: src, compressed: AVURLAsset(url: bad)))
        print("[TEST] degraded ssim=\(score)")
        XCTAssertLessThan(score, CompressionQuality.maxSavings.minSSIM, "quality check did not catch a bad copy")
    }

    /// Produces a visibly bad copy (lowest export preset = tiny resolution, upscaled on compare).
    func degradedCopy(of url: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetLowQuality))
        try await session.export(to: out, as: .mov)
        return out
    }
}

/// XCTUnwrap for async contexts.
func XCTUnwrapAsync<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}
