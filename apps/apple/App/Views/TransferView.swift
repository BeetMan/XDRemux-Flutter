import SwiftUI
import UniformTypeIdentifiers
import XDRemuxTransfer
#if os(iOS)
import PhotosUI
#endif

/// 局域网传输: send photos to another XDRemux / LocalSend device and
/// receive from one. The service lives only while this sheet is open.
struct TransferView: View {
    @Bindable var library: LibraryModel
    @State private var model: TransferModel
    @State private var sendOriginals = false
    /// The receive switch's own state; `onChange` drives the model so the
    /// switch animates immediately and snaps back if starting fails.
    @State private var receiveSwitch = false
    @State private var renaming = false
    @State private var aliasDraft = ""
    @State private var confirmClear = false
    @State private var pickingFiles = false
    #if os(iOS)
    @State private var pickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    #endif
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel) {
        self.library = library
        _model = State(initialValue: TransferModel(root: library.transferRoot))
    }

    var body: some View {
        NavigationStack {
            Form {
                receiveSection
                if !model.offers.isEmpty { offersSection }
                sendSection
                if !model.transfers.isEmpty { transfersSection }
                inboxSection
            }
            .formStyle(.grouped)
            .navigationTitle("局域网传输")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            model.refreshInterfaces()
        }
        .onDisappear {
            model.clearPicks()
            Task { await model.stop() }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addPicks(urls, securityScoped: true) }
        }
        #if os(iOS)
        .photosPicker(isPresented: $pickingPhotos, selection: $photoSelection,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoSelection = []
            Task { await importPickedMedia(picked) }
        }
        #endif
        .alert("确认设备指纹", isPresented: Binding(get: { model.pendingConfirmation != nil },
                                              set: { if !$0 { model.pendingConfirmation = nil } })) {
            Button("确认并连接") { if let p = model.pendingConfirmation { model.confirm(p) } }
            Button("取消", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            if let p = model.pendingConfirmation {
                Text("对方设备 \(p.address) 的证书指纹：\n\(p.groupedFingerprint)\n\n请与对方屏幕上显示的指纹核对一致后再发送。")
            }
        }
        .alert("出错了", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .alert("设备名", isPresented: $renaming) {
            TextField(TransferModel.deviceName, text: $aliasDraft)
            Button("保存") { Task { await model.setAlias(aliasDraft) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("其他设备看到的名字。留空则使用设备名。")
        }
        .confirmationDialog("清空收件箱？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { Task { await model.clearInbox() } }
        } message: {
            Text("删除收件箱里的 \(model.inbox.count) 个文件。已存入照片或加入列表的副本不受影响。")
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    // MARK: Sections

    private var receiveSection: some View {
        Section {
            Toggle("在局域网接收", isOn: $receiveSwitch)
                .disabled(model.isBusy || model.interfaces.isEmpty)
                .onChange(of: receiveSwitch) { _, on in
                    Task {
                        if on { await model.startReceiving() } else { await model.stopReceiving() }
                        receiveSwitch = model.isReceiving
                    }
                }
                .onChange(of: model.isReceiving) { _, on in receiveSwitch = on }
            LabeledContent("设备名") {
                Button {
                    aliasDraft = model.customAlias ?? ""
                    renaming = true
                } label: {
                    HStack(spacing: 4) {
                        Text(model.alias).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "pencil").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isBusy)
            }
            if model.interfaces.count > 1 {
                Picker("网络", selection: $model.selectedInterface) {
                    ForEach(model.interfaces) { i in
                        Text(verbatim: "\(i.address) (\(i.name))").tag(Optional(i.address))
                    }
                }
                .disabled(model.isReceiving)
            }
            if !model.isReceiving {
                LabeledContent("端口") {
                    // Empty title: macOS would print the label twice.
                    TextField("", value: $model.port, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
            }
            if model.isReceiving, let ready = model.ready {
                LabeledContent("本机地址", value: ready.address)
                LabeledContent("本机指纹") {
                    Text(TransferPeer(address: ready.address, fingerprint: ready.fingerprint).groupedFingerprint)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("接收")
        } footer: {
            if model.interfaces.isEmpty {
                Text("没有可用的局域网地址，请先连接 Wi-Fi。")
            } else if model.isReceiving {
                Text("对方在 XDRemux 或 LocalSend 里输入本机地址即可发送；每次传输都需要你在这里接受。")
            } else {
                Text("开启后本机会在局域网监听这个端口；离开此页即停止。")
            }
        }
    }

    private var offersSection: some View {
        Section("待接收") {
            if model.offers.count > 1 {
                Button("接收全部") { Task { await model.acceptAll() } }
            }
            ForEach(model.offers) { offer in
                VStack(alignment: .leading, spacing: 6) {
                    Text(offer.alias).font(.headline)
                    Text("\(offer.files.count) 个文件 · \(offer.totalBytes.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(offer.files.map(\.name).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Button("接收") { Task { await model.decide(offer, accept: true) } }
                            .buttonStyle(.borderedProminent)
                        Button("拒绝", role: .destructive) { Task { await model.decide(offer, accept: false) } }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var sendSection: some View {
        Section {
            ForEach(model.peers) { peer in
                Button {
                    Task { await model.connect(address: peer.address, alias: peer.alias) }
                } label: {
                    HStack {
                        Label(peer.alias, systemImage: "iphone.gen3")
                        Spacer()
                        Text(peer.address).font(.caption).foregroundStyle(.secondary)
                        if model.selectedPeer?.fingerprint == peer.fingerprint {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(model.isBusy)
            }
            HStack {
                TextField("对方 IP:端口", text: $model.manualAddress)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button("连接") { Task { await model.connect(address: model.manualAddress) } }
                    .disabled(model.isBusy || model.manualAddress.isEmpty)
            }
            if model.isReceiving {
                Button {
                    model.scanSubnet()
                } label: {
                    HStack {
                        Label("扫描网段", systemImage: "dot.radiowaves.left.and.right")
                        if model.scanning {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.scanning)
            }
            if let peer = model.selectedPeer {
                LabeledContent(model.selectedAlias ?? peer.address) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(peer.shortFingerprint).font(.caption.monospaced())
                    }
                }
                Picker("发送内容", selection: $sendOriginals) {
                    Text("转换结果").tag(false)
                    Text("原始照片").tag(true)
                }
                .pickerStyle(.segmented)
                HStack {
                    #if os(iOS)
                    Button {
                        pickingPhotos = true
                    } label: {
                        Label("选择照片", systemImage: "photo.on.rectangle")
                    }
                    #endif
                    Button {
                        pickingFiles = true
                    } label: {
                        Label("选择文件", systemImage: "paperclip")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy)
                ForEach(model.picks, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            model.removePick(url)
                        } label: {
                            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                    }
                }
                let urls = filesToSend
                Button {
                    Task { await model.send(urls) }
                } label: {
                    Label(urls.isEmpty ? "没有可发送的文件" : "发送 \(urls.count) 个文件", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(urls.isEmpty || model.isBusy)
            }
        } header: {
            Text("发送到")
        } footer: {
            if model.scanning {
                Text("正在逐个尝试本网段的地址，大约需要十几秒…")
            } else if model.isReceiving, let error = model.discoveryError {
                Text(error == "discovery_unavailable"
                     ? "自动发现在这台设备上不可用（需要 Apple 的多播授权）。可以扫描网段，或手动输入对方的 IP:端口。"
                     : "自动发现失败：\(error)。可以扫描网段，或手动输入对方的 IP:端口。")
            } else if model.isReceiving, model.discovering, model.peers.isEmpty {
                Text("正在查找同一局域网内开启了接收的设备；几秒后没找到会自动扫描网段。")
            } else if !model.isReceiving {
                Text("只发送不接收时不会监听端口。开启接收后会自动查找附近设备。")
            }
        }
    }

    private var transfersSection: some View {
        Section("传输记录") {
            ForEach(model.transfers) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: t.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundStyle(t.phase == .failed ? Color.red : (t.phase == .completed ? Color.green : Color.accentColor))
                        Text(t.alias ?? t.peerFingerprint.map { String($0.prefix(8)) } ?? "—")
                        Spacer()
                        Text("\(t.fileCount) 个文件").font(.caption).foregroundStyle(.secondary)
                    }
                    if !t.phase.isTerminal, let p = model.totalProgress(for: t) {
                        ProgressView(value: p)
                    }
                    HStack {
                        Text(TransferModel.phaseText(t)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !t.phase.isTerminal {
                            Button("取消") { Task { await model.cancel(t) } }.controlSize(.small)
                        } else if t.phase == .failed, t.retryAvailable == true, t.direction == .send {
                            Button("重试") { Task { await model.retry(t) } }.controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var inboxSection: some View {
        Section {
            if model.inbox.isEmpty {
                Text(model.isRunning ? "还没有收到文件。" : "开启接收后，收到的文件会出现在这里。")
                    .foregroundStyle(.secondary)
            } else {
                inboxActions
            }
            ForEach(model.inbox) { receipt in
                inboxRow(receipt)
                    .swipeActions {
                        Button(role: .destructive) { Task { await model.deleteReceipt(receipt) } } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("删除", role: .destructive) { Task { await model.deleteReceipt(receipt) } }
                    }
            }
        } header: {
            Text("收件箱")
        } footer: {
            if let notice = model.notice {
                Text(notice)
            } else {
                Text("收到的文件保存在 App 内部，加入照片列表后可以转换；删除只影响这里的副本。")
            }
        }
    }

    private var inboxActions: some View {
        HStack {
            #if os(iOS)
            Button("全部存入照片") { Task { await model.saveAllToPhotos() } }
                .disabled(!model.inbox.contains { model.savesToPhotos($0) && !model.savedToPhotos.contains($0.id) })
            #endif
            Button("全部加入列表") { Task { await model.importAll(into: library) } }
                .disabled(!model.inbox.contains { model.queues($0) })
            Spacer()
            Button("清空", role: .destructive) { confirmClear = true }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isBusy)
    }

    private func inboxRow(_ receipt: TransferReceipt) -> some View {
        let pairedMovie = model.pairedMovie(for: receipt)
        let isPairedMovie = model.isPairedMovie(receipt)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if pairedMovie != nil || model.isLivePhotoZip(receipt) {
                        Text("Live Photo · ")
                    } else if isPairedMovie {
                        Text("Live Photo 视频，随同名照片一起处理 · ")
                    }
                    Text(receipt.size.formatted(.byteCount(style: .file)))
                    if model.savedToPhotos.contains(receipt.id) {
                        Text("· 已存入照片")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            #if os(iOS)
            if model.savesToPhotos(receipt), !model.savedToPhotos.contains(receipt.id) {
                Button("存入照片") { Task { await model.saveToPhotos(receipt) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            #endif
            if model.queues(receipt) {
                Button("加入列表") { Task { await model.importReceipt(receipt, into: library) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .disabled(model.isBusy)
    }

    // MARK: Helpers

    /// Converted outputs (plus their Live Photo videos) by default; the
    /// imported originals when asked.
    /// The conversion list (originals or results) plus every picked file.
    private var filesToSend: [URL] {
        let queue: [URL]
        if sendOriginals {
            queue = library.items.map(\.inputURL)
        } else {
            queue = library.items.compactMap(\.product).flatMap { product in
                [product.outputURL] + (product.pairedVideoURL.map { [$0] } ?? []) + product.extraVideoURLs
            }
        }
        return queue + model.picks
    }

    #if os(iOS)
    /// Each pick comes over as a file copy (a Live Photo as a `.pvt` folder)
    /// that the model copies into its own folder; the picker's copy goes.
    private func importPickedMedia(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let media = try await item.loadTransferable(type: PickedMedia.self) else { continue }
                model.addPicks([media.url])
                try? FileManager.default.removeItem(at: media.url.deletingLastPathComponent())
            } catch {
                model.error = L("无法读取所选文件：\(error.localizedDescription)")
            }
        }
    }
    #endif
}

#if os(iOS)
/// What the Photos picker hands over for 选择照片: the original file under
/// its own name, or for a Live Photo the `.pvt` folder with the still and
/// its MOV. The file only exists inside the import closure, so it is copied
/// out right there.
private struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("XDRemuxTransferPicks", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMedia(url: copy)
        }
    }
}
#endif
