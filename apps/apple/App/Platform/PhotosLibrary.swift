#if os(iOS)
import Foundation
import Photos
import XDRemuxModel

/// Add-only writes to the Photos library, shared by the export buttons and
/// the transfer inbox.
enum PhotosLibrary {
    enum Failure: Error { case notAuthorized }

    /// Saves `still` (with `pairedVideo` as one Live Photo when given) and
    /// each clip as its own video asset. A `nil` still saves only videos.
    /// Returns true when a Live Photo was written.
    @discardableResult
    static func save(still: URL?, pairedVideo: URL? = nil, clips: [URL] = []) async throws -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAuthorized }
        if let still {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = still.lastPathComponent
                request.addResource(with: .photo, fileURL: still, options: options)
                if let mov = pairedVideo {
                    let movOptions = PHAssetResourceCreationOptions()
                    movOptions.originalFilename = mov.lastPathComponent
                    request.addResource(with: .pairedVideo, fileURL: mov, options: movOptions)
                }
            }
        }
        for clip in clips {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = clip.lastPathComponent
                request.addResource(with: .video, fileURL: clip, options: options)
            }
        }
        return still != nil && pairedVideo != nil
    }

    /// A finished conversion: the still with its paired video as one Live
    /// Photo, every extra clip as its own video.
    @discardableResult
    static func save(_ product: ConversionProduct) async throws -> Bool {
        try await save(still: product.outputURL, pairedVideo: product.pairedVideoURL, clips: product.extraVideoURLs)
    }

    static func describe(_ error: Error) -> String {
        if case Failure.notAuthorized = error { return L("没有写入照片库的权限，可在“设置”里允许。") }
        return L("保存失败：\(error.localizedDescription)")
    }
}
#endif
