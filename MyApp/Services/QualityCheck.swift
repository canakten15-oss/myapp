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
    /// The score is the average, but one clearly bad frame pulls it down: we blend in the worst frame.
    static func similarity(original: AVAsset, compressed: AVAsset) async -> Double? {
        guard let duration = try? await original.load(.duration).seconds, duration > 0.5 else { return nil }

        let genA = makeGenerator(original)
        let genB = makeGenerator(compressed)

        var scores: [Double] = []
        for i in 0..<sampleCount {
            // spread samples between 5% and 95% of the clip
            let t = duration * (0.05 + 0.9 * Double(i) / Double(max(sampleCount - 1, 1)))
            let time = CMTime(seconds: t, preferredTimescale: 600)
            guard
                let a = try? await genA.image(at: time).image,
                let b = try? await genB.image(at: time).image,
                let score = ssim(a, b)
            else { continue }
            scores.append(score)
        }
        guard scores.count >= sampleCount / 2, let worst = scores.min() else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        // 75% average, 25% worst frame: a short smeared moment (fast pan) is not averaged away.
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
