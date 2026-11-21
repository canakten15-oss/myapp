import AVFoundation
import XCTest
@testable import MyApp

/// Benchmark on real camera footage. Runs only when CI sets BENCH_DIR (bench.yml):
/// compresses every .mov there at both levels, writes results to BENCH_DIR/out/.
final class BenchTests: XCTestCase {

    func testBenchmark() async throws {
        executionTimeAllowance = 3000
        guard let dir = ProcessInfo.processInfo.environment["BENCH_DIR"] else {
            throw XCTSkip("BENCH_DIR not set")
        }
        let base = URL(fileURLWithPath: dir)
        let out = base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no benchmark clips")

        var lines = ["clip,level,rung,in_bytes,out_bytes,ssim_app,seconds"]
        for src in files {
            let inBytes = (try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? 0
            for q in CompressionQuality.allCases {
                let c = VideoCompressor()
                let t0 = Date()
                let outcome: VideoCompressor.Outcome
                do {
                    outcome = try await c.compress(asset: AVURLAsset(url: src), originalBytes: inBytes,
                                                   quality: q, progress: { _ in })
                } catch AppError.qualityTooLow(let score) {
                    lines.append("\(src.deletingPathExtension().lastPathComponent),\(q.rawValue),kept-original,\(inBytes),0,"
                                 + String(format: "%.4f,%.1f", score, Date().timeIntervalSince(t0)))
                    print("[BENCH] " + lines.last!)
                    continue
                }
                let secs = Date().timeIntervalSince(t0)
                let name = src.deletingPathExtension().lastPathComponent
                switch outcome {
                case .compressed(let r):
                    let dest = out.appendingPathComponent("\(name)__\(q.rawValue).mov")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: r.url, to: dest)
                    lines.append("\(name),\(q.rawValue),rung\(r.rung)@\(r.bitrate / 1000)k,\(inBytes),\(r.outputBytes),"
                                 + String(format: "%.4f,%.1f", r.similarity, secs))
                case .alreadyEfficient:
                    lines.append("\(name),\(q.rawValue),skipped,\(inBytes),0,0,\(Int(secs))")
                }
                print("[BENCH] " + lines.last!)
            }
        }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("app_results.csv"), atomically: true, encoding: .utf8)
    }
}
