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
        }
    }
    var selectedID: PhotoItem.ID?
    var lastError: String?
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
        guard let journal = try? journalStore.load() else { return }
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
                    item.state = .failed(String(localized: "记录不完整，请重新转换"))
                }
            case .failed:
                item.state = .failed(record.errorMessage ?? String(localized: "失败"))
            }
            return item
        }
        restoring = false
        selectedID = items.first?.id
        let ids = items.filter { FileManager.default.fileExists(atPath: $0.inputURL.path) }.map(\.id)
        Task { for id in ids { await inspect(id, keepState: true) } }
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
        do { try journalStore.save(journal) } catch { lastError = String(localized: "无法保存队列状态：\(error.localizedDescription)") }
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
                lastError = String(localized: "导入 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
            }
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
            lastError = String(localized: "导入 \(name) 失败：\(error.localizedDescription)")
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
        let thumbnail = await Task.detached(priority: .utility) {
            ImageLoading.thumbnail(at: url, maxPixelSize: 512)
        }.value
        do {
            let (c, i, d) = try await (classification, inspection, details)
            let m = try? await motion
            update(id) { item in
                item.classification = c
                item.inspection = i
                item.details = d
                item.motionPhoto = m
                item.thumbnail = thumbnail
                if !keepState || item.state == .inspecting { item.state = .ready }
            }
        } catch {
            update(id) { item in
                item.thumbnail = thumbnail
                if !keepState || item.state == .inspecting { item.state = .failed(String(localized: "读取失败：\(String(describing: error))")) }
            }
        }
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
                        self?.update(id) { if case .converting = $0.state { $0.state = .converting(fraction) } }
                    }
                }
                self?.update(id) { $0.state = .done(product) }
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

    func remove(_ id: PhotoItem.ID) {
        guard let item = items.first(where: { $0.id == id }), !item.state.isBusy else { return }
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: item.inputURL)
        if selectedID == id { selectedID = items.first?.id }
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

    // MARK: - Helpers

    private func update(_ id: PhotoItem.ID, _ body: (inout PhotoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private static func describe(_ error: ConversionJobError) -> String {
        switch error {
        case .coreFailed(let message): return message ?? String(localized: "内核未给出原因")
        case .verificationFailed: return String(localized: "输出未通过结构校验，已丢弃")
        case .styles3Failed(let message): return String(localized: "摄影风格 3 后处理失败：\(message ?? "")")
        case .livePhotoFailed(let message): return message ?? String(localized: "Live Photo 合成失败")
        case .missingOutput: return String(localized: "内核报告成功但没有写出文件")
        case .samePath: return String(localized: "输出路径与输入相同")
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
