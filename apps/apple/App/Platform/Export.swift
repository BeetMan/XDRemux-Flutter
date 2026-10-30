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
                ShareLink(item: product.outputURL) {
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
                    NSWorkspace.shared.activateFileViewerSelecting([product.outputURL])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                ShareLink(item: product.outputURL) {
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
            }
            model.markSavedToPhotos(item.id)
            message = "已作为新照片保存到照片库。"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
    #else
    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = product.outputURL.lastPathComponent
        panel.allowedContentTypes = [.heic]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: product.outputURL, to: destination)
            message = "已存储到 \(destination.path)"
        } catch {
            message = "存储失败：\(error.localizedDescription)"
        }
    }
    #endif
}
