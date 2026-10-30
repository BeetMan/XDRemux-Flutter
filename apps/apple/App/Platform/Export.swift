import SwiftUI
import XDRemuxModel
#if os(iOS)
import Photos
#else
import AppKit
#endif

/// Platform export controls for a finished conversion.
/// iOS: save to the Photos library (add-only permission) or share.
/// macOS: save a copy via the save panel, or reveal in Finder.
struct ExportButtons: View {
    @Bindable var model: LibraryModel
    let item: PhotoItem
    let product: ConversionProduct
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                #if os(iOS)
                Button {
                    Task { await saveToPhotos() }
                } label: {
                    Label(item.savedToPhotos ? "已保存到照片" : "保存到照片", systemImage: item.savedToPhotos ? "checkmark" : "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.savedToPhotos)
                ShareLink(items: product.allFiles) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                #else
                Button {
                    saveCopy()
                } label: {
                    Label("存储副本…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(product.allFiles)
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                ShareLink(items: product.allFiles) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                #endif
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    #if os(iOS)
    private func saveToPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "没有写入照片库的权限，可在“设置”里允许。"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = product.outputURL.lastPathComponent
                request.addResource(with: .photo, fileURL: product.outputURL, options: options)
                if let mov = product.pairedVideoURL {
                    let movOptions = PHAssetResourceCreationOptions()
                    movOptions.originalFilename = mov.lastPathComponent
                    request.addResource(with: .pairedVideo, fileURL: mov, options: movOptions)
                }
            }
            for clip in product.extraVideoURLs {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: clip, options: nil)
                }
            }
            model.markSavedToPhotos(item.id)
            message = product.isLivePhoto ? "已作为 Live Photo 保存到照片库。" : "已作为新照片保存到照片库。"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
    #else
    /// Single file: save panel. Live Photo / clips: choose a folder so the
    /// pair keeps its shared stem (Photos matches HEIC + MOV by name).
    private func saveCopy() {
        let files = product.allFiles
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = product.outputURL.lastPathComponent
            panel.allowedContentTypes = [.heic]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            copy(files, to: destination.deletingLastPathComponent(), renamingFirstTo: destination.lastPathComponent)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "存储到此文件夹"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            copy(files, to: folder, renamingFirstTo: nil)
        }
    }

    private func copy(_ files: [URL], to folder: URL, renamingFirstTo firstName: String?) {
        do {
            for (index, file) in files.enumerated() {
                var destination = folder.appendingPathComponent(file.lastPathComponent)
                if index == 0, let firstName { destination = folder.appendingPathComponent(firstName) }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: file, to: destination)
            }
            message = files.count == 1 ? "已存储到 \(folder.path)" : "已存储 \(files.count) 个文件到 \(folder.path)"
        } catch {
            message = "存储失败：\(error.localizedDescription)"
        }
    }
    #endif
}
