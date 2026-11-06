import Foundation
import Observation
import OSLog
import XDRemuxTransfer
#if os(iOS)
import UIKit
#endif

/// UI state over one `TransferService` (LocalSend v2). The service runs
/// only while the transfer sheet is open: receiving binds a LAN port, so
/// it is an explicit, visible state, never something left on in the
/// background. Fingerprints are confirmed per session; nothing is sent to
/// a peer the user has not looked at.
@MainActor @Observable
final class TransferModel {
    struct Progress: Equatable { var bytes: UInt64 = 0; var total: UInt64 = 0 }

    private(set) var service: TransferService?
    private(set) var isReceiving = false
    private(set) var ready: TransferReady?
    private(set) var isBusy = false
    var error: String?

    var interfaces: [LocalInterface] = []
    var selectedInterface: String?
    var port = 53319

    private(set) var discovering = false
    private(set) var discoveryError: String?
    private(set) var peers: [DiscoveredPeer] = []
    var manualAddress = ""
    private(set) var selectedPeer: TransferPeer?
    private(set) var selectedAlias: String?
    /// Set when `connect` probed a peer the user has not yet confirmed.
    var pendingConfirmation: TransferPeer?
    private var confirmed: Set<String> = []

    /// Peers found by `scanSubnet`; kept across multicast updates.
    private var scanned: [String: DiscoveredPeer] = [:]
    private(set) var scanning = false
    private var scanTask: Task<Void, Never>?
    private var receivingSince: Date = .distantPast
    private var autoScanned = false

    private(set) var offers: [TransferOffer] = []
    private(set) var transfers: [TransferSummary] = []
    private(set) var progress: [String: [String: Progress]] = [:]
    private(set) var inbox: [TransferReceipt] = []
    /// Receipts saved to Photos this session (iOS), by receipt id.
    private(set) var savedToPhotos: Set<String> = []
    /// Transient confirmation after a batch action.
    var notice: String?

    private let root: URL
    private let defaults: UserDefaults
    static let aliasKey = "xdremux.transferAlias"
    private let log = Logger(subsystem: "io.github.beetman.xdremux.swiftui", category: "transfer")
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(root: URL, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        customAlias = TransferAlias.clean(defaults.string(forKey: Self.aliasKey))
        try? FileManager.default.removeItem(at: picksRoot)
    }

    // MARK: Picked files

    /// Files chosen with 选择照片 / 选择文件, copied under `root/picks` so
    /// they outlive the picker's temporary copy. Sent along with the
    /// conversion list.
    private(set) var picks: [URL] = []
    private var picksRoot: URL { root.appendingPathComponent("picks", isDirectory: true) }

    /// Copies each pick in under its own name. A Live Photo from the Photos
    /// picker arrives as a `.pvt` folder (still + MOV); it is sent as the two
    /// files sharing the bundle's stem, the way our own Live Photo outputs
    /// travel, so the receiver pairs them by name. A name already picked is
    /// skipped. `securityScoped` is for file-importer URLs.
    func addPicks(_ urls: [URL], securityScoped: Bool = false) {
        var names = Set(picks.map(\.lastPathComponent))
        for url in urls {
            let scoped = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                var sources: [(URL, String)] = []
                if isDirectory.boolValue {
                    guard url.pathExtension.lowercased() == "pvt" else { continue }
                    let stem = url.deletingPathExtension().lastPathComponent
                    // Only the still and the movie travel; the bundle's
                    // metadata.plist stays behind.
                    let parts = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                        .filter { LivePhotoPairing.isStill($0.lastPathComponent) || LivePhotoPairing.isVideo($0.lastPathComponent) }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    sources = parts.map { ($0, "\(stem).\($0.pathExtension)") }
                } else {
                    sources = [(url, url.lastPathComponent)]
                }
                let directory = picksRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (source, name) in sources where !names.contains(name) {
                    let destination = directory.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: source, to: destination)
                    picks.append(destination)
                    names.insert(name)
                }
            } catch {
                self.error = L("无法读取所选文件：\(error.localizedDescription)")
            }
        }
    }

    func removePick(_ url: URL) {
        picks.removeAll { $0 == url }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func clearPicks() {
        picks = []
        try? FileManager.default.removeItem(at: picksRoot)
    }

    /// The user's own name for this device, or `nil` for the system name.
    private(set) var customAlias: String?

    /// Name other devices see: the custom name if set, else the device's.
    var alias: String { customAlias ?? Self.deviceName }

    static var deviceName: String {
        #if os(iOS)
        TransferAlias.clean(UIDevice.current.name) ?? UIDevice.current.model
        #else
        TransferAlias.clean(Host.current().localizedName) ?? "Mac"
        #endif
    }

    /// Saves a new name (blank restores the device name). A running
    /// listener announces the old name, so it restarts to pick up the new one.
    func setAlias(_ name: String?) async {
        let clean = TransferAlias.clean(name)
        guard clean != customAlias else { return }
        customAlias = clean
        if let clean { defaults.set(clean, forKey: Self.aliasKey) } else { defaults.removeObject(forKey: Self.aliasKey) }
        if isReceiving { await startReceiving() }
    }

    var isRunning: Bool { service != nil }

    func refreshInterfaces() {
        interfaces = LocalNetwork.ipv4Interfaces()
        if selectedInterface == nil || !interfaces.contains(where: { $0.address == selectedInterface }) {
            selectedInterface = interfaces.first?.address
        }
    }

    // MARK: Lifecycle

    /// Send-only service on loopback; nothing is reachable from the LAN.
    func ensureLocal() async throws {
        if service != nil { return }
        try await start(bind: "127.0.0.1:0", receiving: false)
    }

    /// Binds the chosen interface so other devices can send to us.
    func startReceiving() async {
        log.info("startReceiving interface=\(self.selectedInterface ?? "nil", privacy: .public) port=\(self.port)")
        guard let address = selectedInterface else {
            error = L("没有可用的局域网地址，请连接 Wi-Fi 后重试。")
            return
        }
        await stop()
        do {
            try await start(bind: "\(address):\(port)", receiving: true)
            receivingSince = .now
            autoScanned = false
            await refreshDiscovery()
        } catch {
            log.error("startReceiving failed: \(Self.code(error), privacy: .public)")
            self.error = Self.describe(error)
        }
    }

    func stopReceiving() async {
        await stop()
    }

    private func start(bind: String, receiving: Bool) async throws {
        let service = TransferService()
        isBusy = true
        defer { isBusy = false }
        log.info("starting transfer service bind=\(bind, privacy: .public) root=\(self.root.path, privacy: .public)")
        let ready = try await service.start(.init(root: root, bind: bind, alias: alias))
        log.info("transfer service ready at \(ready.address, privacy: .public)")
        self.service = service
        self.ready = ready
        self.isReceiving = receiving
        eventTask = Task { [weak self] in
            for await event in await service.events {
                await self?.handle(event)
            }
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh(discovery: true)
            }
        }
        await refresh(discovery: false)
    }

    func stop() async {
        refreshTask?.cancel(); refreshTask = nil
        eventTask?.cancel(); eventTask = nil
        if let service {
            await service.stop()
        }
        service = nil
        ready = nil
        isReceiving = false
        discovering = false
        peers = []
        offers = []
        transfers = []
        progress = [:]
        selectedPeer = nil
        selectedAlias = nil
        confirmed = []
        scanTask?.cancel(); scanTask = nil
        scanned = [:]
        scanning = false
        syncKeepAwake()
    }

    // MARK: Keep awake

    #if os(iOS)
    private var awake = false
    #endif

    /// Phones stop reception when they sleep, so the idle timer is off while
    /// a transfer is moving and this sheet is receiving.
    private func syncKeepAwake() {
        #if os(iOS)
        let active = isReceiving && transfers.contains { !$0.phase.isTerminal }
        guard active != awake else { return }
        awake = active
        UIApplication.shared.isIdleTimerDisabled = active
        #endif
    }

    // MARK: Discovery and peers

    func refreshDiscovery() async {
        guard let service, isReceiving else { return }
        do {
            apply(try await service.discoveryStart(interface: selectedInterface))
        } catch {
            discoveryError = Self.code(error)
            discovering = false
        }
    }

    private func apply(_ snapshot: DiscoverySnapshot) {
        discovering = snapshot.enabled
        discoveryError = snapshot.error
        peers = snapshot.enabled ? snapshot.peers : []
        mergeScanned()
        // Multicast is often blocked (and iOS needs Apple's multicast
        // entitlement), so after a few quiet seconds scan the subnet once.
        if peers.isEmpty, !autoScanned, Date.now.timeIntervalSince(receivingSince) >= 3 {
            autoScanned = true
            scanSubnet()
        }
    }

    private func mergeScanned() {
        for peer in scanned.values where !peers.contains(where: { $0.fingerprint.uppercased() == peer.fingerprint.uppercased() }) {
            peers.append(peer)
        }
    }

    /// Knocks on every /24 neighbour on the LocalSend ports, probes the
    /// responders and keeps the ones that answer as peers. One scan at a
    /// time; a second request while one runs is ignored.
    func scanSubnet() {
        guard isReceiving, scanTask == nil else { return }
        let own = interfaces.map(\.address)
        let targets = SubnetScan.targets(own: own)
        guard !targets.isEmpty else { return }
        scanning = true
        log.info("subnet scan: \(targets.count) targets from \(own.joined(separator: ","), privacy: .public)")
        scanTask = Task { [weak self] in
            let open = await SubnetScan.openPorts(targets)
            guard let self else { return }
            if !Task.isCancelled { await self.identify(open) }
            self.log.info("subnet scan done: open=\(open.map(\.address).joined(separator: ","), privacy: .public) peers=\(self.peers.count)")
            self.scanning = false
            self.scanTask = nil
        }
    }

    private func identify(_ open: [SubnetScan.Target]) async {
        guard let service, let selfFingerprint = ready?.fingerprint.uppercased() else { return }
        for target in open {
            if Task.isCancelled || !isReceiving { return }
            guard let peer = try? await service.probe(address: target.address) else { continue }
            let fingerprint = peer.fingerprint.uppercased()
            if fingerprint == selfFingerprint { continue }
            scanned[fingerprint] = DiscoveredPeer(alias: target.host, address: target.address, fingerprint: peer.fingerprint)
        }
        mergeScanned()
    }

    /// Probes `address` (`IP:port`), then asks for confirmation unless the
    /// fingerprint was confirmed earlier in this session.
    func connect(address: String, alias: String? = nil) async {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard Self.isAddress(trimmed) else { error = L("请输入对方的 IP:端口，例如 192.168.1.20:53317"); return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await ensureLocal()
            guard let service else { return }
            let peer = try await service.probe(address: trimmed)
            selectedAlias = alias
            if confirmed.contains(peer.fingerprint) {
                selectedPeer = peer
            } else {
                selectedPeer = nil
                pendingConfirmation = peer
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    func confirm(_ peer: TransferPeer) {
        confirmed.insert(peer.fingerprint)
        selectedPeer = peer
        pendingConfirmation = nil
    }

    func clearPeer() {
        selectedPeer = nil
        selectedAlias = nil
    }

    // MARK: Send

    func send(_ urls: [URL]) async {
        guard let peer = selectedPeer, confirmed.contains(peer.fingerprint) else {
            error = L("请先连接并确认对方设备。"); return
        }
        guard !urls.isEmpty else { error = L("没有可发送的文件。"); return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await ensureLocal()
            guard let service else { return }
            _ = try await service.send(peer: peer, paths: urls.map(\.path))
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    func retry(_ transfer: TransferSummary) async {
        guard let service, let peer = selectedPeer, confirmed.contains(peer.fingerprint),
              peer.fingerprint == transfer.peerFingerprint else {
            error = L("重试需要先重新连接并确认同一台设备。"); return
        }
        do {
            _ = try await service.retrySend(transferId: transfer.id, peer: peer)
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    func cancel(_ transfer: TransferSummary) async {
        guard let service else { return }
        do {
            try await service.cancel(transferId: transfer.id, direction: transfer.direction)
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Receive

    func decide(_ offer: TransferOffer, accept: Bool) async {
        guard let service else { return }
        do {
            try await service.decide(transferId: offer.sessionId, accept: accept)
            offers.removeAll { $0.id == offer.id }
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    func acceptAll() async {
        for offer in offers { await decide(offer, accept: true) }
    }

    /// Copies a received file into the library under its original name
    /// while holding the receipt lease, then releases it. A `.pvt.zip`
    /// contributes its still.
    func importReceipt(_ receipt: TransferReceipt, into library: LibraryModel) async {
        isBusy = true
        defer { isBusy = false }
        do {
            if isLivePhotoZip(receipt) {
                let temp = try Self.makeTemp()
                defer { try? FileManager.default.removeItem(at: temp) }
                let parts = try await unpack(receipt, into: temp)
                await library.importFile(at: parts.still, named: parts.still.lastPathComponent)
            } else {
                try await withLease(receipt) { path in
                    await library.importFile(at: path, named: receipt.name)
                }
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Queues every received still (and the still of each `.pvt.zip`);
    /// paired videos ride along with the library's own Live Photo handling,
    /// so they are skipped here.
    func importAll(into library: LibraryModel) async {
        var count = 0
        for receipt in inbox where queues(receipt) {
            await importReceipt(receipt, into: library)
            count += 1
        }
        notice = L("已加入 \(count) 张照片")
    }

    /// Whether "add to list" applies: a still, or a Live Photo zip.
    func queues(_ receipt: TransferReceipt) -> Bool {
        LivePhotoPairing.isStill(receipt.name) || isLivePhotoZip(receipt)
    }

    func isLivePhotoZip(_ receipt: TransferReceipt) -> Bool {
        LivePhotoZip.isLivePhotoZip(receipt.name)
    }

    private func unpack(_ receipt: TransferReceipt, into directory: URL) async throws -> LivePhotoZip.Parts {
        var parts: LivePhotoZip.Parts?
        try await withLease(receipt) { path in
            parts = try LivePhotoZip.unpack(path, name: receipt.name, into: directory)
        }
        guard let parts else { throw LivePhotoZip.Failure.invalidLivePhoto }
        return parts
    }

    private static func makeTemp() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    /// The `.mov` received alongside this still, if any (a Live Photo).
    func pairedMovie(for receipt: TransferReceipt) -> TransferReceipt? {
        guard let name = LivePhotoPairing.pairedMovie(for: receipt.name, in: inbox.map(\.name)) else { return nil }
        return inbox.first { $0.name == name }
    }

    func isPairedMovie(_ receipt: TransferReceipt) -> Bool {
        LivePhotoPairing.isPairedMovie(receipt.name, in: inbox.map(\.name))
    }

    /// Whether this receipt gets a "save to Photos" action: stills and
    /// videos, except a video that is saved together with its still.
    func savesToPhotos(_ receipt: TransferReceipt) -> Bool {
        #if os(iOS)
        (LivePhotoPairing.isStill(receipt.name) || LivePhotoPairing.isVideo(receipt.name) || isLivePhotoZip(receipt))
            && !isPairedMovie(receipt)
        #else
        false
        #endif
    }

    #if os(iOS)
    /// Saves one receipt to Photos; a still with its paired `.mov` becomes
    /// one Live Photo. Returns true when a Live Photo was written.
    @discardableResult
    func saveToPhotos(_ receipt: TransferReceipt) async -> Bool? {
        isBusy = true
        defer { isBusy = false }
        guard let temp = try? Self.makeTemp() else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            // The photo library wants real file names; copy out of the private inbox.
            var still: URL?, video: URL?
            if isLivePhotoZip(receipt) {
                let parts = try await unpack(receipt, into: temp)
                still = parts.still
                video = parts.movie
            } else if LivePhotoPairing.isStill(receipt.name) {
                still = try await copyOut(receipt, to: temp)
                if let movie = pairedMovie(for: receipt) { video = try await copyOut(movie, to: temp) }
            } else {
                video = try await copyOut(receipt, to: temp)
            }
            let live = try await PhotosLibrary.save(still: still, pairedVideo: still == nil ? nil : video,
                                                    clips: still == nil ? [video].compactMap { $0 } : [])
            savedToPhotos.insert(receipt.id)
            if let movie = pairedMovie(for: receipt) { savedToPhotos.insert(movie.id) }
            return live
        } catch let failure as LivePhotoZip.Failure {
            self.error = Self.describe(failure)
            return nil
        } catch {
            self.error = PhotosLibrary.describe(error)
            return nil
        }
    }

    func saveAllToPhotos() async {
        var saved = 0, failed = 0
        for receipt in inbox where savesToPhotos(receipt) && !savedToPhotos.contains(receipt.id) {
            if await saveToPhotos(receipt) != nil { saved += 1 } else { failed += 1; error = nil }
        }
        notice = failed > 0 ? L("已存入照片 \(saved) 项，\(failed) 项失败") : L("已存入照片 \(saved) 项")
    }

    private func copyOut(_ receipt: TransferReceipt, to directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent(receipt.name)
        try await withLease(receipt) { path in
            try FileManager.default.copyItem(at: path, to: destination)
        }
        return destination
    }
    #endif

    private func withLease(_ receipt: TransferReceipt, _ body: (URL) async throws -> Void) async throws {
        guard let service else { throw TransferError.closed }
        let lease = try await service.acquireReceipt(id: receipt.id)
        defer { Task { try? await service.releaseReceipt(leaseId: lease.leaseId) } }
        try await body(URL(fileURLWithPath: lease.path))
    }

    func deleteReceipt(_ receipt: TransferReceipt) async {
        guard let service else { return }
        do {
            try await service.deleteReceipt(id: receipt.id)
            inbox.removeAll { $0.id == receipt.id }
        } catch {
            self.error = Self.describe(error)
        }
    }

    func clearInbox() async {
        for receipt in inbox { await deleteReceipt(receipt) }
    }

    // MARK: State

    private func handle(_ event: TransferEvent) {
        switch event.kind {
        case "offer":
            if let offer = event.offer, !offers.contains(where: { $0.id == offer.id }) { offers.append(offer) }
        case "accepted", "session_ended":
            if let id = event.sessionId { offers.removeAll { $0.id == id } }
            Task { await refresh(discovery: false) }
        case "progress":
            if let t = event.transferId, let f = event.fileId {
                progress[t, default: [:]][f] = Progress(bytes: event.bytes ?? 0, total: event.total ?? 0)
            }
        case "committed":
            if let receipt = event.receipt, !inbox.contains(where: { $0.id == receipt.id }) { inbox.insert(receipt, at: 0) }
        case "receipt_deleted":
            if let id = event.receiptId { inbox.removeAll { $0.id == id } }
        case "sent", "failed", "send_started", "prepared", "file_sent":
            Task { await refresh(discovery: false) }
        case "stopped", "fatal":
            Task { await stop() }
            if event.kind == "fatal" { error = L("传输服务异常停止：\(event.code ?? "unknown")") }
        default:
            break
        }
    }

    private func refresh(discovery: Bool) async {
        guard let service else { return }
        do {
            transfers = try await service.snapshot().transfers.sorted { $0.id > $1.id }
            syncKeepAwake()
            let receipts = try await service.receipts()
            inbox = receipts.sorted { $0.id > $1.id }
            if discovery, isReceiving { apply(try await service.discoveryStatus()) }
        } catch TransferError.closed {
            // The service went away underneath us; the stopped event handles it.
        } catch {
            self.error = Self.describe(error)
        }
    }

    func totalProgress(for transfer: TransferSummary) -> Double? {
        guard let files = progress[transfer.id], !files.isEmpty else { return nil }
        let total = files.values.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        return Double(files.values.reduce(0) { $0 + $1.bytes }) / Double(total)
    }

    // MARK: Helpers

    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return false }
        let octets = parts[0].split(separator: ".")
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    static func code(_ error: Error) -> String {
        switch error {
        case TransferError.code(let code), TransferError.startFailed(let code): return code
        case TransferError.status(let s): return "status_\(s)"
        case TransferError.closed: return "closed"
        case TransferError.malformed: return "malformed"
        case TransferError.unsupportedABI: return "unsupported_abi"
        default: return String(describing: error)
        }
    }

    /// Stable core codes → sentences. Unknown codes are shown as-is.
    static func describe(_ error: Error) -> String {
        if let failure = error as? LivePhotoZip.Failure {
            switch failure {
            case .invalidLivePhoto: return L("这个 .pvt.zip 不是有效的 Live Photo 包。")
            case .alreadyExists: return L("同名的 Live Photo 包已存在。")
            }
        }
        if error is ZipArchive.Failure { return L("这个 .pvt.zip 不是有效的 Live Photo 包。") }
        switch code(error) {
        case "port_in_use": return L("端口已被占用，换一个端口再试。")
        case "identity_mismatch": return L("对方设备的证书与之前确认的不一致，请重新连接并核对指纹。")
        case "discovery_unavailable": return L("自动发现不可用，请手动输入对方的 IP:端口。")
        case "network": return L("连不上对方设备，确认两台设备在同一个 Wi-Fi 下，且对方已开启接收。")
        case "declined", "rejected": return L("对方拒绝了这次传输。")
        case "pin_required", "invalid_pin": return L("对方要求 PIN 码。")
        case "closed": return L("传输服务已停止。")
        case "no_space": return L("存储空间不足。")
        case let code: return L("传输失败：\(code)")
        }
    }

    static func phaseText(_ t: TransferSummary) -> String {
        switch t.phase {
        case .preparing: return L("准备中…")
        case .pending: return L("等待对方确认…")
        case .accepted: return L("已接受")
        case .transferring: return L("传输中")
        case .completed: return L("已完成")
        case .failed: return t.error.map { L("失败：\($0)") } ?? L("失败")
        }
    }
}
