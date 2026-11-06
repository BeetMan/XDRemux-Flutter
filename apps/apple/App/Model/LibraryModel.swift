import CoreGraphics
import Foundation
import Observation
import XDRemuxKit
import XDRemuxModel

/// App state: imported photos, settings, and the conversion pipeline.
/// Platform-neutral; import pickers and export live in `Platform/`.
@MainActor
@Observable
final class LibraryModel {
    var items: [PhotoItem] = [] {
        didSet { persistJournal() }
    }
    var config: ConversionConfig {
        didSet {
            try? settingsStore.save(config)
            engine.setMaxConcurrency(config.maxConcurrentJobs)
            L10n.apply(config.language)
            applyPolicies()
        }
    }

    /// Re-evaluates the Huawei admission policy for every idle photo, e.g.
    /// after Photographic Styles is switched on (which admits Huawei HDR).
    private func applyPolicies() {
        for index in items.indices where items[index].state == .ready {
            items[index].policyReason = Self.policyReason(for: items[index], config: config)
        }
    }

    private static func policyReason(for item: PhotoItem, config: ConversionConfig) -> String? {
        if case .skipped(let reason) = HuaweiPhotoPolicy.admission(item.huawei, config: config, motionPhoto: item.isMotionPhoto) {
            return reason
        }
        return nil
    }
    var selectedID: PhotoItem.ID?
    var lastError: String?
    /// Non-error message for the user (checkpoint import summary).
    var notice: String?
    var isImporting = false
    /// Set by `--round-trip` so the four-step sheet opens at launch (smoke runs).
    var openRoundTripOnLaunch = false
    /// Where published files land; the app folder unless the user chose one.
    private(set) var outputRoot: URL
    var usesCustomOutputDirectory: Bool { outputLocation.isCustom }

    let coreVersion = XDRemuxEngine.coreVersion()
    let directories: AppDirectories

    private let engine: XDRemuxEngine
    private let settingsStore: SettingsStore
    private let journalStore: QueueJournalStore
    private let outputLocation: OutputLocation
    private var convertAllTask: Task<Void, Never>?
    /// Running single-photo conversions, so each can be cancelled.
    private var conversionTasks: [PhotoItem.ID: Task<Void, Never>] = [:]
    private var restoring = false

    init(engine: XDRemuxEngine = .shared,
         settingsStore: SettingsStore = .userDefaults(),
         directories: AppDirectories = .standard,
         outputLocation: OutputLocation = OutputLocation()) {
        self.engine = engine
        self.settingsStore = settingsStore
        self.directories = directories
        self.outputLocation = outputLocation
        self.journalStore = QueueJournalStore(fileURL: directories.journal)
        self.config = settingsStore.load()
        self.outputRoot = directories.outputs
        try? directories.ensureExists()
        L10n.apply(config.language)
        engine.setMaxConcurrency(config.maxConcurrentJobs)
        outputRoot = outputLocation.resolve(fallback: directories.outputs)
        restoreJournal()
    }

    // MARK: - Output directory

    #if os(macOS)
    func chooseOutputDirectory() {
        if let url = outputLocation.chooseDirectory() {
            outputRoot = url
            config.outputDirectory = url.path
        }
    }
    #endif

    func resetOutputDirectory() {
        outputLocation.reset()
        outputRoot = directories.outputs
        config.outputDirectory = nil
    }

    // MARK: - Journal

    /// Rebuilds `items` from the journal, applying the restart rules; then
    /// re-reads classification and thumbnails for each restored input.
    private func restoreJournal() {
        guard let journal = try? journalStore.load()?.resolved(home: NSHomeDirectory()) else { return }
        let restored = journal.restored { FileManager.default.fileExists(atPath: $0) }
        restoring = true
        items = restored.records.map { record in
            var item = PhotoItem(id: record.id, sourceName: record.sourceName,
                                 inputURL: URL(fileURLWithPath: record.inputPath))
            item.savedToPhotos = record.savedToPhotos
            item.motionMode = record.motionMode
            switch record.status {
            case .pending, .running:
                item.state = .inspecting
            case .succeeded:
                if let out = record.outputPath, let outcome = record.outcome {
                    item.state = .done(ConversionProduct(
                        inputURL: item.inputURL, outputURL: URL(fileURLWithPath: out),
                        outcome: outcome, config: record.config ?? ConversionConfig(),
                        pairedVideoURL: record.pairedVideoPath.map(URL.init(fileURLWithPath:)),
                        extraVideoURLs: (record.extraVideoPaths ?? []).map(URL.init(fileURLWithPath:))))
                } else {
                    item.state = .failed(L("记录不完整，请重新转换"))
                }
            case .failed:
                item.state = .failed(record.errorMessage ?? L("失败"))
            }
            return item
        }
        restoring = false
        selectedID = items.first?.id
        let present = items.filter { FileManager.default.fileExists(atPath: $0.inputURL.path) }.map(\.id)
        let cache = inspectionCache
        Task {
            // Cached first (disk only, no core calls), so a library of a few
            // hundred photos is on screen at once; the rest go through the core.
            var uncached: [PhotoItem.ID] = []
            for id in present {
                if let (snapshot, thumbnail) = await Task.detached(priority: .userInitiated, operation: { cache.load(id) }).value {
                    apply(snapshot, thumbnail: thumbnail, to: id, keepState: true)
                } else {
                    uncached.append(id)
                }
            }
            for id in uncached { await inspect(id, keepState: true) }
        }
    }

    private var inspectionCache: InspectionCache { InspectionCache(root: directories.inspections) }

    private func apply(_ snapshot: InspectionSnapshot, thumbnail: CGImage?, to id: PhotoItem.ID, keepState: Bool) {
        let config = self.config
        update(id) { item in
            item.classification = snapshot.classification
            item.inspection = snapshot.inspection
            item.details = snapshot.details
            item.motionPhoto = snapshot.motionPhoto
            item.huawei = snapshot.huawei
            item.thumbnail = thumbnail
            if !keepState || item.state == .inspecting { item.state = .ready }
            item.policyReason = Self.policyReason(for: item, config: config)
        }
    }

    private func persistJournal() {
        guard !restoring else { return }
        let journal = QueueJournal(records: items.map { item in
            let status: QueueJournal.Record.Status
            var output: String?
            var outcome: ConversionOutcome?
            var config: ConversionConfig?
            var paired: String?
            var extras: [String]?
            var error: String?
            switch item.state {
            case .inspecting, .ready: status = .pending
            case .converting: status = .running
            case .done(let p):
                status = .succeeded; output = p.outputURL.path; outcome = p.outcome; config = p.config
                paired = p.pairedVideoURL?.path; extras = p.extraVideoURLs.map(\.path)
            case .failed(let m): status = .failed; error = m
            }
            return QueueJournal.Record(id: item.id, sourceName: item.sourceName, inputPath: item.inputURL.path,
                                       status: status, outputPath: output, outcome: outcome, config: config,
                                       pairedVideoPath: paired, extraVideoPaths: extras, motionMode: item.motionMode,
                                       errorMessage: error, savedToPhotos: item.savedToPhotos)
        })
        do { try journalStore.save(journal.portable(home: NSHomeDirectory())) } catch { lastError = L("无法保存队列状态：\(error.localizedDescription)") }
    }

    var selectedItem: PhotoItem? {
        items.first { $0.id == selectedID }
    }

    var convertibleCount: Int {
        items.filter { $0.isConvertible && $0.state == .ready }.count
    }

    var isConverting: Bool {
        items.contains { if case .converting = $0.state { return true } else { return false } }
    }

    // MARK: - Launch arguments

    /// `XDRemux --import a.heic b.heic [--convert-all]` imports files at
    /// launch (scripting, CI smoke, "open with" from a shell). Paths must be
    /// readable without security scope, so this is a developer/automation
    /// entry, not the user-facing import.
    // MARK: - Flutter checkpoint interop

    /// Imports a Flutter `xdremux_checkpoint.jsonl`. Inputs are copied into
    /// the sandbox like any import; finished outputs are copied into the
    /// outputs folder so the item restores as done. Paths the sandbox cannot
    /// read (no folder grant) become visible failures, like a lost input.
    func importCheckpoint(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let checkpoint = FlutterCheckpoint.parse(jsonl: text) else {
            lastError = L("不是 Flutter 版的检查点文件（xdremux_checkpoint.jsonl）。")
            return
        }
        isImporting = true
        defer { isImporting = false }
        var restored = 0, redo = 0, unreadable = 0
        for record in checkpoint.journalRecords() {
            let input = URL(fileURLWithPath: record.inputPath)
            guard let copy = try? copyIntoInputs(input) else {
                var item = PhotoItem(sourceName: record.sourceName, inputURL: input)
                item.state = .failed(L("无法读取 \(record.inputPath)，请重新导入"))
                items.append(item); unreadable += 1
                continue
            }
            var item = PhotoItem(id: record.id, sourceName: record.sourceName, inputURL: copy)
            item.motionMode = record.motionMode
            if record.status == .succeeded, let out = record.outputPath,
               let published = try? copyOutput(URL(fileURLWithPath: out)) {
                item.state = .done(ConversionProduct(inputURL: copy, outputURL: published,
                                                     outcome: record.outcome ?? ConversionOutcome(success: true), config: config))
                restored += 1
            } else if record.status == .failed {
                item.state = .failed(record.errorMessage ?? L("失败"))
            } else {
                item.state = .inspecting; redo += 1
            }
            items.append(item)
            if selectedID == nil { selectedID = item.id }
            await inspect(item.id, keepState: true)
        }
        notice = L("已导入 Flutter 检查点：\(restored) 张已完成，\(redo) 张待转换，\(unreadable) 张无法读取。")
    }

    /// The native queue as a Flutter checkpoint (paths absolute, as the
    /// Flutter app on this Mac would need them).
    func exportCheckpointJSONL() -> String {
        let journal = (try? journalStore.load()?.resolved(home: NSHomeDirectory())) ?? QueueJournal()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return FlutterCheckpoint.from(journal: journal, config: config, appVersion: "native-\(version)").jsonl()
    }

    private func copyOutput(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let target = OutputPlanner.uniqueURL(outputRoot.appendingPathComponent(url.lastPathComponent)) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// Imports what the Share Extension left in the app-group inbox, then
    /// removes it (the import made its own sandbox copy). iOS only.
    func drainSharedInbox() async {
        #if os(iOS)
        let pending = SharedInbox.pending()
        guard !pending.isEmpty else { return }
        await importFiles(pending)
        for url in pending { try? FileManager.default.removeItem(at: url) }
        #endif
    }

    func handleLaunchArguments(_ arguments: [String] = CommandLine.arguments) async {
        if arguments.contains("--round-trip") { openRoundTripOnLaunch = true }
        guard let start = arguments.firstIndex(of: "--import") else { return }
        let rest = arguments[(start + 1)...]
        let paths = rest.prefix { !$0.hasPrefix("--") }
        await importFiles(paths.map { URL(fileURLWithPath: $0) })
        if rest.contains("--convert-all") {
            convertAll()
        }
    }

    // MARK: - Import

    /// Copies each picked file into the sandbox `inputs/` folder and inspects
    /// it. Security-scoped access is held only for the copy.
    func importFiles(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        for url in urls {
            do {
                let copy = try copyIntoInputs(url)
                let item = PhotoItem(sourceName: url.lastPathComponent, inputURL: copy)
                items.append(item)
                if selectedID == nil { selectedID = item.id }
                await inspect(item.id)
            } catch {
                lastError = L("导入 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
            }
        }
    }

    /// App-private root for the local-transfer service (certificate,
    /// staging, inbox). Next to `inputs`, so it is on the same volume and
    /// survives like the rest of the library.
    var transferRoot: URL {
        directories.inputs.deletingLastPathComponent().appendingPathComponent("transfer", isDirectory: true)
    }

    /// Copies a file into the library under a name of the caller's choosing
    /// (a received transfer: the leased path is called `data`).
    func importFile(at url: URL, named name: String) async {
        do {
            let copy = directories.inputs.appendingPathComponent("\(UUID().uuidString)-\(name)")
            try FileManager.default.copyItem(at: url, to: copy)
            let item = PhotoItem(sourceName: name, inputURL: copy)
            items.append(item)
            if selectedID == nil { selectedID = item.id }
            await inspect(item.id)
        } catch {
            lastError = L("导入 \(name) 失败：\(error.localizedDescription)")
        }
    }

    /// Imports a file the platform layer already materialised (Photos picker
    /// data, share extension inbox).
    func importMaterialised(name: String, data: Data) async {
        do {
            let copy = directories.inputs.appendingPathComponent("\(UUID().uuidString)-\(name)")
            try data.write(to: copy, options: .atomic)
            let item = PhotoItem(sourceName: name, inputURL: copy)
            items.append(item)
            if selectedID == nil { selectedID = item.id }
            await inspect(item.id)
        } catch {
            lastError = L("导入 \(name) 失败：\(error.localizedDescription)")
        }
    }

    /// Public variant for other flows (round trip) that need a sandbox copy
    /// without creating a library item.
    func materialise(_ url: URL) throws -> URL {
        try copyIntoInputs(url)
    }

    /// Strips the UUID prefix `copyIntoInputs` adds, giving back the user's file name.
    func sourceName(of sandboxCopy: URL) -> String {
        let name = sandboxCopy.lastPathComponent
        guard name.count > 37, name[name.index(name.startIndex, offsetBy: 36)] == "-" else { return name }
        return String(name.dropFirst(37))
    }

    private func copyIntoInputs(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = directories.inputs.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    private func inspect(_ id: PhotoItem.ID, keepState: Bool = false) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let path = items[index].inputURL.path
        let url = items[index].inputURL
        async let classification = engine.classify(path: path)
        async let inspection = engine.inspect(path: path)
        async let details = engine.decodedPhotoDetails(path: path)
        async let motion = engine.motionPhotoInfo(path: path)
        async let huawei = engine.huaweiPhotoInfo(path: path)
        let thumbnail = await Task.detached(priority: .utility) {
            ImageLoading.thumbnail(at: url, maxPixelSize: 512)
        }.value
        do {
            let (c, rawInspection, d) = try await (classification, inspection, details)
            let i = await explainInspection(rawInspection, classification: c, path: path)
            let m = try? await motion
            let h = await huawei
            let snapshot = InspectionSnapshot(classification: c, inspection: i, details: d, motionPhoto: m, huawei: h)
            apply(snapshot, thumbnail: thumbnail, to: id, keepState: keepState)
            let cache = inspectionCache
            Task.detached(priority: .utility) { cache.store(id, snapshot: snapshot, thumbnail: thumbnail) }
        } catch {
            update(id) { item in
                item.thumbnail = thumbnail
                if !keepState || item.state == .inspecting { item.state = .failed(L("读取失败：\(String(describing: error))")) }
            }
        }
    }

    /// The core answers "Failed to locate LHDR metadata block" for anything
    /// that is not a ProXDR original: a photo from another phone, a file it
    /// already converted, an edited copy. Say which, as the Flutter app does
    /// at import, instead of showing the English core message.
    private func explainInspection(_ report: ConversionReport, classification: Classification,
                                   path: String) async -> ConversionReport {
        guard !report.success, let raw = report.errorMessage, raw.contains("Failed to locate LHDR") else { return report }
        let message: String
        if (try? await engine.verifyOutput(path: path)) == true {
            message = L("已是转换后的 HDR 照片；如需应用新设置，请选择原始拍摄照片。")
        } else if classification.hdrKind == nil {
            message = L("不是 OPPO ProXDR / Ultra HDR 照片，无法转换。")
        } else {
            message = L("没有找到 ProXDR 的 HDR 数据，可能是编辑或再保存过的副本。")
        }
        return ConversionReport(success: false, mode: report.mode, family: report.family,
                                edrScale: report.edrScale, gainMapMax: report.gainMapMax, errorMessage: message)
    }

    // MARK: - Convert

    func convert(_ id: PhotoItem.ID) async {
        guard let item = items.first(where: { $0.id == id }), !item.state.isBusy,
              conversionTasks[id] == nil else { return }
        let config = self.config
        let job = ConversionJob(backend: engine, scratchRoot: directories.scratch, outputRoot: outputRoot)
        update(id) { $0.state = .converting(0); $0.savedToPhotos = false }
        let task = Task { [weak self] in
            do {
                let mode = item.motionMode ?? config.motionPhotoDefaultMode
                let product = try await job.run(input: item.inputURL, sourceName: item.sourceName, config: config,
                                                motionMode: item.isMotionPhoto ? mode : nil) { fraction in
                    Task { @MainActor [weak self] in
                        self?.update(id) {
                            // Monotonic: the core reports stage 0 between
                            // phases, and a bar that jumps back reads as a
                            // restart.
                            if case .converting(let previous) = $0.state { $0.state = .converting(max(previous, fraction)) }
                        }
                    }
                }
                self?.update(id) { $0.state = .done(product) }
                self?.discardPreview(id)
                self?.autoSaveAfterConvert(id)
            } catch is CancellationError {
                // The core stopped at its next tile; scratch is gone, nothing published.
                self?.update(id) { $0.state = .ready }
            } catch let error as ConversionJobError {
                self?.update(id) { $0.state = .failed(Self.describe(error)) }
            } catch {
                self?.update(id) { $0.state = .failed(String(describing: error)) }
            }
        }
        conversionTasks[id] = task
        await task.value
        conversionTasks[id] = nil
    }

    /// Stops one running conversion (`xdremux_progress_cancel` in the core);
    /// the photo goes back to "ready".
    func cancel(_ id: PhotoItem.ID) {
        conversionTasks[id]?.cancel()
    }

    /// Batch over every ready, convertible item, at most
    /// `config.maxConcurrentJobs` at a time (the engine enforces the same
    /// bound on Rust calls).
    func convertAll() {
        guard convertAllTask == nil else { return }
        let ids = items.filter { $0.isConvertible && $0.state == .ready }.map(\.id)
        let width = max(1, config.maxConcurrentJobs)
        convertAllTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var next = ids.makeIterator()
                for _ in 0..<width {
                    if let id = next.next() { group.addTask { await self.convert(id) } }
                }
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    if let id = next.next() { group.addTask { await self.convert(id) } }
                }
            }
            convertAllTask = nil
            if config.autoSaveToGallery { await saveAllToPhotos() }
        }
    }

    /// Stops the batch: no further photos start and every running one is cancelled.
    func cancelBatch() {
        convertAllTask?.cancel()
        convertAllTask = nil
        for task in conversionTasks.values { task.cancel() }
    }

    func retry(_ id: PhotoItem.ID) async {
        update(id) { $0.state = .ready }
        await convert(id)
    }

    /// Back to the options with the old output gone, so the same photo can
    /// be converted again in another mode without re-importing it.
    func reconvert(_ id: PhotoItem.ID) {
        guard let item = items.first(where: { $0.id == id }), let product = item.product else { return }
        for url in [product.outputURL] + [product.pairedVideoURL].compactMap({ $0 }) + product.extraVideoURLs {
            try? FileManager.default.removeItem(at: url)
        }
        update(id) { $0.state = .ready; $0.savedToPhotos = false }
        Task { await preparePreview(id) }
    }

    func remove(_ id: PhotoItem.ID) {
        guard let item = items.first(where: { $0.id == id }), !item.state.isBusy else { return }
        discardPreview(id)
        inspectionCache.remove(id)
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: item.inputURL)
        if selectedID == id { selectedID = items.first?.id }
    }

    // MARK: - HDR preview before conversion

    private var previewTasks: [PhotoItem.ID: Task<Void, Never>] = [:]

    /// Renders the photo through the core (Apple mode, no styles) into the
    /// cache so the detail page can show the HDR result before the user
    /// converts. Idempotent; the detail page calls it on appear.
    func preparePreview(_ id: PhotoItem.ID) async {
        guard let item = items.first(where: { $0.id == id }),
              item.isConvertible, item.product == nil,
              item.previewState == .none, previewTasks[id] == nil else { return }
        let dir = directories.scratch.appendingPathComponent("previews", isDirectory: true)
        let output = dir.appendingPathComponent("\(id.uuidString).heic")
        update(id) { $0.previewState = .rendering }
        let engine = self.engine
        let input = item.inputURL
        let task = Task.detached(priority: .utility) { [weak self] in
            var ok = false
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let config = RustConvertConfig(oppoCompat: 0, oppoCameraTail: 0, strictTmap: 0,
                                               applePhotographicStyles: 0, applePortrait: 0)
                let report = try await engine.convert(input: input.path, output: output.path, config: config)
                ok = report.success && FileManager.default.fileExists(atPath: output.path)
            } catch {
                ok = false
            }
            let done = ok
            await MainActor.run { [weak self] in
                self?.update(id) {
                    $0.previewURL = done ? output : nil
                    $0.previewState = done ? .ready : .failed
                }
            }
        }
        previewTasks[id] = task
        await task.value
        previewTasks[id] = nil
    }

    /// Drops the cached preview once the real output exists or the photo
    /// leaves the library.
    private func discardPreview(_ id: PhotoItem.ID) {
        previewTasks[id]?.cancel()
        previewTasks[id] = nil
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let url = item.previewURL { try? FileManager.default.removeItem(at: url) }
        update(id) { $0.previewURL = nil; $0.previewState = .none }
    }

    func clearFinished() {
        for item in items where item.product != nil {
            try? FileManager.default.removeItem(at: item.inputURL)
        }
        items.removeAll { $0.product != nil }
        if let selectedID, !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = items.first?.id
        }
    }

    func setMotionMode(_ mode: MotionPhotoMode, for id: PhotoItem.ID) {
        update(id) { $0.motionMode = mode }
    }

    func markSavedToPhotos(_ id: PhotoItem.ID) {
        update(id) { $0.savedToPhotos = true }
    }

    // MARK: - Photos auto-save (iOS)

    /// Finished photos not yet in the library, in queue order.
    var unsavedProducts: [PhotoItem] {
        items.filter { $0.product != nil && !$0.savedToPhotos }
    }

    private var savingToPhotos = false

    /// Settings → 转换完成后自动存入照片. A batch saves once at the end
    /// (like Flutter); a photo converted on its own is saved right away.
    private func autoSaveAfterConvert(_ id: PhotoItem.ID) {
        #if os(iOS)
        guard config.autoSaveToGallery, convertAllTask == nil else { return }
        Task { await saveAllToPhotos() }
        #endif
    }

    /// Saves every finished photo that is not in the library yet (Live
    /// Photo pairs as one asset). The first failure stops the pass and is
    /// reported once; the photos already saved keep their mark.
    func saveAllToPhotos() async {
        #if os(iOS)
        guard !savingToPhotos else { return }
        savingToPhotos = true
        defer { savingToPhotos = false }
        var saved = 0
        for item in unsavedProducts {
            guard let product = item.product else { continue }
            do {
                try await PhotosLibrary.save(product)
                markSavedToPhotos(item.id)
                saved += 1
            } catch {
                notice = L("已存入照片 \(saved) 张；\(item.sourceName) 未存入：\(PhotosLibrary.describe(error))")
                return
            }
        }
        #endif
    }

    // MARK: - Helpers

    private func update(_ id: PhotoItem.ID, _ body: (inout PhotoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private static func describe(_ error: ConversionJobError) -> String {
        switch error {
        case .coreFailed(let message): return message ?? L("内核未给出原因")
        case .verificationFailed: return L("输出未通过结构校验，已丢弃")
        case .styles3Failed(let message): return L("摄影风格 3 后处理失败：\(message ?? "")")
        case .livePhotoFailed(let message): return message ?? L("Live Photo 合成失败")
        case .missingOutput: return L("内核报告成功但没有写出文件")
        case .samePath: return L("输出路径与输入相同")
        }
    }
}

/// Sandbox folders. Inputs and scratch are caches; outputs stay until the
/// user exports or clears them.
struct AppDirectories: Sendable {
    let inputs: URL
    let scratch: URL
    let outputs: URL
    /// Queue journal (`queue.json`), next to outputs so it survives cache purges.
    var journal: URL { outputs.deletingLastPathComponent().appendingPathComponent("queue.json") }
    /// Inspection snapshots + thumbnails (`InspectionCache`), a cache like scratch.
    var inspections: URL { scratch.deletingLastPathComponent().appendingPathComponent("inspections", isDirectory: true) }

    static var standard: AppDirectories {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("XDRemux", isDirectory: true)
        #if os(iOS)
        // Documents is visible in the Files app under "On My iPhone / XDRemux".
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XDRemux", isDirectory: true)
        #endif
        return AppDirectories(
            inputs: caches.appendingPathComponent("inputs", isDirectory: true),
            scratch: caches.appendingPathComponent("scratch", isDirectory: true),
            outputs: base.appendingPathComponent("outputs", isDirectory: true))
    }

    func ensureExists() throws {
        for dir in [inputs, scratch, outputs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
