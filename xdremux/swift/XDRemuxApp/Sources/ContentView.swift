import SwiftUI
import UniformTypeIdentifiers
import Observation
import AppKit

struct ContentView: View {
    @State private var viewModel = XDRemuxViewModel()
    @State private var isTargeted = false
    @State private var isSettingsPresented = false
    @State private var selectedQueueItemID: UUID?

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                Divider()
                progressPanel
                Divider()
                queuePanel
                Divider()
                footerBar
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(Color.clear)
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(viewModel: viewModel)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("XDRemux")
                    .font(.title3.weight(.semibold))
                Text(configSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: selectFiles) {
                Label(AppStrings.addHEIC, systemImage: "plus")
            }
            .disabled(!viewModel.canEditQueue)
            .help(AppStrings.addHEICHelp)

            Button {
                viewModel.startConversion()
            } label: {
                Label(AppStrings.startConversion, systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canStart)
            .keyboardShortcut(.defaultAction)

            Button {
                viewModel.cancelTask()
            } label: {
                Label(AppStrings.cancel, systemImage: "stop.fill")
            }
            .disabled(viewModel.state != .processing && viewModel.state != .scanning)
            .keyboardShortcut(.cancelAction)

            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help(AppStrings.conversionSettings)

            Button {
                viewModel.clearQueue()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!viewModel.canEditQueue || viewModel.queue.isEmpty)
            .help(AppStrings.clearQueue)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var progressPanel: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stateTitle)
                        .font(.headline)
                    Text(stateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 8) {
                    StatPill(title: AppStrings.statConverted, value: viewModel.convertedCount, color: .green)
                    StatPill(title: AppStrings.statSkipped, value: viewModel.skippedCount, color: .secondary)
                    StatPill(title: AppStrings.statFailed, value: viewModel.failedCount, color: viewModel.failedCount == 0 ? .secondary : .red)
                    StatPill(title: AppStrings.statCancelled, value: viewModel.cancelledCount, color: .secondary)
                    StatPill(title: AppStrings.statTotal, value: viewModel.totalFiles, color: .secondary)
                }
            }

            ProgressView(value: viewModel.progressFraction)
                .progressViewStyle(.linear)
                .frame(height: 8)

            HStack {
                Label("\(viewModel.processedCount) / \(viewModel.totalFiles)", systemImage: "checklist")
                Spacer()
                Label("\(AppStrings.concurrentJobsSummary) \(displayedConcurrency)", systemImage: "cpu")
                Label("\(viewModel.pendingCount) \(AppStrings.pending)", systemImage: "clock")
                if viewModel.runningCount > 0 {
                    Label("\(viewModel.runningCount) \(AppStrings.running)", systemImage: "bolt.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var queuePanel: some View {
        ZStack {
            if viewModel.queue.isEmpty {
                emptyQueueView
            } else {
                HSplitView {
                    queueList
                        .frame(minWidth: 560)

                    selectedItemDetail
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(isTargeted ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 2)
        }
        .dropDestination(for: URL.self) { items, _ in
            guard !items.isEmpty else { return false }
            viewModel.addFiles(from: items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private var queueList: some View {
        List(selection: $selectedQueueItemID) {
            ForEach(viewModel.queue) { item in
                QueueRow(
                    item: item,
                    thumbnailStatus: viewModel.thumbnailStatus(for: item.id),
                    canRemove: viewModel.canEditQueue,
                    reveal: { reveal(item.outputURL) },
                    remove: { viewModel.removeQueueItem(id: item.id) }
                )
                .tag(item.id)
                .task(id: item.id) {
                    viewModel.loadThumbnailIfNeeded(for: item)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onAppear {
            reconcileSelection(with: viewModel.queue.map(\.id))
        }
        .onChange(of: viewModel.queue.map(\.id)) { _, ids in
            reconcileSelection(with: ids)
        }
    }

    private var selectedItemDetail: some View {
        Group {
            if let selectedItem {
                QueueDetailView(
                    item: selectedItem,
                    thumbnailStatus: viewModel.thumbnailStatus(for: selectedItem.id),
                    revealInput: { reveal(selectedItem.inputURL) },
                    revealOutput: { reveal(selectedItem.outputURL) }
                )
                .task(id: selectedItem.id) {
                    viewModel.loadThumbnailIfNeeded(for: selectedItem)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(AppStrings.noSelection)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .background(Color.secondary.opacity(0.06))
    }

    private var emptyQueueView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: isTargeted)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(AppStrings.emptyQueueTitle)
                    .font(.title3.weight(.semibold))
            }

            Button(action: selectFiles) {
                Label(AppStrings.addHEIC, systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canEditQueue)
        }
        .padding(30)
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            if !viewModel.visibleErrors.isEmpty {
                errorSummary
            } else {
                Text(viewModel.queue.isEmpty ? AppStrings.queueNotImported : "\(viewModel.queue.count) 个队列项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.retryFailed()
            } label: {
                Label(AppStrings.retryFailed, systemImage: "arrow.clockwise")
            }
            .disabled(!viewModel.canEditQueue || viewModel.failedCount == 0)

            Button {
                viewModel.clearCompleted()
            } label: {
                Label(AppStrings.removeCompleted, systemImage: "checkmark.circle")
            }
            .disabled(!viewModel.canEditQueue || (viewModel.convertedCount + viewModel.skippedCount) == 0)

            Button {
                revealOutputs()
            } label: {
                Label(AppStrings.revealOutputsInFinder, systemImage: "folder")
            }
            .disabled(viewModel.queue.allSatisfy { !$0.isSuccessful })
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var errorSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(viewModel.visibleErrors.joined(separator: "  |  "))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var configSummary: String {
        let output = viewModel.config.outputDirectory?.lastPathComponent ?? viewModel.config.fileNameSuffix
        let oppo = "\(AppStrings.oppoCompatLabel): \(viewModel.config.oppoCompat ? AppStrings.oppoCompatOn : AppStrings.oppoCompatOff)"
        return "\(viewModel.config.family.appTitle) / \(viewModel.config.inputProcessingBranch.appTitle) / \(oppo) / \(output)"
    }

    private var stateTitle: String {
        switch viewModel.state {
        case .idle:
            return viewModel.queue.isEmpty ? AppStrings.ready : AppStrings.queueReady
        case .scanning:
            return AppStrings.scanning
        case .processing:
            return AppStrings.converting
        case .completed:
            return viewModel.failedCount == 0 ? AppStrings.conversionFinished : AppStrings.conversionFinishedWithFailures
        case .cancelled:
            return AppStrings.statCancelled
        }
    }

    private var stateDetail: String {
        if !viewModel.currentFileName.isEmpty {
            return viewModel.currentFileName
        }
        if viewModel.queue.isEmpty {
            return AppStrings.waitingForInput
        }
        return "\(AppStrings.pending) \(viewModel.pendingCount)，\(AppStrings.running) \(viewModel.runningCount)"
    }

    private var displayedConcurrency: Int {
        viewModel.currentConcurrency > 0 ? viewModel.currentConcurrency : viewModel.config.maxConcurrentJobs
    }

    private var selectedItem: ConversionQueueItem? {
        guard let selectedQueueItemID else { return viewModel.queue.first }
        return viewModel.queue.first { $0.id == selectedQueueItemID }
    }

    private func reconcileSelection(with ids: [UUID]) {
        guard !ids.isEmpty else {
            selectedQueueItemID = nil
            return
        }
        if let selectedQueueItemID, ids.contains(selectedQueueItemID) {
            return
        }
        selectedQueueItemID = ids.first
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.heic]
        panel.canCreateDirectories = false
        panel.message = AppStrings.selectHEICPanelMessage
        panel.prompt = AppStrings.addHEIC

        if panel.runModal() == .OK {
            viewModel.addFiles(from: panel.urls)
        }
    }

    private func revealOutputs() {
        let urls = viewModel.queue
            .filter(\.isSuccessful)
            .map(\.outputURL)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct StatPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text("\(value)")
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct QueueRow: View {
    let item: ConversionQueueItem
    let thumbnailStatus: ThumbnailStatus
    let canRemove: Bool
    let reveal: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(status: thumbnailStatus, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.inputURL.lastPathComponent)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.status.iconColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.status.iconColor.opacity(0.12), in: Capsule())

                    if item.outputPlanStatus != .ready {
                        Text(item.outputPlanStatus.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.outputPlanStatus.iconColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(item.outputPlanStatus.iconColor.opacity(0.12), in: Capsule())
                    }

                    if let duration = item.duration {
                        Text(durationText(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(item.outputURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let errorMessage = item.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Button(action: reveal) {
                Image(systemName: "folder")
            }
            .disabled(!item.isSuccessful)
            .help(AppStrings.revealInFinder)

            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .disabled(!canRemove)
            .help(AppStrings.remove)
        }
        .frame(minHeight: 68)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.inputURL.lastPathComponent), \(item.status.displayName), \(item.outputPlanStatus.displayName)")
    }

    private func durationText(_ duration: TimeInterval) -> String {
        if duration < 10 {
            return String(format: "%.1fs", duration)
        }
        return "\(Int(duration.rounded()))s"
    }
}

private struct QueueDetailView: View {
    let item: ConversionQueueItem
    let thumbnailStatus: ThumbnailStatus
    let revealInput: () -> Void
    let revealOutput: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppStrings.preview)
                        .font(.headline)
                    ThumbnailView(status: thumbnailStatus, size: 224)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(item.inputURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    LabelValueRow(label: AppStrings.fileStatus, value: item.status.displayName, color: item.status.iconColor)
                    LabelValueRow(label: AppStrings.outputPlan, value: item.outputPlanStatus.displayName, color: item.outputPlanStatus.iconColor)

                    if let errorMessage = item.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    PathActionRow(
                        title: AppStrings.inputPath,
                        path: item.inputURL.path,
                        buttonTitle: AppStrings.revealInputInFinder,
                        systemImage: "doc.viewfinder",
                        action: revealInput
                    )
                    PathActionRow(
                        title: AppStrings.outputPath,
                        path: item.outputURL.path,
                        buttonTitle: AppStrings.revealInFinder,
                        systemImage: "folder",
                        action: revealOutput
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ThumbnailView: View {
    let status: ThumbnailStatus
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                }

            switch status {
            case .empty:
                Image(systemName: "photo")
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .controlSize(size > 80 ? .regular : .small)
                    .help(AppStrings.previewLoading)
            case .ready(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 7))
            case .failed:
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundStyle(.secondary)
                    .help(AppStrings.previewUnavailable)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(AppStrings.preview)
    }

    private var iconSize: CGFloat {
        max(18, min(size * 0.34, 42))
    }
}

private struct LabelValueRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PathActionRow: View {
    let title: String
    let path: String
    let buttonTitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: action) {
                    Image(systemName: systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(buttonTitle)
            }

            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension ConversionQueueStatus {
    var displayName: String {
        switch self {
        case .pending: return AppStrings.statusPending
        case .running: return AppStrings.statusRunning
        case .converted: return AppStrings.statusConverted
        case .skippedExisting: return AppStrings.statusSkippedExisting
        case .failed: return AppStrings.statusFailed
        case .cancelled: return AppStrings.statusCancelled
        }
    }

    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .running: return "bolt.circle.fill"
        case .converted: return "checkmark.circle.fill"
        case .skippedExisting: return "arrow.uturn.forward.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .accentColor
        case .converted: return .green
        case .skippedExisting: return .secondary
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

private extension OutputPlanStatus {
    var displayName: String {
        switch self {
        case .ready: return AppStrings.outputPlanReady
        case .willOverwriteExisting: return AppStrings.outputPlanOverwriteExisting
        case .skipsExistingValidOutput: return AppStrings.outputPlanSkipExisting
        case .duplicateOutput: return AppStrings.outputPlanDuplicate
        case .inputMissing: return AppStrings.outputPlanInputMissing
        case .outputParentIsFile: return AppStrings.outputPlanParentIsFile
        }
    }

    var iconColor: Color {
        switch self {
        case .ready:
            return .secondary
        case .willOverwriteExisting:
            return .orange
        case .skipsExistingValidOutput:
            return .secondary
        case .duplicateOutput, .inputMissing, .outputParentIsFile:
            return .red
        }
    }
}

private struct SettingsView: View {
    @Bindable var viewModel: XDRemuxViewModel
    @Environment(\.dismiss) private var dismiss

    private var maxJobs: Int {
        max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppStrings.conversionSettings)
                .font(.title3.weight(.semibold))

            Form {
                Picker(AppStrings.inputHDRType, selection: $viewModel.config.family) {
                    ForEach(Family.allCases) { family in
                        Text(family.appTitle).tag(family)
                    }
                }
                .pickerStyle(.segmented)
                SettingExplanation(AppStrings.inputHDRTypeHelp)

                Picker(AppStrings.inputProcessing, selection: $viewModel.config.inputProcessingBranch) {
                    ForEach(InputProcessingBranch.allCases) { branch in
                        Text(branch.appTitle).tag(branch)
                    }
                }
                .pickerStyle(.segmented)
                SettingExplanation(viewModel.config.inputProcessingBranch.appHelp)

                Toggle(AppStrings.oppoCompatLabel, isOn: $viewModel.config.oppoCompat)
                SettingExplanation(AppStrings.oppoCompatHelp)

                Toggle(AppStrings.skipExisting, isOn: $viewModel.config.skipExisting)
                SettingExplanation(AppStrings.skipExistingHelp)

                Stepper(value: $viewModel.config.maxConcurrentJobs, in: 1...maxJobs) {
                    LabeledContent(AppStrings.concurrentJobs) {
                        Text("\(viewModel.config.maxConcurrentJobs)")
                            .monospacedDigit()
                    }
                }

                LabeledContent(AppStrings.outputFileSuffix) {
                    TextField("_iso", text: $viewModel.config.fileNameSuffix)
                        .frame(width: 140)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.config.outputDirectory != nil)
                        .onChange(of: viewModel.config.fileNameSuffix) {
                            viewModel.refreshOutputURLsForPendingItems()
                        }
                }
                SettingExplanation(AppStrings.outputFileSuffixHelp)

                LabeledContent(AppStrings.outputDirectory) {
                    directoryControl(
                        url: viewModel.config.outputDirectory,
                        emptyText: AppStrings.useOriginalDirectory,
                        choose: chooseOutputDirectory,
                        clear: {
                            viewModel.config.outputDirectory = nil
                            viewModel.refreshOutputURLsForPendingItems()
                        }
                    )
                }

                LabeledContent(AppStrings.debugOutputDirectory) {
                    directoryControl(
                        url: viewModel.config.debugDirectory,
                        emptyText: AppStrings.doNotWriteDebugFiles,
                        choose: chooseDebugDirectory,
                        clear: { viewModel.config.debugDirectory = nil }
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(AppStrings.done) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func directoryControl(url: URL?, emptyText: String, choose: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(url?.path ?? emptyText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .frame(maxWidth: 300, alignment: .trailing)

            Button(action: choose) {
                Image(systemName: "folder")
            }
            .help(AppStrings.chooseDirectory)

            Button(action: clear) {
                Image(systemName: "xmark.circle")
            }
            .disabled(url == nil)
            .help(AppStrings.clear)
        }
    }

    private func chooseOutputDirectory() {
        if let url = chooseDirectory() {
            viewModel.config.outputDirectory = url
            viewModel.refreshOutputURLsForPendingItems()
        }
    }

    private func chooseDebugDirectory() {
        if let url = chooseDirectory() {
            viewModel.config.debugDirectory = url
        }
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = AppStrings.select
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct SettingExplanation: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
