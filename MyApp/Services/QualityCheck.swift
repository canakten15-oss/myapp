import AVFoundation
import CoreGraphics

/// Compares original and compressed video on a few sample frames using SSIM
/// (structural similarity, 1.0 = identical). Cheap: ~6 frames at 360 px width.
enum QualityCheck {

    static let sampleCount = 6
    static let analysisWidth = 360

    /// Average SSIM over sample frames, or nil if frames could not be read
    /// (then the check is skipped rather than blocking the user).
    static func similarity(original: AVAsset, compressed: AVAsset) async -> Double? {
        guard let duration = try? await original.load(.duration).seconds, duration > 0.5 else { return nil }

        let genA = makeGenerator(original)
        let genB = makeGenerator(compressed)

        var scores: [Double] = []
        for i in 0..<sampleCount {
            // spread samples between 10% and 90% of the clip
            let t = duration * (0.1 + 0.8 * Double(i) / Double(max(sampleCount - 1, 1)))
            let time = CMTime(seconds: t, preferredTimescale: 600)
            guard
                let a = try? await genA.image(at: time).image,
                let b = try? await genB.image(at: time).image,
                let score = ssim(a, b)
            else { continue }
            scores.append(score)
        }
        guard scores.count >= sampleCount / 2 else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private static func makeGenerator(_ asset: AVAsset) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero   // exact frames, so both sides match
        g.requestedTimeToleranceAfter = .zero
        g.maximumSize = CGSize(width: 720, height: 720)
        return g
    }

    // MARK: SSIM

    /// SSIM on luma, 8x8 non-overlapping windows.
    static func ssim(_ a: CGImage, _ b: CGImage) -> Double? {
        let w = analysisWidth
        let h = max(8, Int(Double(w) * Double(a.height) / Double(max(a.width, 1))))
        guard let x = gray(a, width: w, height: h), let y = gray(b, width: w, height: h) else { return nil }

        let c1 = pow(0.01 * 255, 2.0)
        let c2 = pow(0.03 * 255, 2.0)
        var total = 0.0
        var windows = 0

        var by = 0
        while by + 8 <= h {
            var bx = 0
            while bx + 8 <= w {
                var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                for yy in by..<(by + 8) {
                    let row = yy * w
                    for xx in bx..<(bx + 8) {
                        let p = Double(x[row + xx]), q = Double(y[row + xx])
                        sx += p; sy += q; sxx += p * p; syy += q * q; sxy += p * q
                    }
                }
                let n = 64.0
                let mx = sx / n, my = sy / n
                let vx = sxx / n - mx * mx
                let vy = syy / n - my * my
                let cov = sxy / n - mx * my
                total += ((2 * mx * my + c1) * (2 * cov + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
                windows += 1
                bx += 8
            }
            by += 8
        }
        return windows > 0 ? total / Double(windows) : nil
    }

    /// Draws the image into an 8-bit grayscale buffer of the given size.
    private static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }
}
