import SwiftUI
import UniformTypeIdentifiers
import XDRemuxKit
import XDRemuxModel

/// "一帧影像，动用两台手机": standalone four-step file round trip, separate
/// from the batch queue (plan §3 P2, Flutter `apple_oppo_workflow_page.dart`).
struct RoundTripView: View {
    @Bindable var library: LibraryModel
    @State private var model: RoundTripModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing: RoundTripModel.Slot?

    init(library: LibraryModel) {
        self.library = library
        _model = State(initialValue: RoundTripModel(library: library))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("一次摄影风格转换生成 Apple 编辑副本，在 iPhone 上编辑后回传，由 Rust 恢复原机水印与 OPPO 元数据。普通批量转换队列不参与此流程。")
                        .font(.callout).foregroundStyle(.secondary)

                    StepCard(step: 1, title: "选择 OPPO 原始照片",
                             description: "建议选择未经转换的 OPPO 原始照片；它也是后续恢复原机水印和元数据的来源。",
                             fileName: model.donor?.lastPathComponent) {
                        Button("选择照片…") { importing = .donor }
                    }

                    StepCard(step: 2, title: "生成 Apple 照片摄影风格编辑副本",
                             description: "对所选 OPPO 原始照片做一次摄影风格转换，生成交给 iPhone 编辑的工作文件。",
                             fileName: model.editCopy?.lastPathComponent) {
                        Button(model.busy == .editCopy ? "生成中…" : "生成 Apple 照片编辑副本") {
                            Task { await model.createEditCopy() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.donor == nil || model.busy != nil)
                        if let copy = model.editCopy {
                            FileExportButtons(files: [copy], onSavedToPhotos: nil)
                        }
                    }

                    StepCard(step: 3, title: "在 iPhone 上编辑",
                             description: "把上一步的文件传到 iPhone，在 Apple 照片中调整后导出（保留 HEIC）并选回这里。macOS 可直接从 Apple 照片拖到此窗口。",
                             fileName: model.returned?.lastPathComponent) {
                        Button("选择 iPhone 回传照片…") { importing = .returned }
                    }

                    StepCard(step: 4, title: "恢复原机水印并生成最终输出",
                             description: "OPPO 兼容恢复 OPPO 兼容结构、元数据和尾部数据；Apple 标准保留 Apple 照片结果且不写入 OPPO 私有信息，可按开关恢复可见原机水印。",
                             fileName: model.finalOutput?.lastPathComponent) {
                        Picker("输出", selection: $model.outputMode) {
                            Text("OPPO 兼容").tag(OutputMode.oppo)
                            Text("Apple 标准").tag(OutputMode.apple)
                        }
                        .pickerStyle(.segmented)
                        Toggle("按 OPPO 原始照片恢复可见原机水印", isOn: $model.restoreWatermark)
                        Button(model.busy == .writeback ? "处理中…" : "生成最终输出") {
                            Task { await model.writeback() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.returned == nil || model.busy != nil)
                        if let report = model.report {
                            InfoGrid {
                                InfoRow("原机水印", report.rasterWatermarkRestored.map { $0 ? "已恢复" : "未恢复" })
                                InfoRow("OPPO 条目", report.restoredOppoEntries?.joined(separator: ", "))
                                InfoRow("EXIF", report.exifGrafted == true ? "已从原图移植" : nil)
                            }
                        }
                        if let final = model.finalOutput {
                            FileExportButtons(files: [final], onSavedToPhotos: nil)
                        }
                    }

                    if let status = model.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("一帧影像，动用两台手机")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                          allowedContentTypes: [.heic, .heif, .jpeg], allowsMultipleSelection: false) { result in
                guard let slot = importing, case .success(let urls) = result, let url = urls.first else { return }
                Task { await model.assign(url, to: slot) }
            }
            #if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await model.assign(url, to: model.donor == nil ? .donor : .returned) }
                return true
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }
}

@MainActor
@Observable
final class RoundTripModel {
    enum Slot { case donor, returned }
    enum Busy { case editCopy, writeback }

    var donor: URL?
    var editCopy: URL?
    var returned: URL?
    var finalOutput: URL?
    var report: WritebackReport?
    var outputMode: OutputMode
    var restoreWatermark = true
    var busy: Busy?
    var status: String?
    var error: String?

    private let library: LibraryModel
    private let engine = XDRemuxEngine.shared

    init(library: LibraryModel) {
        self.library = library
        outputMode = library.config.outputMode
    }

    /// Copies the picked file into the sandbox inputs folder (security scope
    /// held only for the copy), like the library import.
    func assign(_ url: URL, to slot: Slot) async {
        error = nil
        do {
            let copy = try library.materialise(url)
            switch slot {
            case .donor:
                donor = copy; editCopy = nil; finalOutput = nil; report = nil
                status = "已选择 OPPO 原始照片：\(url.lastPathComponent)"
            case .returned:
                returned = copy; finalOutput = nil; report = nil
                status = "已选择 iPhone 回传照片：\(url.lastPathComponent)"
            }
        } catch {
            self.error = "导入失败：\(error.localizedDescription)"
        }
    }

    func createEditCopy() async {
        guard let donor, busy == nil else { return }
        busy = .editCopy; error = nil; status = "正在生成 Apple 照片摄影风格编辑副本…"
        defer { busy = nil }
        let job = ConversionJob(backend: engine, scratchRoot: library.directories.scratch, outputRoot: library.outputRoot)
        do {
            let product = try await RoundTrip.createEditCopy(donor: donor, sourceName: library.sourceName(of: donor),
                                                             base: library.config, job: job)
            editCopy = product.outputURL
            status = "Apple 编辑副本已生成：\(product.outputURL.lastPathComponent)"
        } catch {
            self.error = "Apple 照片摄影风格失败：\(error)"
        }
    }

    func writeback() async {
        guard let returned, busy == nil else { return }
        if outputMode == .oppo && donor == nil { error = "OPPO 兼容输出必须保留 OPPO 原始照片。"; return }
        if restoreWatermark && donor == nil { error = "需要恢复原机水印时必须保留 OPPO 原始照片。"; return }
        busy = .writeback; error = nil; status = "正在写回回传照片…"
        defer { busy = nil }
        do {
            let (url, report) = try await RoundTrip.writeback(
                donor: donor, returned: returned, returnedName: library.sourceName(of: returned),
                outputMode: outputMode, restoreWatermark: restoreWatermark,
                outputRoot: library.outputRoot, scratchRoot: library.directories.scratch, backend: engine)
            finalOutput = url
            self.report = report
            status = "最终输出已生成：\(url.lastPathComponent)"
        } catch RoundTripError.writebackFailed(let message) {
            error = "写回失败：\(message ?? "未知原因")"
        } catch {
            self.error = "写回失败：\(error)"
        }
    }
}

struct StepCard<Actions: View>: View {
    let step: Int
    let title: String
    let description: String
    let fileName: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(step)")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.tint))
                        .foregroundStyle(.white)
                    Text(title).font(.headline)
                }
                Text(description).font(.caption).foregroundStyle(.secondary)
                if let fileName {
                    Label(fileName, systemImage: "doc").font(.callout).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("尚未选择").font(.callout).foregroundStyle(.tertiary)
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }
}
