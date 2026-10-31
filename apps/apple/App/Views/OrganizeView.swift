import SwiftUI
import UniformTypeIdentifiers
import XDRemuxKit
import XDRemuxModel

/// "批量整理": scan a folder of originals, group them by capture mode, and
/// copy them into per-mode folders (Live Photo pairs together). No
/// conversion happens here (Flutter `organize_page.dart`, plan §3 P2).
struct OrganizeView: View {
    @State private var model = OrganizeModel()
    @Environment(\.dismiss) private var dismiss
    @State private var pickingInput = false
    @State private var pickingOutput = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("扫描一个文件夹里的 OPPO 原始照片，按拍摄模式复制到分类文件夹；实况照片连同配对视频一起放在“实况照片”下。不做转换，不改动原文件。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("选择照片文件夹…") { pickingInput = true }
                    Text(model.inputRoot?.path ?? String(localized: "尚未选择")).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("输出到…") { pickingOutput = true }.disabled(model.inputRoot == nil)
                    Text(model.outputRoot?.path ?? String(localized: "默认与照片文件夹相同")).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                if let status = model.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if model.scanning {
                    ProgressView(value: model.progress)
                }
                List {
                    ForEach(model.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.entries, id: \.item.sourceURL) { entry in
                                HStack {
                                    Image(systemName: entry.item.isLivePhoto ? "livephoto" : "photo")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(entry.item.sourceURL.lastPathComponent).lineLimit(1)
                                        Text(entry.isDuplicate ? String(localized: "已在目标位置，跳过") : entry.destination.deletingLastPathComponent().path)
                                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                    }
                                }
                            }
                        }
                    }
                }
                .overlay {
                    if model.groups.isEmpty, !model.scanning {
                        ContentUnavailableView("没有待整理的照片", systemImage: "folder", description: Text("选择一个包含 HEIC / JPEG 的文件夹。"))
                    }
                }
            }
            .padding()
            .navigationTitle("批量整理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.copying ? String(localized: "复制中…") : String(localized: "开始整理")) {
                        Task { await model.execute() }
                    }
                    .disabled(model.groups.isEmpty || model.scanning || model.copying)
                }
            }
            .fileImporter(isPresented: $pickingInput, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { Task { await model.scan(url) } }
            }
            .fileImporter(isPresented: $pickingOutput, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.setOutput(url) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
        .onDisappear { model.releaseAccess() }
    }
}

@MainActor
@Observable
final class OrganizeModel {
    struct Group { var name: String; var entries: [OrganizePlanner.Entry] }

    private(set) var inputRoot: URL?
    private(set) var outputRoot: URL?
    private(set) var groups: [Group] = []
    private(set) var scanning = false
    private(set) var copying = false
    private(set) var progress = 0.0
    var status: String?

    private var items: [OrganizePlanner.Item] = []
    private var scopedURLs: [URL] = []
    private let engine = XDRemuxEngine.shared
    private let supported: Set<String> = ["heic", "heif", "jpg", "jpeg"]

    var layout: OrganizePlanner.Layout {
        .init(stillFolder: String(localized: "静态照片"), liveFolder: String(localized: "实况照片"))
    }

    func scan(_ root: URL) async {
        releaseAccess()
        if root.startAccessingSecurityScopedResource() { scopedURLs.append(root) }
        inputRoot = root
        outputRoot = nil
        scanning = true; progress = 0; items = []; groups = []
        status = String(localized: "正在扫描…")
        defer { scanning = false }

        // Files first (one pass), then classify; a same-stem MOV becomes the
        // paired video only when the content identifiers match.
        var photos: [URL] = []
        var movs: [String: URL] = [:]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let ext = url.pathExtension.lowercased()
                if supported.contains(ext) { photos.append(url) }
                else if ext == "mov" { movs[url.deletingPathExtension().lastPathComponent] = url }
            }
        }
        photos.sort { $0.path < $1.path }
        guard !photos.isEmpty else {
            status = String(localized: "该文件夹下没有找到 HEIC / JPEG 照片")
            return
        }
        var live = 0
        for (index, url) in photos.enumerated() {
            let classification = try? await engine.classify(path: url.path)
            var paired: URL?
            if let mov = movs[url.deletingPathExtension().lastPathComponent],
               (try? await engine.livePhotoPairValid(still: url.path, video: mov.path)) == true {
                paired = mov; live += 1
            }
            items.append(.init(sourceURL: url, folderName: classification?.folderName, pairedVideoURL: paired))
            progress = Double(index + 1) / Double(photos.count)
        }
        let categorized = items.filter { $0.folderName != nil }.count
        status = String(localized: "共 \(items.count) 张照片，\(categorized) 张可分类，\(live) 组实况照片")
        replan()
    }

    func setOutput(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        outputRoot = url
        replan()
    }

    private func replan() {
        guard let root = outputRoot ?? inputRoot else { return }
        let plan = OrganizePlanner.plan(items, root: root, layout: layout) { FileManager.default.fileExists(atPath: $0.path) }
        let uncategorized = String(localized: "（未分类）")
        var byName: [String: [OrganizePlanner.Entry]] = [:]
        for entry in plan { byName[entry.item.folderName ?? uncategorized, default: []].append(entry) }
        groups = byName.keys.sorted { a, b in
            if a == uncategorized { return false }
            if b == uncategorized { return true }
            return a < b
        }.map { Group(name: $0, entries: byName[$0] ?? []) }
    }

    func execute() async {
        guard !copying else { return }
        copying = true; progress = 0
        status = String(localized: "复制中…")
        defer { copying = false }
        let entries = groups.flatMap(\.entries)
        let outcome = await Task.detached(priority: .userInitiated) { [entries] in
            OrganizePlanner.execute(entries) { from, to in
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: from, to: to)
            }
        }.value
        progress = 1
        status = String(localized: "完成：\(outcome.copied) 张已复制，\(outcome.skipped) 张跳过，\(outcome.failed.count) 张失败")
        replan()
    }

    func releaseAccess() {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }
}
