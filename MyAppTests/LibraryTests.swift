import CoreLocation
import Photos
import XCTest
@testable import MyApp

/// Real photo library in the simulator: import fixtures, run the app's own batch logic,
/// check that copies carry date, location, favorite and album.
/// Deleting originals is NOT tested: iOS shows a confirmation dialog for it.
@MainActor
final class LibraryTests: XCTestCase {

    let albumName = "MyApp Test Album"
    let testDate = Date(timeIntervalSince1970: 1_754_042_400)   // 2025-08-01 10:00 UTC
    let testLocation = CLLocation(latitude: 53.5511, longitude: 9.9937)

    override func setUp() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        XCTAssertEqual(status, .authorized, "Photo access not granted in the simulator - CI setup problem")
        UserDefaults.standard.removeObject(forKey: "processedAssetIDs")
        UserDefaults.standard.removeObject(forKey: "pendingDeleteIDs")
    }

    func testEndToEndBatch() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sdr_1080p", withExtension: "mov"))
        let album = try await makeAlbum()
        let originalID = try await importVideo(url, into: album)

        let model = LibraryViewModel()
        model.minSizeMB = 1
        model.quality = .bestQuality
        await model.scan()

        let item = try XCTUnwrap(model.items.first { $0.id == originalID }, "imported video not found by scan")
        XCTAssertFalse(item.isSelected, "videos must not be pre-selected")
        model.toggle(item)
        XCTAssertEqual(model.selectedItems.count, 1)

        model.start()
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let s = model.items.first(where: { $0.id == originalID })?.status, s.isFinished, !model.isRunning { break }
        }
        let status = try XCTUnwrap(model.items.first { $0.id == originalID }?.status)
        print("[TEST] end-to-end status: \(status)")
        guard case .done(let saved) = status else { return XCTFail("batch did not finish with .done: \(status)") }
        XCTAssertGreaterThan(saved, 0)
        XCTAssertTrue(model.pendingDeleteIDs.contains(originalID), "original not queued for deletion")

        // find the new copy: same date, not the original
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        var copies: [PHAsset] = []
        PHAsset.fetchAssets(with: opts).enumerateObjects { a, _, _ in
            if a.localIdentifier != originalID, a.creationDate == self.testDate { copies.append(a) }
        }
        let copy = try XCTUnwrap(copies.first, "compressed copy not in library (or date not copied)")
        XCTAssertTrue(copy.isFavorite, "favorite not copied")
        let loc = try XCTUnwrap(copy.location, "location not copied")
        XCTAssertEqual(loc.coordinate.latitude, 53.5511, accuracy: 0.001)
        XCTAssertEqual(loc.coordinate.longitude, 9.9937, accuracy: 0.001)

        var inAlbum = false
        PHAssetCollection.fetchAssetCollectionsContaining(copy, with: .album, options: nil).enumerateObjects { c, _, _ in
            if c.localizedTitle == self.albumName { inAlbum = true }
        }
        XCTAssertTrue(inAlbum, "album membership not copied")
        XCTAssertLessThan(PhotoLibraryService.fileSize(of: copy), PhotoLibraryService.fileSize(of: item.asset))

        // a second scan must not offer the copy or the original again
        await model.scan()
        XCTAssertFalse(model.items.contains { $0.id == originalID || $0.id == copy.localIdentifier },
                       "processed videos offered again")
    }

    // MARK: helpers

    func makeAlbum() async throws -> PHAssetCollection {
        let name = albumName
        let id = Box("")
        try await PHPhotoLibrary.shared().performChanges {
            id.value = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        return try XCTUnwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id.value], options: nil).firstObject)
    }

    func importVideo(_ url: URL, into album: PHAssetCollection) async throws -> String {
        let date = testDate, location = testLocation
        let id = Box("")
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .video, fileURL: url, options: nil)
            req.creationDate = date
            req.location = location
            req.isFavorite = true
            if let ph = req.placeholderForCreatedAsset {
                id.value = ph.localIdentifier
                PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray)
            }
        }
        return id.value
    }
}
