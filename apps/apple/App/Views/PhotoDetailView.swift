import SwiftUI
import XDRemuxKit
import XDRemuxModel

/// Detail-first flow (plan §8.3): what the core found, the options that
/// apply to this photo, one "convert" button, then the HDR result and export.
struct PhotoDetailView: View {
    @Bindable var model: LibraryModel
    let itemID: PhotoItem.ID

    private var item: PhotoItem? { model.items.first { $0.id == itemID } }

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PreviewCard(item: item)
                    statusSection(item)
                    infoSection(item)
                    if item.isConvertible, item.product == nil {
                        optionsSection(item)
                    }
                    if let product = item.product {
                        ResultSection(model: model, item: item, product: product)
                    }
                }
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(item.sourceName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } else {
            ContentUnavailableView("照片已移出", systemImage: "photo")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func statusSection(_ item: PhotoItem) -> some View {
        switch item.state {
        case .converting(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                Text(item.statusText).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            GroupBox {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Spacer()
                    Button("重试") { Task { await model.retry(item.id) } }
                }
            }
        case .ready where !item.isConvertible:
            GroupBox {
                Label(item.inspection?.errorMessage ?? "这张照片不是可转换的 ProXDR / Ultra HDR 文件。",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func infoSection(_ item: PhotoItem) -> some View {
        GroupBox("照片信息") {
            InfoGrid {
                InfoRow("拍摄设备", [item.details?.make, item.details?.model].compactMap { $0 }.joined(separator: " "))
                InfoRow("尺寸", item.details?.dimensionsText)
                InfoRow("拍摄时间", item.details?.dateTime)
                InfoRow("曝光", item.details?.exposureSummary)
                InfoRow("HDR 类型", item.classification?.hdrKind?.uppercased())
                InfoRow("机型家族", item.classification?.family?.uppercased())
                InfoRow("拍摄模式", item.classification?.modeKey)
                InfoRow("分类状态", item.classification?.status)
                if let i = item.inspection, i.success {
                    InfoRow("EDR scale", String(format: "%.3f", i.edrScale))
                    InfoRow("Gain map 上限", String(format: "%.3f", i.gainMapMax))
                }
                if item.details?.applePhotographicStyles == true { InfoRow("Apple 摄影风格", "已包含") }
                if item.details?.applePortrait == true { InfoRow("Apple 人像", "已包含") }
            }
        }
    }

    private func optionsSection(_ item: PhotoItem) -> some View {
        GroupBox("转换选项") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("输出", selection: $model.config.outputMode) {
                    Text("OPPO 兼容").tag(OutputMode.oppo)
                    Text("Apple 标准").tag(OutputMode.apple)
                }
                .pickerStyle(.segmented)

                Text(model.config.outputMode == .oppo
                     ? "恢复 OPPO 兼容结构、元数据和 OPPO 私有尾部数据，照片在 ColorOS 图库里像原机照片。"
                     : "不追加 OPPO 私有信息，照片可在 Apple 照片里继续编辑。")
                    .font(.caption).foregroundStyle(.secondary)

                if model.config.outputMode == .apple {
                    Toggle("Apple 摄影风格", isOn: $model.config.applePhotographicStyles)
                    Toggle("摄影风格 3（纹理与颗粒）", isOn: $model.config.applePhotographicStyles3)
                    Toggle("Apple 人像数据", isOn: $model.config.applePortrait)
                }

                Button {
                    Task { await model.convert(item.id) }
                } label: {
                    Label("转换这张", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(item.state.isBusy)
            }
            .padding(.top, 4)
        }
    }
}

/// Shows the HDR output when available, otherwise the SDR input thumbnail.
struct PreviewCard: View {
    let item: PhotoItem
    @State private var hdrImage: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary)
            if let hdrImage {
                Image(decorative: hdrImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .allowedDynamicRange(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) { badge("HDR 输出") }
            } else if let thumb = item.thumbnail {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) { badge("原图预览") }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220, maxHeight: 420)
        .task(id: item.product?.outputURL) {
            guard let url = item.product?.outputURL else { hdrImage = nil; return }
            hdrImage = await Task.detached(priority: .userInitiated) { ImageLoading.hdrImage(at: url) }.value
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
    }
}

struct ResultSection: View {
    @Bindable var model: LibraryModel
    let item: PhotoItem
    let product: ConversionProduct

    var body: some View {
        GroupBox("转换结果") {
            VStack(alignment: .leading, spacing: 12) {
                InfoGrid {
                    InfoRow("输出模式", product.config.outputMode == .oppo ? "OPPO 兼容" : "Apple 标准")
                    InfoRow("文件", product.outputURL.lastPathComponent)
                    InfoRow("来源", [product.outcome.family?.uppercased(), product.outcome.mode?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                    InfoRow("校验", "通过（可解码 + 结构检查）")
                }
                ExportButtons(model: model, item: item, product: product)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Small layout helpers

struct InfoGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}
