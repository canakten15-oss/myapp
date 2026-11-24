import Foundation
import Photos
import UIKit

/// Everything that touches the user's photo library.
enum PhotoLibraryService {

    // MARK: Access

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static var currentStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: Scan

    /// Original file size from the asset resource. Works for iCloud-only assets too.
    static func fileSize(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .video } ?? resources.first
        return (resource?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    /// False if the original only lives in iCloud and must be downloaded first (needs extra space).
    static func isLocallyAvailable(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .video } ?? resources.first
        return (resource?.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue ?? true
    }

    /// Edited/trimmed videos have extra resources; re-encoding the original would lose the edit.
    static func isEdited(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains {
            $0.type == .fullSizeVideo || $0.type == .adjustmentData
        }
    }

    struct ScanResult {
        var items: [VideoItem]
        var allVideosBytes: Int64
        var allVideosCount: Int
    }

    /// Videos worth compressing, biggest first, plus totals for the library overview. Call off the main thread.
    static func scanLibrary(minBytes: Int64, excluding processed: Set<String>) -> ScanResult {
        var total: Int64 = 0
        var count = 0
        let all = PHFetchOptions()
        all.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        PHAsset.fetchAssets(with: all).enumerateObjects { asset, _, _ in
            total += fileSize(of: asset)
            count += 1
        }
        return ScanResult(items: fetchCandidates(minBytes: minBytes, excluding: processed),
                          allVideosBytes: total, allVideosCount: count)
    }

    /// Videos worth compressing, biggest first. Call off the main thread.
    static func fetchCandidates(minBytes: Int64, excluding processed: Set<String>) -> [VideoItem] {
        let copiesAlbum = compressedAlbumAssetIDs()
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)

        var items: [VideoItem] = []
        result.enumerateObjects { asset, _, _ in
            if processed.contains(asset.localIdentifier) || copiesAlbum.contains(asset.localIdentifier) { return }
            if asset.mediaSubtypes.contains(.videoHighFrameRate) { return }   // slo-mo
            if asset.mediaSubtypes.contains(.videoTimelapse) { return }
            if asset.sourceType.contains(.typeCloudShared) { return }
            let size = fileSize(of: asset)
            guard size >= minBytes else { return }
            if isEdited(asset) { return }
            items.append(VideoItem(asset: asset, fileSize: size, isLocal: isLocallyAvailable(asset)))
        }
        return items.sorted { $0.fileSize > $1.fileSize }
    }

    // MARK: Load original

    /// Loads the unedited original, downloading it from iCloud if needed.
    static func loadOriginal(_ asset: PHAsset, progress: @escaping (Double) -> Void) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in
            DispatchQueue.main.async { progress(value) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    let error = (info?[PHImageErrorKey] as? Error) ?? AppError.loadFailed
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Save

    /// Imports the compressed file as a new asset with the original's date, location,
    /// favorite flag and album memberships. Returns the new asset's local identifier.
    static func saveCompressed(fileURL: URL, basedOn original: PHAsset) async throws -> String {
        let copiesAlbum = try await compressedAlbum()
        var albums: [PHAssetCollection] = [copiesAlbum]
        PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
            .enumerateObjects { collection, _, _ in
                if collection.canPerform(.addContent) { albums.append(collection) }
            }

        let targetAlbums = albums
        let newIdentifier = Box("")
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let resourceOptions = PHAssetResourceCreationOptions()
            resourceOptions.shouldMoveFile = true
            request.addResource(with: .video, fileURL: fileURL, options: resourceOptions)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite

            if let placeholder = request.placeholderForCreatedAsset {
                newIdentifier.value = placeholder.localIdentifier
                for album in targetAlbums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        }
        return newIdentifier.value
    }

    // MARK: "Slash – compressed" album (every copy lands here too, for easy comparison)

    static let compressedAlbumTitle = "Slash – compressed"

    static func compressedAlbum() async throws -> PHAssetCollection {
        if let existing = findCompressedAlbum() { return existing }
        let title = compressedAlbumTitle
        let id = Box("")
        try await PHPhotoLibrary.shared().performChanges {
            id.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id.value], options: nil).firstObject
        else { throw AppError.writerFailed("could not create album") }
        return album
    }

    private static func findCompressedAlbum() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "localizedTitle == %@", compressedAlbumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    private static func compressedAlbumAssetIDs() -> Set<String> {
        guard let album = findCompressedAlbum() else { return [] }
        var ids = Set<String>()
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
        return ids
    }

    static func existingIDs(_ ids: [String]) -> Set<String> {
        var out = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }

    static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: Delete

    /// Deletes originals. iOS shows its own confirmation dialog; nothing is deleted without it.
    /// Deleted items stay in "Recently Deleted" for 30 days.
    static func deleteAssets(withIdentifiers ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    static func totalSize(ofIdentifiers ids: [String]) -> Int64 {
        var total: Int64 = 0
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            total += fileSize(of: asset)
        }
        return total
    }

    // MARK: Thumbnails

    static func thumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: asset, targetSize: size, contentMode: .aspectFill, options: options
        ) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }
}
