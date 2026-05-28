import Foundation
import SwiftUI
import Observation
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum AppState: Equatable {
    case idle
    case scanning
    case processing
    case completed
    case cancelled
}

enum ConversionQueueStatus: String, Sendable, Equatable {
    case pending
    case running
    case converted
    case skippedExisting
    case failed
    case cancelled

    var isRunnable: Bool {
        switch self {
        case .pending:
            return true
        case .running, .converted, .skippedExisting, .failed, .cancelled:
            return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .converted, .skippedExisting, .failed, .cancelled:
            return true
        case .pending, .running:
            return false
        }
    }
}

enum OutputPlanStatus: String, Sendable, Equatable {
    case ready
    case willOverwriteExisting
    case skipsExistingValidOutput
    case duplicateOutput
    case inputMissing
    case outputParentIsFile

    var blocksConversion: Bool {
        switch self {
        case .duplicateOutput, .inputMissing, .outputParentIsFile:
            return true
        case .ready, .willOverwriteExisting, .skipsExistingValidOutput:
            return false
        }
    }
}

enum OutputPreparationDisposition: String, Sendable, Equatable {
    case ready
    case skippedExistingValidOutput
    case removedExistingInvalidOutput
}

enum ThumbnailStatus: Equatable {
    case empty
    case loading
    case ready(NSImage)
    case failed(String)

    static func == (lhs: ThumbnailStatus, rhs: ThumbnailStatus) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.loading, .loading):
            return true
        case (.ready(let left), .ready(let right)):
            return left === right
        case (.failed(let left), .failed(let right)):
            return left == right
        default:
            return false
        }
    }
}

struct ConversionQueueItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let inputURL: URL
    var outputURL: URL
    var status: ConversionQueueStatus
    var outputPlanStatus: OutputPlanStatus
    var errorMessage: String?
    var startedAt: Date?
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        inputURL: URL,
        outputURL: URL,
        status: ConversionQueueStatus = .pending,
        outputPlanStatus: OutputPlanStatus = .ready,
        errorMessage: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.status = status
        self.outputPlanStatus = outputPlanStatus
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    var isSuccessful: Bool {
        status == .converted || status == .skippedExisting
    }

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

@Observable
@MainActor
final class XDRemuxViewModel {
    var state: AppState = .idle
    var currentFileName: String = ""
    var config = ConversionConfig()
    var queue: [ConversionQueueItem] = []
    var currentConcurrency: Int = 0
    var thumbnailStatusByID: [UUID: ThumbnailStatus] = [:]

    var totalFiles: Int { queue.count }

    var processedCount: Int {
        queue.filter { $0.status.isTerminal }.count
    }

    var pendingCount: Int {
        queue.filter { $0.status == .pending }.count
    }

    var runningCount: Int {
        queue.filter { $0.status == .running }.count
    }

    var convertedCount: Int {
        queue.filter { $0.status == .converted }.count
    }

    var skippedCount: Int {
        queue.filter { $0.status == .skippedExisting }.count
    }

    var failedCount: Int {
        queue.filter { $0.status == .failed }.count
    }

    var cancelledCount: Int {
        queue.filter { $0.status == .cancelled }.count
    }

    var progressFraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedCount) / Double(totalFiles)
    }

    var canStart: Bool {
        !isBusy && queue.contains {
            ($0.status == .pending || $0.status == .failed || $0.status == .cancelled) &&
            !$0.outputPlanStatus.blocksConversion
        }
    }

    var canEditQueue: Bool {
        !isBusy
    }

    var isBusy: Bool {
        state == .scanning || state == .processing
    }

    var visibleErrors: [String] {
        queue
            .reversed()
            .filter { $0.status == .failed }
            .prefix(5)
            .map { "\($0.inputURL.lastPathComponent): \($0.errorMessage ?? "未知错误")" }
    }

    private var processTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    func addFiles(from urls: [URL]) {
        guard canEditQueue else { return }
        importTask?.cancel()
        importTask = Task { [weak self] in
            _ = await self?.importFiles(from: urls)
        }
    }

    @discardableResult
    func importFiles(from urls: [URL]) async -> Int {
        guard canEditQueue else { return 0 }
        state = .scanning
        currentFileName = "正在扫描 HEIC 文件..."

        let heicURLs = await Task.detached(priority: .userInitiated) {
            Self.collectHEICURLs(from: urls)
        }.value

        if Task.isCancelled {
            state = queue.isEmpty ? .idle : .cancelled
            currentFileName = "已取消扫描"
            return 0
        }

        let existingInputs = Set(queue.map { Self.pathKey($0.inputURL) })
        let newItems = heicURLs
            .filter { !existingInputs.contains(Self.pathKey($0)) }
            .map {
                let outputURL = Self.makeOutputURL(for: $0, config: config)
                return ConversionQueueItem(
                    inputURL: $0,
                    outputURL: outputURL,
                    outputPlanStatus: Self.outputPlanStatus(inputURL: $0, outputURL: outputURL, config: config)
                )
            }

        queue.append(contentsOf: newItems)
        refreshOutputURLsAndPlansForEditableItems()
        currentFileName = newItems.isEmpty ? "没有新增 ProXDR HEIC 文件" : "已添加 \(newItems.count) 个 ProXDR HEIC 文件"
        state = .idle
        return newItems.count
    }

    func startConversion() {
        guard canStart else { return }
        retryFailed()
        resetCancelledToPending()
        processTask?.cancel()
        processTask = Task { [weak self] in
            await self?.runQueue()
        }
    }

    func cancelTask() {
        guard state == .processing || state == .scanning else { return }
        importTask?.cancel()
        processTask?.cancel()
        markPendingAsCancelled()
        state = .cancelled
        currentFileName = runningCount > 0 ? "正在等待当前文件结束..." : AppStrings.statCancelled
    }

    func acknowledgeCompletion() {
        if state == .completed || state == .cancelled {
            state = .idle
            currentFileName = ""
        }
    }

    func clearQueue() {
        guard canEditQueue else { return }
        queue.removeAll()
        thumbnailStatusByID.removeAll()
        currentFileName = ""
        state = .idle
    }

    func clearCompleted() {
        guard canEditQueue else { return }
        let removedIDs = Set(queue.filter { $0.status == .converted || $0.status == .skippedExisting }.map(\.id))
        queue.removeAll { $0.status == .converted || $0.status == .skippedExisting }
        for id in removedIDs {
            thumbnailStatusByID.removeValue(forKey: id)
        }
        if queue.isEmpty {
            state = .idle
            currentFileName = ""
        }
    }

    func retryFailed() {
        guard canEditQueue || state == .idle || state == .completed || state == .cancelled else { return }
        for index in queue.indices where queue[index].status == .failed {
            queue[index].status = .pending
            queue[index].errorMessage = nil
            queue[index].startedAt = nil
            queue[index].finishedAt = nil
            queue[index].outputURL = Self.makeOutputURL(for: queue[index].inputURL, config: config)
            queue[index].outputPlanStatus = Self.outputPlanStatus(inputURL: queue[index].inputURL, outputURL: queue[index].outputURL, config: config)
        }
        refreshOutputURLsAndPlansForEditableItems()
    }

    func removeQueueItem(id: UUID) {
        guard canEditQueue else { return }
        queue.removeAll { $0.id == id }
        thumbnailStatusByID.removeValue(forKey: id)
        refreshOutputURLsAndPlansForEditableItems()
        if queue.isEmpty {
            state = .idle
            currentFileName = ""
        }
    }

    func refreshOutputURLsForPendingItems() {
        guard canEditQueue else { return }
        refreshOutputURLsAndPlansForEditableItems()
    }

    func thumbnailStatus(for id: UUID) -> ThumbnailStatus {
        thumbnailStatusByID[id] ?? .empty
    }

    func loadThumbnailIfNeeded(for item: ConversionQueueItem) {
        switch thumbnailStatus(for: item.id) {
        case .empty:
            thumbnailStatusByID[item.id] = .loading
        case .loading, .ready, .failed:
            return
        }

        let id = item.id
        let inputURL = item.inputURL
        Task.detached(priority: .utility) { [weak self] in
            do {
                let imageData = try Self.makeThumbnailPNGData(for: inputURL, maxPixelSize: 320)
                await self?.applyThumbnailData(id: id, inputURL: inputURL, data: imageData)
            } catch {
                await self?.applyThumbnailFailure(id: id, inputURL: inputURL, message: Self.describe(error))
            }
        }
    }

    @discardableResult
    func applyThumbnailFailureForTesting(id: UUID, inputURL: URL, message: String) -> Bool {
        applyThumbnailFailure(id: id, inputURL: inputURL, message: message)
    }

    nonisolated static func prepareOutputForConversionForTesting(
        inputURL: URL,
        outputURL: URL,
        skipExisting: Bool
    ) throws -> OutputPreparationDisposition {
        try prepareOutputForConversion(inputURL: inputURL, outputURL: outputURL, skipExisting: skipExisting)
    }

    nonisolated static func makeThumbnailPNGDataForTesting(for url: URL, maxPixelSize: Int) throws -> Data {
        try makeThumbnailPNGData(for: url, maxPixelSize: maxPixelSize)
    }

    private func refreshOutputURLsAndPlansForEditableItems() {
        for index in queue.indices where queue[index].status == .pending || queue[index].status == .failed || queue[index].status == .cancelled {
            queue[index].outputURL = Self.makeOutputURL(for: queue[index].inputURL, config: config)
            queue[index].outputPlanStatus = Self.outputPlanStatus(
                inputURL: queue[index].inputURL,
                outputURL: queue[index].outputURL,
                config: config
            )
        }
        markDuplicateOutputPlans()
    }

    private func markDuplicateOutputPlans() {
        var indexesByOutput: [String: [Int]] = [:]
        for index in queue.indices where queue[index].status == .pending || queue[index].status == .failed || queue[index].status == .cancelled {
            indexesByOutput[Self.pathKey(queue[index].outputURL), default: []].append(index)
        }

        for (_, indexes) in indexesByOutput where indexes.count > 1 {
            for index in indexes {
                queue[index].outputPlanStatus = .duplicateOutput
            }
        }
    }

    @discardableResult
    func markOutputCollisionsForTesting() -> Int {
        refreshOutputURLsForPendingItems()
        return markOutputCollisions()
    }

    func effectiveConcurrencyForTesting(fileSizes: [UInt64], physicalMemory: UInt64) -> Int {
        Self.effectiveConcurrency(
            configuredLimit: config.maxConcurrentJobs,
            fileSizes: fileSizes,
            physicalMemory: physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    private func runQueue() async {
        state = .processing
        currentFileName = "准备转换 ProXDR HEIC..."
        refreshOutputURLsAndPlansForEditableItems()
        _ = markOutputCollisions()

        let runnableItems = queue.compactMap { item -> WorkItem? in
            guard item.status == .pending, !item.outputPlanStatus.blocksConversion else { return nil }
            return WorkItem(id: item.id, inputURL: item.inputURL, outputURL: item.outputURL)
        }

        guard !runnableItems.isEmpty else {
            currentConcurrency = 0
            state = failedCount > 0 ? .completed : .idle
            processTask = nil
            return
        }

        let runConfig = config
        let fileSizes = runnableItems.map { Self.fileSize($0.inputURL) }
        let concurrencyLimit = Self.effectiveConcurrency(
            configuredLimit: runConfig.maxConcurrentJobs,
            fileSizes: fileSizes,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount
        )
        currentConcurrency = concurrencyLimit

        await withTaskGroup(of: QueueWorkResult.self) { group in
            var iterator = runnableItems.makeIterator()
            var active = 0

            @MainActor
            func schedule(_ item: WorkItem) {
                if let index = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[index].status = .running
                    queue[index].errorMessage = nil
                    queue[index].startedAt = Date()
                    queue[index].finishedAt = nil
                }
                currentFileName = item.inputURL.lastPathComponent
                active += 1
                group.addTask {
                    Self.convertOne(item, config: runConfig)
                }
            }

            while active < concurrencyLimit, let item = iterator.next(), !Task.isCancelled {
                schedule(item)
            }

            for await result in group {
                active -= 1
                apply(result)

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                if let nextItem = iterator.next() {
                    schedule(nextItem)
                }
            }
        }

        currentConcurrency = 0
        processTask = nil

        if Task.isCancelled {
            markPendingAsCancelled()
            markRunningAsCancelled()
            state = .cancelled
            currentFileName = AppStrings.statCancelled
        } else {
            state = .completed
            currentFileName = failedCount == 0 ? AppStrings.conversionFinished : AppStrings.conversionFinishedWithFailures
        }
    }

    private func apply(_ result: QueueWorkResult) {
        guard let index = queue.firstIndex(where: { $0.id == result.id }) else { return }
        queue[index].status = result.status
        queue[index].errorMessage = result.errorMessage
        queue[index].finishedAt = result.finishedAt
        currentFileName = queue[index].inputURL.lastPathComponent
    }

    @discardableResult
    private func markOutputCollisions() -> Int {
        var marked = 0
        refreshOutputURLsAndPlansForEditableItems()
        for index in queue.indices where queue[index].status == .pending && queue[index].outputPlanStatus.blocksConversion {
            queue[index].status = .failed
            queue[index].errorMessage = Self.outputPlanFailureMessage(for: queue[index])
            queue[index].finishedAt = Date()
            marked += 1
        }
        return marked
    }

    private func markPendingAsCancelled() {
        for index in queue.indices where queue[index].status == .pending {
            queue[index].status = .cancelled
            queue[index].finishedAt = Date()
        }
    }

    private func markRunningAsCancelled() {
        for index in queue.indices where queue[index].status == .running {
            queue[index].status = .cancelled
            queue[index].finishedAt = Date()
        }
    }

    private func resetCancelledToPending() {
        for index in queue.indices where queue[index].status == .cancelled {
            queue[index].status = .pending
            queue[index].errorMessage = nil
            queue[index].startedAt = nil
            queue[index].finishedAt = nil
            queue[index].outputURL = Self.makeOutputURL(for: queue[index].inputURL, config: config)
            queue[index].outputPlanStatus = Self.outputPlanStatus(inputURL: queue[index].inputURL, outputURL: queue[index].outputURL, config: config)
        }
        refreshOutputURLsAndPlansForEditableItems()
    }

    nonisolated private struct WorkItem: Sendable {
        let id: UUID
        let inputURL: URL
        let outputURL: URL
    }

    nonisolated private struct QueueWorkResult: Sendable {
        let id: UUID
        let status: ConversionQueueStatus
        let errorMessage: String?
        let finishedAt: Date
    }

    nonisolated private static func convertOne(_ item: WorkItem, config: ConversionConfig) -> QueueWorkResult {
        autoreleasepool {
            if Task.isCancelled {
                return QueueWorkResult(id: item.id, status: .cancelled, errorMessage: nil, finishedAt: Date())
            }

            do {
                if config.skipExisting, XDRemuxCore.isValidISOGainMapOutput(item.outputURL) {
                    return QueueWorkResult(id: item.id, status: .skippedExisting, errorMessage: nil, finishedAt: Date())
                }
                let disposition = try prepareOutputForConversion(
                    inputURL: item.inputURL,
                    outputURL: item.outputURL,
                    skipExisting: config.skipExisting
                )
                if disposition == .skippedExistingValidOutput {
                    return QueueWorkResult(id: item.id, status: .skippedExisting, errorMessage: nil, finishedAt: Date())
                }
                try XDRemuxCore.convert(inputURL: item.inputURL, outputURL: item.outputURL, config: config)
                return QueueWorkResult(id: item.id, status: .converted, errorMessage: nil, finishedAt: Date())
            } catch {
                return QueueWorkResult(
                    id: item.id,
                    status: .failed,
                    errorMessage: describe(error),
                    finishedAt: Date()
                )
            }
        }
    }

    nonisolated private static func collectHEICURLs(from urls: [URL]) -> [URL] {
        var heicURLs: [URL] = []
        let fileManager = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    if let enumerator = fileManager.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "heic" {
                            heicURLs.append(fileURL)
                        }
                    }
                } else if url.pathExtension.lowercased() == "heic" {
                    heicURLs.append(url)
                }
            }
        }

        return heicURLs.sorted { $0.path < $1.path }
    }

    nonisolated private static func makeOutputURL(for inputURL: URL, config: ConversionConfig) -> URL {
        if let outputDirectory = config.outputDirectory {
            return outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
        }

        let suffix = config.fileNameSuffix.isEmpty ? "_iso" : config.fileNameSuffix
        let stem = inputURL.deletingPathExtension().lastPathComponent
        return inputURL.deletingLastPathComponent().appendingPathComponent("\(stem)\(suffix).heic")
    }

    nonisolated private static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    nonisolated private static func outputPlanStatus(
        inputURL: URL,
        outputURL: URL,
        config: ConversionConfig
    ) -> OutputPlanStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: inputURL.path) else {
            return .inputMissing
        }

        let parentURL = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return .outputParentIsFile
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            return .ready
        }

        if config.skipExisting, XDRemuxCore.isValidISOGainMapOutput(outputURL) {
            return .skipsExistingValidOutput
        }
        return .willOverwriteExisting
    }

    nonisolated private static func outputPlanFailureMessage(for item: ConversionQueueItem) -> String {
        switch item.outputPlanStatus {
        case .duplicateOutput:
            return "输出路径冲突: \(item.outputURL.path)"
        case .inputMissing:
            return "输入文件不存在: \(item.inputURL.path)"
        case .outputParentIsFile:
            return "输出目录位置是文件，无法写入: \(item.outputURL.deletingLastPathComponent().path)"
        case .ready, .willOverwriteExisting, .skipsExistingValidOutput:
            return ""
        }
    }

    nonisolated private static func prepareOutputForConversion(
        inputURL: URL,
        outputURL: URL,
        skipExisting: Bool
    ) throws -> OutputPreparationDisposition {
        let fileManager = FileManager.default
        guard pathKey(inputURL) != pathKey(outputURL) else {
            return .ready
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            return .ready
        }
        if skipExisting, XDRemuxCore.isValidISOGainMapOutput(outputURL) {
            return .skippedExistingValidOutput
        }
        try fileManager.removeItem(at: outputURL)
        return .removedExistingInvalidOutput
    }

    private func applyThumbnailData(id: UUID, inputURL: URL, data: Data) {
        guard let image = NSImage(data: data) else {
            _ = applyThumbnailFailure(id: id, inputURL: inputURL, message: AppStrings.previewUnavailable)
            return
        }
        _ = applyThumbnailResult(id: id, inputURL: inputURL, status: .ready(image))
    }

    @discardableResult
    private func applyThumbnailFailure(id: UUID, inputURL: URL, message: String) -> Bool {
        applyThumbnailResult(id: id, inputURL: inputURL, status: .failed(message))
    }

    @discardableResult
    private func applyThumbnailResult(id: UUID, inputURL: URL, status: ThumbnailStatus) -> Bool {
        guard let item = queue.first(where: { $0.id == id }),
              Self.pathKey(item.inputURL) == Self.pathKey(inputURL) else {
            return false
        }
        thumbnailStatusByID[id] = status
        return true
    }

    nonisolated private static func makeThumbnailPNGData(for url: URL, maxPixelSize: Int) throws -> Data {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw XDRemuxError.unableToLoadBaseImage(url)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw XDRemuxError.unableToLoadBaseImage(url)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw XDRemuxError.unableToWriteDebugAsset(url)
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XDRemuxError.unableToWriteDebugAsset(url)
        }
        return data as Data
    }

    nonisolated private static func fileSize(_ url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0 else {
            return 0
        }
        return UInt64(size)
    }

    nonisolated private static func effectiveConcurrency(
        configuredLimit: Int,
        fileSizes: [UInt64],
        physicalMemory: UInt64,
        processorCount: Int
    ) -> Int {
        let cpuCap = max(1, min(processorCount, 4))
        let requested = max(1, min(configuredLimit, cpuCap))
        guard let largest = fileSizes.max(), largest > 0 else {
            return requested
        }

        let minimumPerJobBytes = 512.0 * 1024.0 * 1024.0
        let estimatedPerJobBytes = max(Double(largest) * 4.0, minimumPerJobBytes)
        let usableMemoryBytes = max(Double(physicalMemory) * 0.35, estimatedPerJobBytes)
        let memoryCap = max(1, Int(floor(usableMemoryBytes / estimatedPerJobBytes)))
        return max(1, min(requested, memoryCap))
    }

    nonisolated private static func describe(_ error: Error) -> String {
        if let error = error as? XDRemuxError {
            return error.description
        }
        return String(describing: error)
    }
}
