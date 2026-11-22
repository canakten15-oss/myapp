import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class LibraryViewModel: ObservableObject {

    // MARK: published state

    @Published var authorization: PHAuthorizationStatus = PhotoLibraryService.currentStatus
    /// "To do": videos that can still be shrunk.
    @Published var items: [VideoItem] = []
    /// "Shrunk": persisted successes (stay separate, never come back to To do).
    @Published private(set) var shrunk: [ShrunkRecord] = []
    /// "Can't shrink": persisted rejections (greyed out, retry possible).
    @Published private(set) var rejected: [RejectedRecord] = []

    @Published var isScanning = false
    @Published var isRunning = false
    @Published var errorMessage: String?

    // batch progress (working screen)
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchDone = 0
    @Published private(set) var batchStarted = Date()
    @Published private(set) var lastBatchSaved: Int64 = 0
    @Published private(set) var etaText = "Estimating…"
    /// Shown after a finished batch (result screen).
    @Published var batchResult: BatchResult?

    struct BatchResult: Identifiable {
        let id = UUID()
        let shrunkIDs: [String]       // originals that now have a copy
        let savedBytes: Int64         // freed once those originals are deleted
        let rejectedCount: Int
        let failedCount: Int
    }

    // MARK: settings (plain @Published + UserDefaults; @AppStorage doesn't refresh inside an ObservableObject)

    @Published var minSizeMB: Int = UserDefaults.standard.object(forKey: "minSizeMB") != nil
        ? UserDefaults.standard.integer(forKey: "minSizeMB") : 100 {
        didSet { UserDefaults.standard.set(minSizeMB, forKey: "minSizeMB") }
    }
    @Published var qualityRaw: String = UserDefaults.standard.string(forKey: "quality")
        ?? CompressionQuality.maxSavings.rawValue {
        didSet { UserDefaults.standard.set(qualityRaw, forKey: "quality") }
    }
    @Published var totalSavedBytes: Double = UserDefaults.standard.double(forKey: "totalSavedBytes") {
        didSet { UserDefaults.standard.set(totalSavedBytes, forKey: "totalSavedBytes") }
    }

    var quality: CompressionQuality {
        get { CompressionQuality(rawValue: qualityRaw) ?? .maxSavings }
        set { qualityRaw = newValue.rawValue }
    }

    private let defaults = UserDefaults.standard
    private var runTask: Task<Void, Never>?
    private var etaTask: Task<Void, Never>?
    private let compressor = VideoCompressor()

    init() {
        shrunk = Self.load([ShrunkRecord].self, key: "shrunkRecords") ?? []
        rejected = Self.load([RejectedRecord].self, key: "rejectedRecords") ?? []
        Self.cleanTemporaryFiles()
    }

    // MARK: derived

    var selectedItems: [VideoItem] { items.filter { $0.isSelected && !$0.status.isFinished } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.fileSize } }
    var estimatedSavings: Int64 { Int64(Double(selectedBytes) * quality.typicalSavings) }

    /// Originals that have a verified copy and are still in the library.
    var pendingDeleteIDs: [String] { shrunk.filter { !$0.originalDeleted }.map(\.originalID) }
    var pendingDeleteBytes: Int64 { shrunk.filter { !$0.originalDeleted }.reduce(0) { $0 + $1.inputBytes } }
    var pendingSavedBytes: Int64 { shrunk.filter { !$0.originalDeleted }.reduce(0) { $0 + $1.savedBytes } }
    /// Really freed: only counts once the original is gone.
    var freedBytes: Int64 { shrunk.filter(\.originalDeleted).reduce(0) { $0 + $1.savedBytes } }

    // MARK: access + scan

    func requestAccess() async {
        authorization = await PhotoLibraryService.requestAccess()
        if authorization == .authorized || authorization == .limited { await scan() }
    }

    func scan() async {
        guard !isScanning, !isRunning else { return }
        isScanning = true
        refreshRecords()
        let minBytes = Int64(minSizeMB) * 1_048_576
        var exclude = Set(defaults.stringArray(forKey: "processedAssetIDs") ?? [])
        for r in shrunk { exclude.insert(r.originalID); exclude.insert(r.copyID) }
        for r in rejected { exclude.insert(r.originalID) }
        let excluded = exclude
        let found = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.fetchCandidates(minBytes: minBytes, excluding: excluded)
        }.value
        // keep the user's selection across rescans
        let selected = Set(items.filter(\.isSelected).map(\.id))
        items = found.map { var i = $0; i.isSelected = selected.contains(i.id); return i }
        isScanning = false
    }

    func toggle(_ item: VideoItem) {
        guard !isRunning, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isSelected.toggle()
    }

    func setAll(selected: Bool) {
        for i in items.indices where !items[i].status.isFinished { items[i].isSelected = selected }
    }

    /// Moves a "can't shrink" video back to To do (e.g. to try Best quality).
    func retry(_ record: RejectedRecord) {
        rejected.removeAll { $0.id == record.id }
        save(rejected, key: "rejectedRecords")
        Task { await scan() }
    }

    // MARK: batch

    func start() {
        guard !isRunning, !selectedItems.isEmpty else { return }
        runTask = Task { await runBatch() }
    }

    func cancel() { runTask?.cancel() }

    private func runBatch() async {
        var queue = selectedItems
        // Tight on space: smallest first, so deleting their originals makes room for the big ones.
        let free = Self.freeSpace()
        if let biggest = queue.map(\.fileSize).max(), free < biggest * 5 / 2 {
            queue.sort { $0.fileSize < $1.fileSize }
        } else {
            queue.sort { $0.fileSize > $1.fileSize }
        }

        isRunning = true
        lastBatchSaved = 0
        batchTotal = queue.count
        batchDone = 0
        batchStarted = Date()
        progressHistory = []
        displayedETA = nil
        etaText = "Estimating…"
        AdService.shared.batchStarted()
        UIApplication.shared.isIdleTimerDisabled = true
        startETALoop()

        var doneIDs: [String] = []
        var saved: Int64 = 0
        var rejectedCount = 0, failedCount = 0
        for item in queue {
            if Task.isCancelled { break }
            switch await process(item) {
            case .done(let s): doneIDs.append(item.id); saved += s
            case .skipped: rejectedCount += 1
            case .failed: failedCount += 1
            default: break
            }
            batchDone += 1
        }

        etaTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        AdService.shared.batchEnded()   // ads only while working: never after a job
        isRunning = false
        let wasCancelled = Task.isCancelled
        await scan()
        if !wasCancelled && (!doneIDs.isEmpty || rejectedCount + failedCount > 0) {
            batchResult = BatchResult(shrunkIDs: doneIDs, savedBytes: saved,
                                      rejectedCount: rejectedCount, failedCount: failedCount)
        }
    }

    private func process(_ item: VideoItem) async -> ItemStatus {
        let id = item.id
        let started = Date()
        let q = quality
        let retryStart = Box<Double?>(nil)   // where the bar was when a second pass began

        func log(_ result: String) {
            let a = item.asset
            let res = max(a.pixelWidth, a.pixelHeight) >= 3800 ? "4K" : "\(min(a.pixelWidth, a.pixelHeight))p"
            let attempts = compressor.attempts.isEmpty ? "" : " · [" + compressor.attempts.joined(separator: ", ") + "]"
            let info = compressor.sourceInfo.isEmpty ? "" : " · " + compressor.sourceInfo
            appendReport("\(res) · \(Format.duration(a.duration))\(info) · \(q.label) · \(result)\(attempts) · \(Int(Date().timeIntervalSince(started))) s")
        }

        // Space check before starting: copy + margin, plus the original if it must come from iCloud.
        let estimatedCopy = Int64(Double(item.fileSize) * (q.bitrateRatios.last ?? 0.7) * 1.2)
        let needsDownload = !PhotoLibraryService.isLocallyAvailable(item.asset)
        let needed = estimatedCopy + (needsDownload ? item.fileSize : 0) + 300_000_000
        if Self.freeSpace() < needed {
            let status = ItemStatus.skipped("Needs \(Format.bytes(needed)) free space")
            update(id, status)
            appendReportLine(item, q, "\(Format.bytes(item.fileSize)) skipped: needs \(Format.bytes(needed)) free", started)
            return status
        }

        do {
            setProgress(id, .downloading, 0)
            let avAsset = try await PhotoLibraryService.loadOriginal(item.asset) { [weak self] p in
                Task { @MainActor in self?.setProgress(id, .downloading, 0.05 * p) }
            }

            let outcome = try await compressor.compress(asset: avAsset, originalBytes: item.fileSize, quality: q) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .probing(let p):
                        self.setProgress(id, .testing, 0.05 + 0.05 * p)
                    case .encoding(let rung, let p):
                        if rung == 0 {
                            self.setProgress(id, .compressing, 0.10 + 0.75 * p)
                        } else {
                            // second full pass: continue from where the bar is, never jump back
                            let start = retryStart.value ?? self.progress(of: id)
                            retryStart.value = start
                            self.setProgress(id, .retrying, start + (0.85 - start) * p)
                        }
                    case .finishing:
                        self.setProgress(id, .finishing, 0.87)
                    case .checking:
                        self.setProgress(id, .checking, 0.92)
                    }
                }
            }

            switch outcome {
            case .alreadyEfficient:
                markProcessed(id)
                log("\(Format.bytes(item.fileSize)) skipped: already efficient")
                let s = ItemStatus.skipped("Already small, nothing to gain")
                update(id, s)
                return s

            case .compressed(let result):
                setProgress(id, .saving, 0.97)
                let newID = try await PhotoLibraryService.saveCompressed(fileURL: result.url, basedOn: item.asset)
                try? FileManager.default.removeItem(at: result.url)
                markProcessed(newID)
                markProcessed(id)
                let record = ShrunkRecord(originalID: id, copyID: newID, inputBytes: result.inputBytes,
                                          outputBytes: result.outputBytes, level: q.label, date: Date())
                shrunk.insert(record, at: 0)
                save(shrunk, key: "shrunkRecords")
                let saved = result.inputBytes - result.outputBytes
                lastBatchSaved += saved
                log("\(Format.bytes(result.inputBytes)) → \(Format.bytes(result.outputBytes)) (−\(record.savedPercent)%)"
                    + (result.isHDR ? " · HDR" : "")
                    + " · rung \(result.rung + 1) @ \(result.bitrate / 1_000_000) Mbit/s"
                    + String(format: " · SSIM %.3f", result.similarity)
                    + (result.droppedAudioTracks > 0 ? " · dropped \(result.droppedAudioTracks) audio" : ""))
                let s = ItemStatus.done(savedBytes: saved)
                update(id, s)
                return s
            }
        } catch is CancellationError {
            update(id, .pending)
            return .pending
        } catch AppError.qualityTooLow(let score) {
            // copy discarded, original untouched; remembered so nobody repeats the attempt
            log(String(format: "\(Format.bytes(item.fileSize)) rejected: SSIM %.3f", score))
            let reason = String(format: "%.0f%% similar with %@", score * 100, q.label)
            rejected.insert(RejectedRecord(originalID: id, fileSize: item.fileSize, level: q.label,
                                           reason: reason, date: Date()), at: 0)
            save(rejected, key: "rejectedRecords")
            let s = ItemStatus.skipped("Can't shrink without visible loss")
            update(id, s)
            return s
        } catch {
            log("\(Format.bytes(item.fileSize)) FAILED: \(error.localizedDescription)")
            let s = ItemStatus.failed(error.localizedDescription)
            update(id, s)
            return s
        }
    }

    private func appendReportLine(_ item: VideoItem, _ q: CompressionQuality, _ result: String, _ started: Date) {
        let a = item.asset
        let res = max(a.pixelWidth, a.pixelHeight) >= 3800 ? "4K" : "\(min(a.pixelWidth, a.pixelHeight))p"
        appendReport("\(res) · \(Format.duration(a.duration)) · \(q.label) · \(result) · \(Int(Date().timeIntervalSince(started))) s")
    }

    // MARK: per-item progress (monotonic)

    private func progress(of id: String) -> Double {
        if let item = items.first(where: { $0.id == id }), case .working(_, let p) = item.status { return p }
        return 0
    }

    private func setProgress(_ id: String, _ phase: WorkPhase, _ value: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var current = 0.0
        if case .working(_, let p) = items[i].status { current = p }
        else if items[i].status.isFinished { return }   // a late tick must not undo a result
        items[i].status = .working(phase, max(current, min(value, 1)))
    }

    private func update(_ id: String, _ status: ItemStatus) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    /// The item currently being worked on.
    var currentItem: VideoItem? { items.first { $0.status.isWorking } }

    /// 0...1 across the whole batch.
    var batchProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min((Double(batchDone) + progress(of: currentItem?.id ?? "")) / Double(batchTotal), 1)
    }

    // MARK: ETA: speed from the last 30 s, smoothed, never jumps around

    private var progressHistory: [(Date, Double)] = []
    private var displayedETA: Double?

    private func startETALoop() {
        etaTask?.cancel()
        etaTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.tickETA() }
            }
        }
    }

    private func tickETA() {
        let now = Date()
        let p = batchProgress
        progressHistory.append((now, p))
        progressHistory.removeAll { now.timeIntervalSince($0.0) > 30 }
        guard now.timeIntervalSince(batchStarted) >= 20,
              let first = progressHistory.first, now.timeIntervalSince(first.0) >= 10,
              p - first.1 > 0.0005 else {
            if displayedETA == nil { etaText = "Estimating…" }
            return
        }
        let rate = (p - first.1) / now.timeIntervalSince(first.0)   // progress per second
        let target = (1 - p) / rate
        if var shown = displayedETA {
            shown -= 1                                // count down in real time…
            shown += (target - shown) * 0.15          // …and drift gently toward the measured value
            displayedETA = max(shown, 1)
        } else {
            displayedETA = target
        }
        etaText = Format.eta(displayedETA!)
    }

    // MARK: delete originals

    /// Deletes originals that have a verified copy. iOS shows its own confirmation.
    func deleteOriginals(_ ids: [String]? = nil) async {
        let targets = ids ?? pendingDeleteIDs
        guard !targets.isEmpty else { return }
        do {
            try await PhotoLibraryService.deleteAssets(withIdentifiers: targets)
            refreshRecords()
            batchResult = nil
        } catch {
            errorMessage = "Nothing was deleted."
        }
    }

    /// Marks records whose original is gone (deleted here or in the Photos app); drops records whose copy is gone.
    private func refreshRecords() {
        let ids = shrunk.flatMap { [$0.originalID, $0.copyID] }
        let alive = PhotoLibraryService.existingIDs(ids)
        shrunk = shrunk.compactMap { r in
            guard alive.contains(r.copyID) else { return nil }   // copy deleted by the user
            var r = r
            r.originalDeleted = !alive.contains(r.originalID)
            return r
        }
        save(shrunk, key: "shrunkRecords")
        let rejAlive = PhotoLibraryService.existingIDs(rejected.map(\.originalID))
        rejected.removeAll { !rejAlive.contains($0.originalID) }
        save(rejected, key: "rejectedRecords")
    }

    // MARK: test report (Settings → Test report)

    @Published private(set) var report: [String] = UserDefaults.standard.stringArray(forKey: "testReport") ?? []

    private func appendReport(_ line: String) {
        let stamp = Date().formatted(date: .numeric, time: .shortened)
        report.insert("\(stamp) · \(line)", at: 0)
        if report.count > 300 { report.removeLast(report.count - 300) }
        defaults.set(report, forKey: "testReport")
    }

    func clearReport() {
        report = []
        defaults.removeObject(forKey: "testReport")
    }

    var reportText: String {
        let d = UIDevice.current
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return (["Slash \(version) (\(build)) · \(model) · \(d.systemName) \(d.systemVersion)"] + report).joined(separator: "\n")
    }

    // MARK: persistence + housekeeping

    private func markProcessed(_ id: String) {
        guard !id.isEmpty else { return }
        var set = defaults.stringArray(forKey: "processedAssetIDs") ?? []
        if !set.contains(id) { set.append(id) }
        defaults.set(set, forKey: "processedAssetIDs")
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func freeSpace() -> Int64 {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    /// Leftovers from an interrupted run (app killed mid-encode) would eat space forever.
    static func cleanTemporaryFiles() {
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for f in files where ["mov", "mp4"].contains(f.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
