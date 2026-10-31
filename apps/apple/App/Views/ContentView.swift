import SwiftUI
import UniformTypeIdentifiers

/// Root layout. macOS: sidebar list + detail. iPhone/iPad: list that pushes
/// the detail. Both share `LibraryModel`.
struct ContentView: View {
    @State private var model = LibraryModel()
    @State private var showSettings = false
    @State private var showFileImporter = false
    @State private var showRoundTrip = false

    static let importTypes: [UTType] = [.heic, .heif, .jpeg]

    var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                PhotoListView(model: model)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } detail: {
                if let item = model.selectedItem {
                    PhotoDetailView(model: model, itemID: item.id)
                } else {
                    EmptyLibraryView(onImport: { showFileImporter = true })
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.importFiles(urls) }
                return true
            }
            #else
            NavigationStack {
                Group {
                    if model.items.isEmpty {
                        EmptyLibraryView(onImport: { showFileImporter = true })
                    } else {
                        PhotoListView(model: model)
                    }
                }
                .navigationDestination(for: PhotoItem.ID.self) { id in
                    PhotoDetailView(model: model, itemID: id)
                }
            }
            #endif
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showRoundTrip) {
            RoundTripView(library: model)
        }
        .task {
            await model.handleLaunchArguments()
            if model.openRoundTripOnLaunch { showRoundTrip = true }
        }
        // Finder "Open With", Dock drop, and iOS "Open in XDRemux" hand files here.
        .onOpenURL { url in
            Task { await model.importFiles([url]) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.importFiles(urls) }
            }
        }
        .alert("出错了", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("好") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(iOS)
            PhotosImportButton(model: model)
            #endif
            Button {
                showFileImporter = true
            } label: {
                Label("从文件导入", systemImage: "folder.badge.plus")
            }
            if model.isConverting {
                Button {
                    model.cancelBatch()
                } label: {
                    Label("停止转换", systemImage: "stop.fill")
                }
                .help("停止队列并取消正在进行的转换；已完成的不受影响")
            } else {
                Button {
                    model.convertAll()
                } label: {
                    Label("全部转换", systemImage: "play.fill")
                }
                .disabled(model.convertibleCount == 0)
            }
            Button {
                showRoundTrip = true
            } label: {
                Label("一帧影像，动用两台手机", systemImage: "arrow.triangle.2.circlepath.camera")
            }
            .help("OPPO 原始照片 → Apple 编辑副本 → iPhone 编辑 → 写回原机水印与元数据")
            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "slider.horizontal.3")
            }
        }
    }
}

struct EmptyLibraryView: View {
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("让 ProXDR HEIC 更容易分享", systemImage: "sparkles")
        } description: {
            Text("导入 OPPO 原始照片，转换为通用 HDR 格式后可在 Apple 照片中继续编辑。")
        } actions: {
            Button("从文件导入", action: onImport)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The library list: one row per imported photo.
struct PhotoListView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        #if os(macOS)
        List(selection: $model.selectedID) {
            ForEach(model.items) { item in
                PhotoRow(item: item).tag(item.id)
                    .contextMenu { rowMenu(item) }
            }
        }
        .navigationTitle("XDRemux")
        .navigationSubtitle("Rust 内核 \(model.coreVersion)")
        #else
        List {
            ForEach(model.items) { item in
                NavigationLink(value: item.id) {
                    PhotoRow(item: item)
                }
                .swipeActions {
                    Button(role: .destructive) { model.remove(item.id) } label: { Label("移出", systemImage: "trash") }
                        .disabled(item.state.isBusy)
                }
            }
        }
        .navigationTitle("XDRemux")
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    @ViewBuilder
    private func rowMenu(_ item: PhotoItem) -> some View {
        if item.isConvertible, item.state == .ready {
            Button("转换这张") { Task { await model.convert(item.id) } }
        }
        if case .converting = item.state {
            Button("取消转换") { model.cancel(item.id) }
        }
        if case .failed = item.state {
            Button("重试") { Task { await model.retry(item.id) } }
        }
        Button("移出", role: .destructive) { model.remove(item.id) }
            .disabled(item.state.isBusy)
    }
}

struct PhotoRow: View {
    let item: PhotoItem

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(image: item.thumbnail)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.sourceName).lineLimit(1).font(.body)
                Text(item.summaryText.isEmpty ? " " : item.summaryText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                statusLine
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.state {
        case .converting(let p):
            ProgressView(value: p).progressViewStyle(.linear)
        case .done:
            Label(item.statusText, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed:
            Label(item.statusText, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(1)
        default:
            Text(item.statusText).font(.caption).foregroundStyle(item.isConvertible ? Color.secondary : Color.orange)
        }
    }
}

struct ThumbnailView: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
    }
}
