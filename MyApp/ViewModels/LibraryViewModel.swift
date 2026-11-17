import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class LibraryViewModel: ObservableObject {

    @Published var authorization: PHAuthorizationStatus = PhotoLibraryService.currentStatus
    @Published var items: [VideoItem] = []
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var lastBatchSaved: Int64 = 0
    // batch progress (for the working panel)
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchDone = 0
    @Published private(set) var batchStarted = Date()
    @Published var errorMessage: String?

    /// Originals that have a verified smaller copy and can be deleted.
    @Published private(set) var pendingDeleteIDs: [String] = []
    @Published private(set) var pendingDeleteBytes: Int64 = 0

    // Plain @Published + UserDefaults (@AppStorage does not refresh views inside an ObservableObject)
    @Published var minSizeMB: Int = UserDefaults.standard.object(forKey: "minSizeMB") != nil
        ? UserDefaults.standard.integer(forKey: "minSizeMB") : 100 {
        didSet { UserDefaults.standard.set(minSizeMB, forKey: "minSizeMB") }
    }
    @Published var qualityRaw: String = UserDefaults.standard.string(forKey: "quality")
        ?? CompressionQuality.bestQuality.rawValue {
        didSet { UserDefaults.standard.set(qualityRaw, forKey: "quality") }
    }
    @Published var totalSavedBytes: Double = UserDefaults.standard.double(forKey: "totalSavedBytes") {
        didSet { UserDefaults.standard.set(totalSavedBytes, forKey: "totalSavedBytes") }
    }

    var quality: CompressionQuality {
        get { CompressionQuality(rawValue: qualityRaw) ?? .bestQuality }
        set { qualityRaw = newValue.rawValue }
    }

    private let defaults = UserDefaults.standard
    private let processedKey = "processedAssetIDs"   // our own outputs + skipped files
    private let pendingKey = "pendingDeleteIDs"
    private var runTask: Task<Void, Never>?
    private let compressor = VideoCompressor()

    init() {
        pendingDeleteIDs = defaults.stringArray(forKey: pendingKey) ?? []
    }

    // MARK: derived

    var selectedItems: [VideoItem] { items.filter { $0.isSelected && !$0.status.isFinished } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.fileSize } }
    var estimatedSavings: Int64 { Int64(Double(selectedBytes) * quality.typicalSavings) }

    // MARK: access + scan

    func requestAccess() async {
        authorization = await PhotoLibraryService.requestAccess()
        if authorization == .authorized || authorization == .limited { await scan() }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let minBytes = Int64(minSizeMB) * 1_048_576
        let processed = Set(defaults.stringArray(forKey: processedKey) ?? [])
        let found = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.fetchCandidates(minBytes: minBytes, excluding: processed)
        }.value
        items = found
        refreshPendingBytes()
        isScanning = false
    }

    func toggle(_ item: VideoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isSelected.toggle()
    }

    func setAll(selected: Bool) {
        for i in items.indices where !items[i].status.isFinished { items[i].isSelected = selected }
    }

    // MARK: batch

    func start() {
        guard !isRunning else { return }
        runTask = Task { await runBatch() }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func runBatch() async {
        let queue = selectedItems
        isRunning = true
        lastBatchSaved = 0
        batchTotal = queue.count
        batchDone = 0
        batchStarted = Date()
        AdService.shared.batchStarted()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isRunning = false
            AdService.shared.batchEnded()
        }

        for item in queue {
            if Task.isCancelled { break }
            await process(item)
            batchDone += 1
        }
        // No ad here on purpose: ads are only shown WHILE a batch runs.
    }

    private func process(_ item: VideoItem) async {
        let id = item.id
        let started = Date()
        let q = quality
        func log(_ result: String) {
            let a = item.asset
            let res = max(a.pixelWidth, a.pixelHeight) >= 3800 ? "4K" : "\(min(a.pixelWidth, a.pixelHeight))p"
            appendReport("\(res) · \(Format.duration(a.duration)) · \(q.label) · \(result) · \(Int(Date().timeIntervalSince(started))) s")
        }
        do {
            update(id, .downloading(0))
            let avAsset = try await PhotoLibraryService.loadOriginal(item.asset) { [weak self] p in
                Task { @MainActor in self?.updateProgress(id, .downloading(p)) }
            }

            update(id, .compressing(0))
            let outcome = try await compressor.compress(
                asset: avAsset, originalBytes: item.fileSize, quality: quality
            ) { [weak self] p in
                Task { @MainActor in self?.updateProgress(id, .compressing(p)) }
            }

            switch outcome {
            case .alreadyEfficient:
                log("\(Format.bytes(item.fileSize)) skipped: already efficient")
                markProcessed(id)
                update(id, .skipped("Already efficient"))

            case .compressed(let result):
                update(id, .saving)
                let newID = try await PhotoLibraryService.saveCompressed(fileURL: result.url, basedOn: item.asset)
                try? FileManager.default.removeItem(at: result.url)
                markProcessed(newID)
                markProcessed(id)
                addPendingDelete(id, bytes: item.fileSize)
                let saved = result.inputBytes - result.outputBytes
                let pct = result.inputBytes > 0 ? 100 - Int(result.outputBytes * 100 / result.inputBytes) : 0
                log("\(Format.bytes(result.inputBytes)) → \(Format.bytes(result.outputBytes)) (−\(pct)%)"
                    + (result.isHDR ? " · HDR" : "")
                    + " · \(result.usedQualityMode ? "quality" : "bitrate") mode"
                    + String(format: " · SSIM %.3f", result.similarity)
                    + (result.droppedAudioTracks > 0 ? " · dropped \(result.droppedAudioTracks) audio" : ""))
                lastBatchSaved += saved
                totalSavedBytes += Double(saved)
                update(id, .done(savedBytes: saved))
            }
        } catch is CancellationError {
            update(id, .pending)
        } catch AppError.qualityTooLow(let score) {
            // copy discarded, original untouched; offered again next scan (e.g. with Best quality)
            log(String(format: "\(Format.bytes(item.fileSize)) rejected: SSIM %.3f", score))
            update(id, .skipped(String(format: "Kept original: copy only %.0f%% similar", score * 100)))
        } catch {
            log("\(Format.bytes(item.fileSize)) FAILED: \(error.localizedDescription)")
            update(id, .failed(error.localizedDescription))
        }
    }

    /// Progress ticks arrive asynchronously; never let a late tick overwrite a later stage.
    private func updateProgress(_ id: String, _ status: ItemStatus) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch (items[i].status, status) {
        case (.downloading, .downloading), (.compressing, .compressing):
            items[i].status = status
        default:
            break
        }
    }

    private func update(_ id: String, _ status: ItemStatus) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    // MARK: batch progress

    /// The item currently being worked on.
    var currentItem: VideoItem? {
        items.first {
            switch $0.status {
            case .downloading, .compressing, .saving: return true
            default: return false
            }
        }
    }

    /// 0...1 across the whole batch.
    var batchProgress: Double {
        guard batchTotal > 0 else { return 0 }
        var current = 0.0
        if let item = currentItem {
            switch item.status {
            case .downloading(let p): current = p * 0.1
            case .compressing(let p): current = 0.1 + p * 0.85
            case .saving: current = 0.95
            default: break
            }
        }
        return min((Double(batchDone) + current) / Double(batchTotal), 1)
    }

    /// Rough time left, nil until there is enough data.
    var timeRemaining: TimeInterval? {
        let p = batchProgress
        let elapsed = Date().timeIntervalSince(batchStarted)
        guard p > 0.03, elapsed > 5 else { return nil }
        return elapsed / p - elapsed
    }

    // MARK: delete originals

    func deleteOriginals() async {
        let ids = pendingDeleteIDs
        do {
            try await PhotoLibraryService.deleteAssets(withIdentifiers: ids)
            pendingDeleteIDs = []
            defaults.set(pendingDeleteIDs, forKey: pendingKey)
            refreshPendingBytes()
            items.removeAll { ids.contains($0.id) }
        } catch {
            // user tapped "Don't Allow" in the system dialog - keep the list
            errorMessage = "Nothing was deleted."
        }
    }

    // MARK: test report (Settings → Test report; shared by testers)

    @Published private(set) var report: [String] = UserDefaults.standard.stringArray(forKey: "testReport") ?? []

    private func appendReport(_ line: String) {
        let stamp = Date().formatted(date: .numeric, time: .shortened)
        report.insert("\(stamp) · \(line)", at: 0)
        if report.count > 200 { report.removeLast(report.count - 200) }
        UserDefaults.standard.set(report, forKey: "testReport")
    }

    func clearReport() {
        report = []
        UserDefaults.standard.removeObject(forKey: "testReport")
    }

    var reportText: String {
        let d = UIDevice.current
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return (["MyApp \(version) · \(model) · \(d.systemName) \(d.systemVersion)"] + report).joined(separator: "\n")
    }

    // MARK: persistence

    private func markProcessed(_ id: String) {
        guard !id.isEmpty else { return }
        var set = defaults.stringArray(forKey: processedKey) ?? []
        if !set.contains(id) { set.append(id) }
        defaults.set(set, forKey: processedKey)
    }

    private func addPendingDelete(_ id: String, bytes: Int64) {
        guard !pendingDeleteIDs.contains(id) else { return }
        pendingDeleteIDs.append(id)
        pendingDeleteBytes += bytes
        defaults.set(pendingDeleteIDs, forKey: pendingKey)
    }

    private func refreshPendingBytes() {
        // drop IDs the user already deleted in the Photos app
        let existing = PHAsset.fetchAssets(withLocalIdentifiers: pendingDeleteIDs, options: nil)
        var alive: [String] = []
        existing.enumerateObjects { asset, _, _ in alive.append(asset.localIdentifier) }
        pendingDeleteIDs = alive
        defaults.set(alive, forKey: pendingKey)
        pendingDeleteBytes = PhotoLibraryService.totalSize(ofIdentifiers: alive)
    }
}
