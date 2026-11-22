import Accelerate
import AVFoundation
import CoreGraphics

/// Compares original and compressed video on sample frames using SSIM
/// (structural similarity, 1.0 = identical) on luma at FULL resolution.
/// Full resolution matters: at reduced size, smeared detail looks fine (v0.5 let VMAF-47 copies pass).
enum QualityCheck {

    static let sampleCount = 10

    /// Average SSIM over sample frames, or nil if frames could not be read
    /// (then the check is skipped rather than blocking the user).
    ///
    /// Frame matching (v0.8): timestamps of original and copy can differ by a few ms
    /// (iPhone videos often have a hidden lead-in / edit list). Picking "the frame at time t"
    /// in both then sometimes compares NEIGHBOURING frames, which scored ~0.92 on real 4K60
    /// footage and wrongly rejected good copies. So each original frame is compared with the
    /// copy's frame at that time AND its two neighbours; the best match is the same frame.
    ///
    /// `originalOffset`: where the compressed clip starts in the original (for probe clips).
    /// The score is 75% average + 25% worst frame, so a short bad moment isn't averaged away.
    static func similarity(original: AVAsset, compressed: AVAsset,
                           originalOffset: CMTime = .zero) async -> Double? {
        guard var duration = try? await compressed.load(.duration).seconds, duration > 0.3 else { return nil }
        var frameStep = 1.0 / 30
        if let track = try? await original.loadTracks(withMediaType: .video).first,
           let mfd = try? await track.load(.minFrameDuration), mfd.isValid, mfd.seconds > 0 {
            frameStep = mfd.seconds
        }

        // Where the copy's own timeline starts (a piece may keep the original's timestamps).
        var copyStart = 0.0
        if let ct = try? await compressed.loadTracks(withMediaType: .video).first,
           let range = try? await ct.load(.timeRange), range.start.isValid {
            copyStart = range.start.seconds
            if range.duration.isValid, range.duration.seconds > 0.3 { duration = range.duration.seconds }
        }
        // original time = copy time - copyStart + offset
        let offset = originalOffset.seconds - copyStart

        let genA = makeGenerator(original)
        let genB = makeGenerator(compressed)

        var scores: [Double] = []
        for i in 0..<sampleCount {
            // spread samples between 5% and 95% of the (compressed) clip
            let t = copyStart + duration * (0.05 + 0.9 * Double(i) / Double(max(sampleCount - 1, 1)))
            guard let a = try? await genA.image(at: CMTime(seconds: offset + t, preferredTimescale: 600)).image
            else { continue }
            var best: Double?
            for k in [0.0, -1.0, 1.0] {
                let tb = max(copyStart, t + k * frameStep)
                guard let b = try? await genB.image(at: CMTime(seconds: tb, preferredTimescale: 600)).image,
                      let s = ssim(a, b) else { continue }
                best = max(best ?? 0, s)
                if s > 0.995 { break }   // clearly the same frame, no need to try neighbours
            }
            if let best { scores.append(best) }
        }
        guard scores.count >= sampleCount / 2, let worst = scores.min() else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        return 0.75 * mean + 0.25 * worst
    }

    private static func makeGenerator(_ asset: AVAsset) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero   // exact frames, so both sides match
        g.requestedTimeToleranceAfter = .zero
        g.maximumSize = .zero                    // native resolution
        return g
    }

    // MARK: SSIM (8x8 windows, luma, vectorised)

    static func ssim(_ a: CGImage, _ b: CGImage) -> Double? {
        let w = (min(a.width, b.width) / 8) * 8
        let h = (min(a.height, b.height) / 8) * 8
        guard w >= 8, h >= 8, let x = luma(a, width: w, height: h), let y = luma(b, width: w, height: h) else { return nil }
        let n = w * h

        var xx = [Float](repeating: 0, count: n), yy = xx, xy = xx
        vDSP_vsq(x, 1, &xx, 1, vDSP_Length(n))
        vDSP_vsq(y, 1, &yy, 1, vDSP_Length(n))
        vDSP_vmul(x, 1, y, 1, &xy, 1, vDSP_Length(n))

        let bw = w / 8, bh = h / 8
        let sx = blockSums(x, w, h), sy = blockSums(y, w, h)
        let sxx = blockSums(xx, w, h), syy = blockSums(yy, w, h), sxy = blockSums(xy, w, h)

        let c1 = Float(0.01 * 255) * Float(0.01 * 255)
        let c2 = Float(0.03 * 255) * Float(0.03 * 255)
        var total = 0.0
        for i in 0..<(bw * bh) {
            let mx = sx[i] / 64, my = sy[i] / 64
            let vx = sxx[i] / 64 - mx * mx
            let vy = syy[i] / 64 - my * my
            let cov = sxy[i] / 64 - mx * my
            total += Double(((2 * mx * my + c1) * (2 * cov + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2)))
        }
        return total / Double(bw * bh)
    }

    /// Sum of every 8x8 block (row-major block grid of size (w/8) x (h/8)).
    private static func blockSums(_ a: [Float], _ w: Int, _ h: Int) -> [Float] {
        let bw = w / 8, bh = h / 8
        let ones = [Float](repeating: 1, count: 8)
        var rowSums = [Float](repeating: 0, count: h * bw)   // 8-pixel sums along each row
        a.withUnsafeBufferPointer { src in
            rowSums.withUnsafeMutableBufferPointer { dst in
                for r in 0..<h {
                    vDSP_desamp(src.baseAddress! + r * w, 8, ones, dst.baseAddress! + r * bw,
                                vDSP_Length(bw), 8)
                }
            }
        }
        var out = [Float](repeating: 0, count: bw * bh)
        rowSums.withUnsafeBufferPointer { rs in
            out.withUnsafeMutableBufferPointer { o in
                for by in 0..<bh {
                    let dst = o.baseAddress! + by * bw
                    for r in 0..<8 {
                        vDSP_vadd(dst, 1, rs.baseAddress! + (by * 8 + r) * bw, 1, dst, 1, vDSP_Length(bw))
                    }
                }
            }
        }
        return out
    }

    /// Draws the image into an 8-bit grayscale buffer and converts it to Float.
    private static func luma(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            // same size as the image in the normal case (no scaling); scaled only if the copy's size differs
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        var f = [Float](repeating: 0, count: width * height)
        vDSP_vfltu8(bytes, 1, &f, 1, vDSP_Length(width * height))
        return f
    }
}
