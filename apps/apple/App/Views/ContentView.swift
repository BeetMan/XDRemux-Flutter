import SwiftUI
import UniformTypeIdentifiers
import XDRemuxModel

/// Root layout, chosen by horizontal size class rather than by platform:
/// regular width (Mac, iPad, unfolded phones) is sidebar list + detail;
/// compact width is a list that pushes the detail. Both share `LibraryModel`.
struct ContentView: View {
    @State private var model = LibraryModel()
    @State private var showSettings = false
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var showRoundTrip = false
    @State private var showOrganize = false
    @State private var showTransfer = false
    /// Regular width (iPad, unfolded phones): both columns up from the
    /// start. Left to its default the split view opens with the sidebar
    /// hidden on an unfolded phone, leaving a lone toolbar capsule.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Window width, for the narrow-regular rule below.
    @State private var windowWidth: CGFloat = 0
    /// Below this width (an unfolded phone, a narrow iPad split) the sidebar
    /// and the two-column detail cannot both fit while leaving the photo a
    /// useful size, so opening a photo hides the sidebar; the toolbar's
    /// sidebar button brings the list back. Wider windows keep both.
    static let narrowRegularWidth: CGFloat = 1000
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    #endif

    static let importTypes: [UTType] = [.heic, .heif, .jpeg]

    /// The Photos picker exists on iOS only.
    private var photosImportAction: (() -> Void)? {
        #if os(iOS)
        { showPhotosPicker = true }
        #else
        nil
        #endif
    }

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
                            EmptyLibraryView(onImport: { showFileImporter = true },
                                             onImportPhotos: photosImportAction)
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
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    PhotoListView(model: model, pushesDetail: false)
                        // Capped so an unfolded phone keeps room for the
                        // two-column detail; without a max the balanced
                        // style hands the sidebar half the screen.
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 300)
                        #if os(iOS)
                        .toolbar { toolbarContent }
                        #endif
                } detail: {
                    if let item = model.selectedItem {
                        PhotoDetailView(model: model, itemID: item.id)
                    } else {
                        EmptyLibraryView(onImport: { showFileImporter = true },
                                         onImportPhotos: photosImportAction)
                    }
                }
                // Side by side rather than detail-over-sidebar, so the list
                // stays in reach while a photo is open.
                .navigationSplitViewStyle(.balanced)
                #if os(iOS)
                .onChange(of: model.selectedID) { _, id in
                    if id != nil, windowWidth > 0, windowWidth < Self.narrowRegularWidth {
                        withAnimation { columnVisibility = .detailOnly }
                    }
                }
                .onChange(of: windowWidth) { old, new in
                    // Folding back to compact rebuilds as a stack; growing
                    // past the threshold (rotation, iPad resize) restores the list.
                    if new >= Self.narrowRegularWidth, old < Self.narrowRegularWidth {
                        columnVisibility = .all
                    }
                    // First measurement: the selection restored at launch
                    // happened before the width was known.
                    // Set on the next run loop turn: a change made during
                    // the split view's first layout pass is dropped.
                    if old == 0, new > 0, new < Self.narrowRegularWidth, model.selectedID != nil {
                        DispatchQueue.main.async { columnVisibility = .detailOnly }
                    }
                }
                #endif
                #if os(macOS)
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await model.importFiles(urls) }
                    return true
                }
                #endif
            }
        }
        // Strings built in model code (status lines, summaries) are plain
        // `Text(String)`, which SwiftUI does not re-evaluate when only the
        // locale changes; rebuilding the tree on a language switch does.
        .id(model.config.language)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { windowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in windowWidth = w }
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
        .sheet(isPresented: $showOrganize) {
            OrganizeView()
        }
        .sheet(isPresented: $showTransfer) {
            TransferView(library: model)
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
        // In-app language: Text keys resolve against this locale; model
        // strings go through L() (see L10n.swift). Last in the chain so the
        // sheets and alerts above inherit it too.
        .environment(\.locale, model.config.language.localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent)
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
                showOrganize = true
            } label: {
                Label("批量整理", systemImage: "folder.badge.gearshape")
            }
            .help("按拍摄模式把原始照片复制到分类文件夹，不做转换")
            Button {
                showTransfer = true
            } label: {
                Label("局域网传输", systemImage: "wifi")
            }
            .help("与同一局域网内的 XDRemux / LocalSend 设备互传照片")
            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "slider.horizontal.3")
            }
        }
    }

    /// iOS: the bottom bar of the list column, where the thumb is on a
    /// phone and where a text button keeps its name and count on an iPad
    /// or unfolded phone (a `.primaryAction` Label collapses to an icon
    /// there). macOS: the window toolbar.
    private var batchPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .primaryAction
        #endif
    }

    /// Text-only on iOS (see `batchPlacement`); icon + text on macOS.
    private var batchIsTextOnly: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The one prominent toolbar item: start the batch, or stop it.
    @ViewBuilder
    private var batchActionButton: some View {
        if model.isConverting {
            Button(role: .destructive) {
                model.cancelBatch()
            } label: {
                if batchIsTextOnly {
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
                if batchIsTextOnly {
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
    /// iOS only: photos usually live in the library, so that is the
    /// prominent action and Files the secondary one. macOS has no library
    /// source and keeps the single Files button.
    var onImportPhotos: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label("让 ProXDR HEIC 更容易分享", systemImage: "sparkles")
        } description: {
            Text("导入 OPPO 原始照片，转换为通用 HDR 格式后可在 Apple 照片中继续编辑。")
        } actions: {
            if let onImportPhotos {
                VStack(spacing: 12) {
                    Button(action: onImportPhotos) {
                        Label("从照片导入", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: onImport) {
                        Label("从文件导入", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            } else {
                Button("从文件导入", action: onImport)
                    .buttonStyle(.borderedProminent)
            }
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
        // Large in both layouts: as a sidebar column the inline title was
        // crowded out by the toolbar and the column had no name at all
        // (`inlineLarge` loses it the same way).
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
        if item.product != nil {
            Button("重新转换") { model.reconvert(item.id) }
        }
        Button("移出", role: .destructive) { model.remove(item.id) }
            .disabled(item.state.isBusy)
    }
}

struct PhotoRow: View {
    let item: PhotoItem

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ThumbnailView(image: item.thumbnail)
                .frame(width: 60, height: 60)
            // Three lines at body / caption / caption; the spacing keeps
            // them readable as separate lines without outgrowing the thumb.
            VStack(alignment: .leading, spacing: 4) {
                // Middle truncation keeps the distinguishing tail of
                // IMG2026…1729.heic visible in a narrow sidebar.
                Text(item.sourceName).lineLimit(1).truncationMode(.middle).font(.body)
                Text(item.summaryText.isEmpty ? " " : item.summaryText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                statusLine
                    .frame(minHeight: 16, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.state {
        case .converting(let p):
            ProgressView(value: p).progressViewStyle(.linear)
        // An HStack rather than Label: inside the row a Label's icon takes
        // the list's icon alignment and floats away from the text.
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text(item.statusText)
            }
            .font(.caption).foregroundStyle(.green)
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(item.statusText).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.red)
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
