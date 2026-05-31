import SwiftUI
import UniformTypeIdentifiers
import Observation
import AppKit

struct ContentView: View {
    @State private var viewModel = XDRemuxViewModel()
    @State private var isTargeted = false
    @State private var isSettingsPresented = false
    @State private var selectedQueueItemID: UUID?
    @State private var queueFilter = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            workbench
        }
        .navigationTitle("XDRemux")
        .frame(minWidth: 1040, minHeight: 680)
        .searchable(text: $queueFilter, prompt: "搜索队列")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(viewModel: viewModel)
                .presentationSizing(.fitted)
        }
        .dropDestination(for: URL.self) { items, _ in
            guard !items.isEmpty else { return false }
            viewModel.addFiles(from: items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .overlay {
            if isTargeted {
                DropTargetOverlay()
            }
        }
        .onAppear {
            reconcileSelection(with: filteredQueueItemIDs)
        }
        .onChange(of: viewModel.queue.map(\.id)) { _, _ in
            reconcileSelection(with: filteredQueueItemIDs)
        }
        .onChange(of: queueFilter) { _, _ in
            reconcileSelection(with: filteredQueueItemIDs)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            QueueSidebarHeader(
                stateTitle: stateTitle,
                stateDetail: stateDetail,
                progressFraction: viewModel.progressFraction,
                processedCount: viewModel.processedCount,
                totalFiles: viewModel.totalFiles
            )

            List(selection: $selectedQueueItemID) {
                if filteredQueueItems.isEmpty {
                    EmptySidebarRow(queueIsEmpty: viewModel.queue.isEmpty)
                } else {
                    ForEach(filteredQueueItems) { item in
                        QueueSidebarRow(
                            item: item,
                            thumbnailStatus: viewModel.thumbnailStatus(for: item.id),
                            reveal: { reveal(item.outputURL) },
                            remove: { viewModel.removeQueueItem(id: item.id) }
                        )
                        .tag(item.id)
                        .task(id: item.id) {
                            viewModel.loadThumbnailIfNeeded(for: item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var workbench: some View {
        VStack(spacing: 0) {
            ProgressSurface(
                convertedCount: viewModel.convertedCount,
                skippedCount: viewModel.skippedCount,
                failedCount: viewModel.failedCount,
                cancelledCount: viewModel.cancelledCount,
                pendingCount: viewModel.pendingCount,
                runningCount: viewModel.runningCount,
                totalFiles: viewModel.totalFiles,
                displayedConcurrency: displayedConcurrency,
                configSummary: configSummary
            )
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ZStack {
                if viewModel.queue.isEmpty {
                    EmptyQueueView(selectFiles: selectFiles, canAdd: viewModel.canEditQueue)
                } else if let selectedItem {
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
                    NoSelectionView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            FooterBar(
                queueIsEmpty: viewModel.queue.isEmpty,
                queueCount: viewModel.queue.count,
                visibleErrors: viewModel.visibleErrors,
                canEditQueue: viewModel.canEditQueue,
                failedCount: viewModel.failedCount,
                completedCount: viewModel.convertedCount + viewModel.skippedCount,
                hasSuccessfulOutputs: viewModel.queue.contains { $0.isSuccessful },
                retryFailed: viewModel.retryFailed,
                clearCompleted: viewModel.clearCompleted,
                revealOutputs: revealOutputs
            )
        }
        .background(.clear)
    }

    private var filteredQueueItems: [ConversionQueueItem] {
        let term = queueFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return viewModel.queue }
        return viewModel.queue.filter { item in
            item.inputURL.lastPathComponent.localizedCaseInsensitiveContains(term) ||
            item.inputURL.path.localizedCaseInsensitiveContains(term) ||
            item.outputURL.path.localizedCaseInsensitiveContains(term) ||
            item.status.displayName.localizedCaseInsensitiveContains(term) ||
            item.outputPlanStatus.displayName.localizedCaseInsensitiveContains(term)
        }
    }

    private var filteredQueueItemIDs: [UUID] {
        filteredQueueItems.map(\.id)
    }

    private var configSummary: String {
        let output = viewModel.config.outputDirectory?.lastPathComponent ?? viewModel.config.fileNameSuffix
        let oppo = "\(AppStrings.oppoCompatLabel): \(viewModel.config.oppoCompatibility.appTitle)"
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
        if let selectedQueueItemID,
           let item = viewModel.queue.first(where: { $0.id == selectedQueueItemID }) {
            return item
        }
        return filteredQueueItems.first ?? viewModel.queue.first
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

private struct QueueSidebarHeader: View {
    let stateTitle: String
    let stateDetail: String
    let progressFraction: Double
    let processedCount: Int
    let totalFiles: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateTitle)
                        .font(.headline)
                    Text(stateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(processedCount)/\(totalFiles)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct QueueSidebarRow: View {
    let item: ConversionQueueItem
    let thumbnailStatus: ThumbnailStatus
    let reveal: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(status: thumbnailStatus, size: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: item.status.iconName)
                        .foregroundStyle(item.status.iconColor)
                        .accessibilityHidden(true)
                    Text(item.inputURL.lastPathComponent)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 6) {
                    Text(item.status.displayName)
                        .foregroundStyle(item.status.iconColor)
                    if item.outputPlanStatus != .ready {
                        Text(item.outputPlanStatus.displayName)
                            .foregroundStyle(item.outputPlanStatus.iconColor)
                    }
                    if let duration = item.duration {
                        Text(durationText(duration))
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .lineLimit(1)
            }
        }
        .frame(minHeight: 58)
        .contextMenu {
            Button(action: reveal) {
                Label(AppStrings.revealInFinder, systemImage: "folder")
            }
            .disabled(!item.isSuccessful)

            Button(role: .destructive, action: remove) {
                Label(AppStrings.remove, systemImage: "xmark")
            }
        }
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

private struct EmptySidebarRow: View {
    let queueIsEmpty: Bool

    var body: some View {
        Label(queueIsEmpty ? AppStrings.queueNotImported : "没有匹配项目", systemImage: queueIsEmpty ? "tray" : "magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

private struct ProgressSurface: View {
    let convertedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let cancelledCount: Int
    let pendingCount: Int
    let runningCount: Int
    let totalFiles: Int
    let displayedConcurrency: Int
    let configSummary: String

    var body: some View {
        GlassPanel(cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("批量转换控制台")
                            .font(.title3.weight(.semibold))
                        Text(configSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        StatPill(title: AppStrings.statConverted, value: convertedCount, color: .green)
                        StatPill(title: AppStrings.statSkipped, value: skippedCount, color: .secondary)
                        StatPill(title: AppStrings.statFailed, value: failedCount, color: failedCount == 0 ? .secondary : .red)
                        StatPill(title: AppStrings.statCancelled, value: cancelledCount, color: .orange)
                        StatPill(title: AppStrings.statTotal, value: totalFiles, color: .secondary)
                    }
                }

                HStack(spacing: 18) {
                    Label("\(AppStrings.concurrentJobsSummary) \(displayedConcurrency)", systemImage: "cpu")
                    Label("\(pendingCount) \(AppStrings.pending)", systemImage: "clock")
                    Label("\(runningCount) \(AppStrings.running)", systemImage: "bolt.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(16)
        }
    }
}

private struct EmptyQueueView: View {
    let selectFiles: () -> Void
    let canAdd: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(AppStrings.emptyQueueTitle)
                .font(.title3.weight(.semibold))

            Button(action: selectFiles) {
                Label(AppStrings.addHEIC, systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
        }
        .padding(32)
    }
}

private struct NoSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppStrings.noSelection)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct QueueDetailView: View {
    let item: ConversionQueueItem
    let thumbnailStatus: ThumbnailStatus
    let revealInput: () -> Void
    let revealOutput: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    ThumbnailView(status: thumbnailStatus, size: 220)
                        .frame(width: 220, height: 220)

                    VStack(alignment: .leading, spacing: 14) {
                        Text(item.inputURL.lastPathComponent)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)

                        HStack(spacing: 8) {
                            StatusBadge(title: item.status.displayName, color: item.status.iconColor)
                            StatusBadge(title: item.outputPlanStatus.displayName, color: item.outputPlanStatus.iconColor)
                        }

                        if let errorMessage = item.errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 10) {
                            Button(action: revealInput) {
                                Label(AppStrings.revealInputInFinder, systemImage: "doc.viewfinder")
                            }

                            Button(action: revealOutput) {
                                Label(AppStrings.revealInFinder, systemImage: "folder")
                            }
                            .disabled(!item.isSuccessful)
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    LabelValueRow(label: AppStrings.fileStatus, value: item.status.displayName, color: item.status.iconColor)
                    LabelValueRow(label: AppStrings.outputPlan, value: item.outputPlanStatus.displayName, color: item.outputPlanStatus.iconColor)

                    if let startedAt = item.startedAt {
                        LabelValueRow(label: "开始时间", value: startedAt.formatted(date: .omitted, time: .standard), color: .secondary)
                    }
                    if let finishedAt = item.finishedAt {
                        LabelValueRow(label: "结束时间", value: finishedAt.formatted(date: .omitted, time: .standard), color: .secondary)
                    }

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
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FooterBar: View {
    let queueIsEmpty: Bool
    let queueCount: Int
    let visibleErrors: [String]
    let canEditQueue: Bool
    let failedCount: Int
    let completedCount: Int
    let hasSuccessfulOutputs: Bool
    let retryFailed: () -> Void
    let clearCompleted: () -> Void
    let revealOutputs: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if !visibleErrors.isEmpty {
                errorSummary
            } else {
                Text(queueIsEmpty ? AppStrings.queueNotImported : "\(queueCount) 个队列项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: retryFailed) {
                Label(AppStrings.retryFailed, systemImage: "arrow.clockwise")
            }
            .disabled(!canEditQueue || failedCount == 0)

            Button(action: clearCompleted) {
                Label(AppStrings.removeCompleted, systemImage: "checkmark.circle")
            }
            .disabled(!canEditQueue || completedCount == 0)

            Button(action: revealOutputs) {
                Label(AppStrings.revealOutputsInFinder, systemImage: "folder")
            }
            .disabled(!hasSuccessfulOutputs)
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
            Text(visibleErrors.joined(separator: "  |  "))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ThumbnailView: View {
    let status: ThumbnailStatus
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
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
                    .clipShape(.rect(cornerRadius: 8))
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
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
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

private struct DropTargetOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.tint.opacity(0.65), lineWidth: 3)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(10)
            .allowsHitTesting(false)
    }
}

private struct GlassPanel<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    init(cornerRadius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.separator.opacity(0.45), lineWidth: 1)
                }
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
            HStack {
                Text(AppStrings.conversionSettings)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(AppStrings.done)
            }

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

                Picker(AppStrings.oppoCompatLabel, selection: $viewModel.config.oppoCompatibility) {
                    ForEach(OppoCompatibility.allCases) { mode in
                        Text(mode.appTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                SettingExplanation(viewModel.config.oppoCompatibility.appHelp)

                Toggle(AppStrings.skipExisting, isOn: $viewModel.config.skipExisting)
                    .onChange(of: viewModel.config.skipExisting) {
                        viewModel.refreshOutputURLsForPendingItems()
                    }
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
        }
        .padding(24)
        .frame(width: 580)
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
