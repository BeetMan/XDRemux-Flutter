import SwiftUI
import UniformTypeIdentifiers

/// Root layout, chosen by horizontal size class rather than by platform:
/// regular width (Mac, iPad, unfolded phones) is sidebar list + detail;
/// compact width is a list that pushes the detail. Both share `LibraryModel`.
struct ContentView: View {
    @State private var model = LibraryModel()
    @State private var showSettings = false
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var showRoundTrip = false
    @State private var importingCheckpoint = false
    @State private var exportingCheckpoint = false
    @State private var checkpointDocument = TextFileDocument(text: "")
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    #endif

    static let importTypes: [UTType] = [.heic, .heif, .jpeg]

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if isCompact {
                NavigationStack {
                    Group {
                        if model.items.isEmpty {
                            EmptyLibraryView(onImport: { showFileImporter = true })
                        } else {
                            PhotoListView(model: model, pushesDetail: true)
                        }
                    }
                    .navigationDestination(for: PhotoItem.ID.self) { id in
                        PhotoDetailView(model: model, itemID: id)
                    }
                    // Inside the stack: a toolbar attached outside a navigation
                    // context is dropped on iOS (macOS puts it in the window).
                    .toolbar { toolbarContent }
                }
            } else {
                NavigationSplitView {
                    PhotoListView(model: model, pushesDetail: false)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
                        #if os(iOS)
                        .toolbar { toolbarContent }
                        #endif
                } detail: {
                    if let item = model.selectedItem {
                        PhotoDetailView(model: model, itemID: item.id)
                    } else {
                        EmptyLibraryView(onImport: { showFileImporter = true })
                    }
                }
                #if os(macOS)
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await model.importFiles(urls) }
                    return true
                }
                #endif
            }
        }
        #if os(macOS)
        .toolbar { toolbarContent }
        #else
        .photosImport(isPresented: $showPhotosPicker, model: model)
        #endif
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showRoundTrip) {
            RoundTripView(library: model)
        }
        .task {
            await model.handleLaunchArguments()
            if model.openRoundTripOnLaunch { showRoundTrip = true }
            await model.drainSharedInbox()
        }
        #if os(iOS)
        // Photos shared through the extension while the app was in the
        // background are picked up when it comes to the front.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.drainSharedInbox() } }
        }
        #endif
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
        .alert("提示", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .fileImporter(isPresented: $importingCheckpoint, allowedContentTypes: [.json, .plainText, .data]) { result in
            if case .success(let url) = result { Task { await model.importCheckpoint(url) } }
        }
        .fileExporter(isPresented: $exportingCheckpoint, document: checkpointDocument, contentType: .plainText,
                      defaultFilename: FlutterCheckpoint.fileName) { result in
            if case .failure(let error) = result { model.lastError = error.localizedDescription }
        }
    }

    /// HIG: a toolbar carries the few most-used actions and lets the system
    /// lay them out per device (a side rail on devices whose status area is
    /// on the right). Import is one item (a menu on iOS), the batch action is
    /// the one prominent item, and the rest go to `.secondaryAction`, which
    /// iOS folds into an overflow menu. On compact phones the batch action
    /// sits in the bottom bar where the thumb is.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            #if os(iOS)
            Menu {
                Button {
                    showPhotosPicker = true
                } label: {
                    Label("从照片导入", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入", systemImage: "folder")
                }
            } label: {
                Label("导入", systemImage: "plus")
            }
            #else
            Button {
                showFileImporter = true
            } label: {
                Label("导入", systemImage: "plus")
            }
            .help("从文件导入 OPPO 原始照片（也可以拖到窗口里）")
            #endif
        }
        ToolbarItem(placement: batchPlacement) {
            batchActionButton
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                showRoundTrip = true
            } label: {
                Label("一帧影像，动用两台手机", systemImage: "arrow.triangle.2.circlepath.camera")
            }
            .help("OPPO 原始照片 → Apple 编辑副本 → iPhone 编辑 → 写回原机水印与元数据")
            Button {
                importingCheckpoint = true
            } label: {
                Label("导入 Flutter 检查点…", systemImage: "square.and.arrow.down.on.square")
            }
            .help("读取 Flutter 版的 xdremux_checkpoint.jsonl，把它的队列接着转")
            Button {
                checkpointDocument = TextFileDocument(text: model.exportCheckpointJSONL())
                exportingCheckpoint = true
            } label: {
                Label("导出 Flutter 检查点…", systemImage: "square.and.arrow.up.on.square")
            }
            .help("把当前队列写成 Flutter 版能读取的 xdremux_checkpoint.jsonl")
            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "slider.horizontal.3")
            }
        }
    }

    /// Compact phones: bottom bar, where the thumb is. Elsewhere: primary.
    private var batchPlacement: ToolbarItemPlacement {
        #if os(iOS)
        isCompact ? .bottomBar : .primaryAction
        #else
        .primaryAction
        #endif
    }

    /// The one prominent toolbar item: start the batch, or stop it.
    @ViewBuilder
    private var batchActionButton: some View {
        if model.isConverting {
            Button(role: .destructive) {
                model.cancelBatch()
            } label: {
                if isCompact {
                    Text("停止转换").fontWeight(.semibold).padding(.horizontal, 8)
                } else {
                    Label("停止转换", systemImage: "stop.fill")
                }
            }
            .help("停止队列并取消正在进行的转换；已完成的不受影响")
        } else {
            Button {
                model.convertAll()
            } label: {
                let title: LocalizedStringKey = model.convertibleCount > 0 ? "全部转换（\(model.convertibleCount)）" : "全部转换"
                if isCompact {
                    // The bottom bar renders a Label as its icon alone; a
                    // text-only button keeps the name and the count.
                    Text(title).fontWeight(.semibold).padding(.horizontal, 8)
                } else {
                    Label(title, systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.convertibleCount == 0)
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
    /// `true` inside a `NavigationStack` (rows push the detail); `false`
    /// as the sidebar of a split view (rows select).
    var pushesDetail: Bool

    var body: some View {
        Group {
            if pushesDetail {
                List {
                    ForEach(model.items) { item in
                        NavigationLink(value: item.id) {
                            PhotoRow(item: item)
                        }
                        .contextMenu { rowMenu(item) }
                        .swipeActions {
                            Button(role: .destructive) { model.remove(item.id) } label: { Label("移出", systemImage: "trash") }
                                .disabled(item.state.isBusy)
                        }
                    }
                }
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.items) { item in
                        PhotoRow(item: item).tag(item.id)
                            .contextMenu { rowMenu(item) }
                    }
                }
            }
        }
        .navigationTitle("XDRemux")
        #if os(macOS)
        .navigationSubtitle("Rust 内核 \(model.coreVersion)")
        #else
        .navigationBarTitleDisplayMode(pushesDetail ? .large : .inline)
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
