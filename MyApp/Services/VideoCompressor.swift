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
        let usedQualityMode: Bool
        let similarity: Double
    }

    enum Outcome {
        case compressed(Result)
        case alreadyEfficient
    }

    /// Only accept the result if it is at most this fraction of the original size.
    var maxSizeRatio = 0.8
    /// Use the encoder's quality target when the device supports it (else fixed bitrate).
    var preferQualityMode = true

    func compress(
        asset: AVAsset,
        originalBytes: Int64,
        quality: CompressionQuality,
        progress: @escaping (Double) -> Void
    ) async throws -> Outcome {

        // ---- inspect source
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.noVideoTrack
        }
        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let (fps, dataRate) = try await videoTrack.load(.nominalFrameRate, .estimatedDataRate)
        let (characteristics, formats) = try await videoTrack.load(.mediaCharacteristics, .formatDescriptions)
        let (duration, metadata) = try await asset.load(.duration, .metadata)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let isHDR = characteristics.contains(.containsHDRVideo)
        let transfer = formats.first.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let isPQ = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)

        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        let frameRate = Double(fps > 0 ? fps : 30)
        var bitrate = Int(Double(width * height) * max(frameRate, 24) * quality.bitsPerPixel)
        let sourceBitrate = Int(dataRate)
        if sourceBitrate > 0 {
            if Double(bitrate) > Double(sourceBitrate) * 0.75 { return .alreadyEfficient }
            bitrate = min(bitrate, Int(Double(sourceBitrate) * 0.6))
        }

        // ---- free space check (output is at most ~ the original size)
        try Self.ensureFreeSpace(atLeast: originalBytes + 200_000_000)

        // ---- reader
        let reader = try AVAssetReader(asset: asset)
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
        writer.shouldOptimizeForNetworkUse = true

        // Rate control: prefer a QUALITY target (calm clips get small, busy clips keep detail).
        // Fall back to the fixed bitrate on devices/encoders that reject the quality key.
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
        func settings(_ props: [String: Any]) -> [String: Any] {
            [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: props,
                AVVideoColorPropertiesKey: colorProperties,
            ]
        }
        var qualityProps = compression
        qualityProps[AVVideoQualityKey] = quality.encoderQuality
        var bitrateProps = compression
        bitrateProps[AVVideoAverageBitRateKey] = bitrate

        let useQualityMode = preferQualityMode
            && writer.canApply(outputSettings: settings(qualityProps), forMediaType: .video)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings(useQualityMode ? qualityProps : bitrateProps)
        )
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
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(duration.seconds, 0.1)
        let videoQueue = DispatchQueue(label: "compress.video")

        // Cancelling the Swift task stops the reader, which ends both pumps.
        await withTaskCancellationHandler {
          await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.pump(output: videoOutput, input: videoInput, queue: videoQueue) { time in
                    let p = min(max(time.seconds / totalSeconds, 0), 1)
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
        if abs(outDuration - duration.seconds) > 1.0 {
            try? FileManager.default.removeItem(at: outURL)
            throw AppError.verifyFailed("Length changed - result discarded")
        }
        if originalBytes > 0 && Double(outBytes) > Double(originalBytes) * maxSizeRatio {
            try? FileManager.default.removeItem(at: outURL)
            return .alreadyEfficient
        }

        // ---- quality check: compare sample frames of original and copy
        progress(1)
        let similarity = await QualityCheck.similarity(original: asset, compressed: AVURLAsset(url: outURL))
        #if DEBUG
        print("[compress] mode=\(useQualityMode ? "quality" : "bitrate") ssim=\(similarity ?? -1) size=\(outBytes)/\(originalBytes)")
        #endif
        if let similarity, similarity < quality.minSSIM {
            try? FileManager.default.removeItem(at: outURL)
            throw AppError.qualityTooLow(similarity)
        }

        return .compressed(Result(url: outURL, inputBytes: originalBytes, outputBytes: outBytes,
                                  droppedAudioTracks: dropped, usedQualityMode: useQualityMode,
                                  similarity: similarity ?? 1))
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
            throw AppError.notEnoughSpace
        }
    }
}
