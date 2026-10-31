#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photos-library import. `PhotosPicker` runs out of process, so no library
/// permission is needed. We ask for the HEIC representation specifically:
/// the default "compatible" transfer re-encodes to JPEG and loses the ProXDR
/// container, which is the whole point of the app.
///
/// Presented from a toolbar menu item through `isPresented`, since a
/// `PhotosPicker` button cannot sit inside a `Menu`.
struct PhotosImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Bindable var model: LibraryModel
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection, maxSelectionCount: 50,
                          matching: .images, preferredItemEncoding: .current)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                let picked = items
                selection = []
                Task { await importPicked(picked) }
            }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            let hasHEIC = item.supportedContentTypes.contains { $0.conforms(to: .heic) || $0.conforms(to: .heif) }
            let hasJPEG = item.supportedContentTypes.contains { $0.conforms(to: .jpeg) }
            guard hasHEIC || hasJPEG else {
                model.lastError = String(localized: "跳过一张不是 HEIC / JPEG 的照片。")
                continue
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let ext = hasHEIC ? "heic" : "jpg"
                let stem = item.itemIdentifier.map { String($0.prefix(8)) } ?? "IMG_\(index + 1)"
                await model.importMaterialised(name: "\(stem).\(ext)", data: data)
            } catch {
                model.lastError = String(localized: "读取照片失败：\(error.localizedDescription)")
            }
        }
    }
}

extension View {
    func photosImport(isPresented: Binding<Bool>, model: LibraryModel) -> some View {
        modifier(PhotosImportModifier(isPresented: isPresented, model: model))
    }
}
#endif
