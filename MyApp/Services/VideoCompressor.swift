import AVFoundation
import CoreMedia
import VideoToolbox

/// Re-encodes a video to HEVC on the device's hardware encoder.
/// Keeps HDR (HLG/PQ, 10-bit), orientation, frame timing, metadata (date, GPS, camera)
/// and stereo/AAC audio. Unsupported audio tracks (e.g. spatial audio) are dropped.
final class VideoCompressor {

    struct Result {
        let url: URL
        let inputBytes: Int64
        let outputBytes: Int64
        let droppedAudioTracks: Int
        /// 0 = first rung of the ladder, 1 = retried at a higher bitrate
        let rung: Int
        let bitrate: Int
        let similarity: Double
        let isHDR: Bool
    }

    enum Outcome {
        case compressed(Result)
        case alreadyEfficient
    }

    /// Progress events for the UI. Fractions are 0...1 within that step.
    enum Event {
        case probing(Double)
        case encoding(rung: Int, Double)
        case finishing
        case checking
    }

    /// Only accept the result if it is at most this fraction of the original size.
    var maxSizeRatio = 0.8
    /// Discard copies below the quality threshold (off only for benchmarks that inspect every result).
    var enforceQualityCheck = true
    /// Test a short piece first to skip rungs (or the whole video) that can't pass.
    var useProbe = true

    /// Every attempt of the last compress() call, for the test report ("probe r1 0.981", "r1 0.968 ✗" …).
    private(set) var attempts: [String] = []
    /// Source facts of the last compress() call, for the test report.
    private(set) var sourceInfo = ""

    /// Sources below this many bits per pixel per frame are already efficient (e.g. messenger videos).
    static let efficientSourceBPP = 0.05
    static let probeSeconds = 3.0

    /// Bitrate ladder: try the smallest rung first; if the quality check fails,
    /// retry one rung up; if every rung fails, the original is kept.
    /// With useProbe, a 3-second piece from the middle is tested first, so rungs that
    /// can't pass are skipped without encoding the whole video.
    func compress(
        asset: AVAsset,
        originalBytes: Int64,
        quality: CompressionQuality,
        progress: @escaping (Event) -> Void
    ) async throws -> Outcome {
        attempts = []
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AppError.noVideoTrack }
        let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
        let dataRate = try await track.load(.estimatedDataRate)
        let duration = try await asset.load(.duration)
        let pixelsPerSecond = abs(size.width * size.height) * Double(fps > 0 ? fps : 30)
        let source = Double(dataRate)
        sourceInfo = String(format: "%.0f fps · %.0f Mbit/s", fps, source / 1_000_000)

        let bitrates: [Int]
        if source > 0 {
            if source / pixelsPerSecond < Self.efficientSourceBPP { return .alreadyEfficient }
            bitrates = quality.bitrateRatios.map { Int(source * $0) }
        } else {
            // unknown source rate: fall back to bits-per-pixel targets
            bitrates = quality.fallbackBPP.map { Int(pixelsPerSecond * $0) }
        }

        let probing = useProbe && enforceQualityCheck && duration.seconds > Self.probeSeconds * 3
        var lastScore = 0.0
        var encodedRungs = 0
        for (rung, bitrate) in bitrates.enumerated() {
            // ---- probe: a 3-second piece from the middle
            if probing {
                if let score = try await probe(asset: asset, duration: duration, bitrate: bitrate,
                                               progress: { progress(.probing($0)) }) {
                    let pass = score >= quality.minSSIM
                    attempts.append(String(format: "probe r%d %.3f%@", rung + 1, score, pass ? "" : " ✗"))
                    // a small margin: a piece can look slightly better than the whole video
                    if score < quality.minSSIM - 0.003 {
                        lastScore = score
                        continue
                    }
                }
            }

            // ---- full encode
            let encoded = try await encode(asset: asset, bitrate: bitrate, progress: {
                progress(.encoding(rung: encodedRungs, $0))
            })
            encodedRungs += 1
            progress(.finishing)

            if originalBytes > 0 && Double(encoded.bytes) > Double(originalBytes) * maxSizeRatio {
                // higher rungs would only be bigger
                try? FileManager.default.removeItem(at: encoded.url)
                attempts.append("r\(rung + 1) not smaller")
                return .alreadyEfficient
            }

            progress(.checking)
            let score = await QualityCheck.similarity(original: asset, compressed: AVURLAsset(url: encoded.url))
            let pass = !enforceQualityCheck || score == nil || score! >= quality.minSSIM
            attempts.append(String(format: "r%d %.3f%@", rung + 1, score ?? -1, pass ? "" : " ✗"))
            #if DEBUG
            print("[compress] rung=\(rung) bitrate=\(bitrate) ssim=\(score ?? -1) size=\(encoded.bytes)/\(originalBytes)")
            #endif
            if pass {
                return .compressed(Result(url: encoded.url, inputBytes: originalBytes, outputBytes: encoded.bytes,
                                          droppedAudioTracks: encoded.droppedAudio, rung: rung, bitrate: bitrate,
                                          similarity: score ?? 1, isHDR: encoded.isHDR))
            }
            lastScore = score!
            try? FileManager.default.removeItem(at: encoded.url)
        }
        throw AppError.qualityTooLow(lastScore)
    }

    /// Encodes 3 s from the middle (video only) and returns its similarity, or nil if it couldn't be measured.
    private func probe(asset: AVAsset, duration: CMTime, bitrate: Int,
                       progress: @escaping (Double) -> Void) async throws -> Double? {
        let start = CMTime(seconds: max(0, duration.seconds / 2 - Self.probeSeconds / 2), preferredTimescale: 600)
        let range = CMTimeRange(start: start, duration: CMTime(seconds: Self.probeSeconds, preferredTimescale: 600))
        let piece = try await encode(asset: asset, bitrate: bitrate, timeRange: range, includeAudio: false,
                                     progress: progress)
        defer { try? FileManager.default.removeItem(at: piece.url) }
        return await QualityCheck.similarity(original: asset, compressed: AVURLAsset(url: piece.url),
                                             originalOffset: start)
    }

    struct Encoded {
        let url: URL
        let bytes: Int64
        let droppedAudio: Int
        let isHDR: Bool
    }

    /// One HEVC encode at a fixed average bitrate (internal so tests can make deliberately bad copies).
    func encode(
        asset: AVAsset,
        bitrate: Int,
        timeRange: CMTimeRange? = nil,
        includeAudio: Bool = true,
        progress: @escaping (Double) -> Void
    ) async throws -> Encoded {

        // ---- inspect source
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.noVideoTrack
        }
        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let (characteristics, formats) = try await videoTrack.load(.mediaCharacteristics, .formatDescriptions)
        let (duration, metadata) = try await asset.load(.duration, .metadata)
        let audioTracks = includeAudio ? try await asset.loadTracks(withMediaType: .audio) : []

        let isHDR = characteristics.contains(.containsHDRVideo)
        let transfer = formats.first.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let isPQ = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)

        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        let frameRate = Double(fps > 0 ? fps : 30)

        // ---- free space check (output is at most ~ the original size)
        let seconds = timeRange?.duration.seconds ?? duration.seconds
        let estimatedBytes = Int64(Double(bitrate) / 8 * max(seconds, 1))
        try Self.ensureFreeSpace(atLeast: Int64(Double(estimatedBytes) * 1.2) + 300_000_000)

        // ---- reader
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let pixelFormat = isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw AppError.writerFailed("reader rejected video track") }
        reader.add(videoOutput)

        // ---- writer
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        writer.metadata = metadata
        // No "optimize for network use": it rewrites the whole finished file once more,
        // which doubled the free space needed (v0.7 test: "Disk Full" on a 4.8 GB video).
        writer.shouldOptimizeForNetworkUse = false

        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if isHDR {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        let colorProperties: [String: Any] = isHDR
            ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: isPQ ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                                                 : AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            : [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        compression[AVVideoAverageBitRateKey] = bitrate
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colorProperties,
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw AppError.writerFailed("writer rejected HEVC settings") }
        writer.add(videoInput)

        // ---- audio: pass through AAC / ALAC / PCM untouched
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var dropped = 0
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first else { dropped += 1; continue }
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            guard [kAudioFormatMPEG4AAC, kAudioFormatAppleLossless, kAudioFormatLinearPCM].contains(subtype) else {
                dropped += 1
                continue
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output) && writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioPairs.append((output, input))
            } else {
                dropped += 1
            }
        }

        // ---- run
        guard reader.startReading() else {
            throw AppError.writerFailed(reader.error?.localizedDescription ?? "reader failed to start")
        }
        guard writer.startWriting() else {
            throw AppError.writerFailed(writer.error?.localizedDescription ?? "writer failed to start")
        }
        let sessionStart = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: sessionStart)

        let totalSeconds = max(seconds, 0.1)
        let videoQueue = DispatchQueue(label: "compress.video")

        // Cancelling the Swift task stops the reader, which ends both pumps.
        await withTaskCancellationHandler {
          await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.pump(output: videoOutput, input: videoInput, queue: videoQueue) { time in
                    let p = min(max((time.seconds - sessionStart.seconds) / totalSeconds, 0), 1)
                    DispatchQueue.main.async { progress(p) }
                }
            }
            for (index, pair) in audioPairs.enumerated() {
                let queue = DispatchQueue(label: "compress.audio.\(index)")
                group.addTask {
                    await Self.pump(output: pair.0, input: pair.1, queue: queue, onSample: nil)
                }
            }
          }
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw AppError.writerFailed(reader.error?.localizedDescription ?? "read error")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outURL)
            throw AppError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        // ---- verify
        let outBytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let outDuration = try await AVURLAsset(url: outURL).load(.duration).seconds
        if abs(outDuration - seconds) > 1.0 {
            try? FileManager.default.removeItem(at: outURL)
            throw AppError.verifyFailed("Length changed - result discarded")
        }
        return Encoded(url: outURL, bytes: outBytes, droppedAudio: dropped, isHDR: isHDR)
    }

    // MARK: helpers

    /// Moves samples from reader output to writer input until done.
    private static func pump(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        queue: DispatchQueue,
        onSample: ((CMTime) -> Void)?
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = Box(false)
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished.value else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished.value = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !input.append(sample) {
                        finished.value = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    private static func ensureFreeSpace(atLeast bytes: Int64) throws {
        let values = try FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, free < bytes {
            throw AppError.notEnoughSpace(needed: bytes)
        }
    }
}
