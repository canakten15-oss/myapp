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

    /// Edited/trimmed videos have extra resources; re-encoding the original would lose the edit.
    static func isEdited(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains {
            $0.type == .fullSizeVideo || $0.type == .adjustmentData
        }
    }

    /// Videos worth compressing, biggest first. Call off the main thread.
    static func fetchCandidates(minBytes: Int64, excluding processed: Set<String>) -> [VideoItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)

        var items: [VideoItem] = []
        result.enumerateObjects { asset, _, _ in
            if processed.contains(asset.localIdentifier) { return }
            if asset.mediaSubtypes.contains(.videoHighFrameRate) { return }   // slo-mo
            if asset.mediaSubtypes.contains(.videoTimelapse) { return }
            if asset.sourceType.contains(.typeCloudShared) { return }
            let size = fileSize(of: asset)
            guard size >= minBytes else { return }
            if isEdited(asset) { return }
            items.append(VideoItem(asset: asset, fileSize: size))
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
        var albums: [PHAssetCollection] = []
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
