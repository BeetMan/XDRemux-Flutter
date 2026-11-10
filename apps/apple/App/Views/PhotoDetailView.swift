import SwiftUI
import XDRemuxKit
import XDRemuxModel

/// Detail-first flow (plan §8.3): the preview, the options that apply to
/// this photo with one "convert" button (or the HDR result and export), and
/// what the core read about the file folded away at the end.
struct PhotoDetailView: View {
    @Bindable var model: LibraryModel
    let itemID: PhotoItem.ID
    @State private var showInfo = false

    private var item: PhotoItem? { model.items.first { $0.id == itemID } }

    /// Below this width the page stacks; at or above it the photo takes
    /// the left and the controls the right. An unfolded Duo with the list
    /// open (~670pt) stacks: split there, the photo got ~340pt. With the
    /// list hidden (~950pt), on an iPad in landscape and on the Mac it splits.
    static let twoColumnMinWidth: CGFloat = 800
    static let controlsColumnWidth: CGFloat = 300

    var body: some View {
        if let item {
            GeometryReader { geo in
                if geo.size.width >= Self.twoColumnMinWidth {
                    HStack(alignment: .top, spacing: 16) {
                        PreviewCard(item: item, fillsHeight: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) { sections(item) }
                        }
                        .frame(width: Self.controlsColumnWidth)
                        // Label-over-value rows: two columns of text do not
                        // fit a 300pt column without wrapping every value.
                        .environment(\.infoRowsStacked, true)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            PreviewCard(item: item)
                            sections(item)
                        }
                        .padding()
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(item.sourceName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // HDR before converting: the core renders the same output into
            // the cache (sub-second for a typical photo on an M-series Mac).
            .task(id: item.id) { await model.preparePreview(item.id) }
        } else {
            ContentUnavailableView("照片已移出", systemImage: "photo")
        }
    }

    // MARK: Sections

    /// Everything but the preview: status, then the options (the body of
    /// the page) or the result, then the metadata folded away.
    @ViewBuilder
    private func sections(_ item: PhotoItem) -> some View {
        statusSection(item)
        if item.canConfigureOptions, item.product == nil {
            if item.isMotionPhoto { motionSection(item) }
            optionsSection(item)
        }
        if let product = item.product {
            ResultSection(model: model, item: item, product: product)
        }
        infoSection(item)
    }

    @ViewBuilder
    private func statusSection(_ item: PhotoItem) -> some View {
        switch item.state {
        case .converting(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                HStack {
                    Text(item.statusText).font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("取消") { model.cancel(item.id) }.controlSize(.small)
                }
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
                Label(item.statusText, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func infoSection(_ item: PhotoItem) -> some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showInfo) {
                infoGrid(item).padding(.top, 8)
            } label: {
                Text("照片信息").font(.headline)
            }
            // A section header, not a link: keep the accent off the label.
            .tint(.primary)
        }
    }

    private func infoGrid(_ item: PhotoItem) -> some View {
            InfoGrid {
                InfoRow("拍摄设备", deviceName(item))
                InfoRow("尺寸", item.details?.dimensionsText)
                InfoRow("拍摄时间", item.details?.dateTime)
                InfoRow("曝光", item.details?.exposureSummary)
                InfoRow("HDR 类型", item.classification?.hdrKind?.uppercased())
                InfoRow("拍摄模式", captureModeName(item.classification?.modeKey))
                InfoRow("分类状态", item.classification?.status)
                if let i = item.inspection, i.success {
                    InfoRow("EDR scale", String(format: "%.3f", i.edrScale))
                    InfoRow("Gain map 上限", String(format: "%.3f", i.gainMapMax))
                }
                if item.details?.applePhotographicStyles == true { InfoRow("Apple 摄影风格", L("已包含")) }
                if item.details?.applePortrait == true { InfoRow("Apple 人像", L("已包含")) }
                if let m = item.motionPhoto {
                    InfoRow("动态照片", [m.sourceKind, m.durationText,
                                       m.videoWidth.flatMap { w in m.videoHeight.map { "\(w) × \($0)" } },
                                       m.isDualStream ? L("双流") : nil,
                                       m.hasAudio == true ? L("有声音") : nil].compactMap { $0 }.joined(separator: " · "))
                }
            }
    }

    /// The core's mode keys, named as the Flutter app and the organizer's
    /// folders name them.
    private func captureModeName(_ key: String?) -> String? {
        switch key {
        case nil: return nil
        case "master": return L("大师模式")
        case "ricoh-gr": return "RICOH GR"
        case "professional": return L("专业模式")
        case "portrait": return L("人像")
        case "night": return L("夜景")
        case "panorama": return L("全景")
        case "time-lapse": return L("延时摄影")
        case "ultra-high-resolution": return L("超清")
        case "id-photo": return L("证件照")
        case "sticker": return L("贴纸")
        case "enhanced-text": return L("超级文本")
        case "group-photo": return L("合影")
        case "double-exposure": return L("双重曝光")
        case "beauty": return L("美颜")
        case "normal": return L("普通拍照")
        case let other?: return other
        }
    }

    /// "OPPO Find X8 Ultra", not "OPPO OPPO Find X8 Ultra": OPPO's model
    /// tag already carries the make.
    private func deviceName(_ item: PhotoItem) -> String? {
        let make = item.details?.make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = item.details?.model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) { return model }
        return "\(make) \(model)"
    }

    private func motionSection(_ item: PhotoItem) -> some View {
        GroupBox("动态照片处理") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("处理方式", selection: Binding(
                    get: { item.motionMode ?? model.config.motionPhotoDefaultMode },
                    set: { model.setMotionMode($0, for: item.id) })) {
                    Text("Live Photo 合成").tag(MotionPhotoMode.livePhotoPair)
                    Text("仅静帧").tag(MotionPhotoMode.still)
                    Text("静帧 + 视频").tag(MotionPhotoMode.stillAndVideo)
                }
                .pickerStyle(.segmented)
                Text(motionHint(item.motionMode ?? model.config.motionPhotoDefaultMode))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func motionHint(_ mode: MotionPhotoMode) -> LocalizedStringKey {
        switch mode {
        case .livePhotoPair: return "转换后的静帧与原视频配对为 Apple Live Photo（HEIC + MOV 需一起导入 Apple 照片）。"
        case .still: return "只转换静帧，忽略附带的视频。"
        case .stillAndVideo: return "转换静帧，并把视频流另存为 MP4 放在输出旁边。"
        }
    }

    /// Same wording as the Flutter app's settings page.
    private func stylesHint(_ options: PhotoOptions) -> LocalizedStringKey {
        if options.applePhotographicStyles3 {
            return "摄影风格 3 已包含摄影风格 2：色调、颜色、强度之外，还可在 Apple“照片”中调整质感（如柔肤、光晕、胶片）和颗粒，需要 iOS 27 或更高版本。"
        }
        if options.applePhotographicStyles {
            return "写入摄影风格数据，可在 Apple“照片”中调整色调、颜色和强度。"
        }
        return "摄影风格数据让 Apple“照片”能像对 iPhone 照片一样调整色调、颜色和强度。"
    }

    private func optionBinding<Value>(_ item: PhotoItem, _ keyPath: WritableKeyPath<PhotoOptions, Value>) -> Binding<Value> {
        Binding(
            get: { model.effectiveOptions(for: item)[keyPath: keyPath] },
            set: { newValue in model.updateOptions(for: item.id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func optionsSection(_ item: PhotoItem) -> some View {
        let options = model.effectiveOptions(for: item)
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("输出", selection: optionBinding(item, \.outputMode)) {
                    Text("OPPO 兼容").tag(OutputMode.oppo)
                    Text("Apple 标准").tag(OutputMode.apple)
                }
                .pickerStyle(.segmented)

                Text(options.outputMode == .oppo
                     ? "兼容 OPPO / 一加相册的标准文件格式，恢复原机结构与私有尾部数据，支持后续编辑。"
                     : "面向 Apple“照片”的兼容文件格式，不写入 OPPO 私有信息，支持继续调节摄影风格。")
                    .font(.caption).foregroundStyle(.secondary)

                if options.outputMode == .apple {
                    Toggle("摄影风格 2", isOn: optionBinding(item, \.applePhotographicStyles))
                        .disabled(options.applePhotographicStyles3)
                    Toggle("摄影风格 3", isOn: optionBinding(item, \.applePhotographicStyles3))
                    Toggle("Apple 人像数据", isOn: optionBinding(item, \.applePortrait))
                    Text(stylesHint(options))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.convert(item.id) }
                } label: {
                    Label("转换这张", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(item.state.isBusy || !item.isConvertible)
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text("转换选项")
                Spacer()
                if item.options != nil {
                    Button("恢复默认") {
                        model.setOptions(nil, for: item.id)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(item.state.isBusy)
                }
            }
        }
    }
}

/// Shows the HDR output when available, otherwise the SDR input thumbnail.
/// With an HDR output on screen, a press-and-hold button shows the SDR base
/// image instead (what a viewer without HDR support would display), as the
/// HarmonyOS app does; releasing restores HDR.
struct PreviewCard: View {
    let item: PhotoItem
    /// Two-column layout: the card fills the column instead of capping at
    /// a fixed height.
    var fillsHeight = false
    /// The converted output, or the pre-conversion HDR preview the model
    /// rendered through the same core (`LibraryModel.preparePreview`).
    private var hdrURL: URL? { item.product?.outputURL ?? item.previewURL }
    private var isPreview: Bool { item.product == nil && item.previewURL != nil }
    #if os(iOS)
    // `UIImageReader` with `prefersHighDynamicRange` is the supported HDR
    // path on iOS; a CGImage decoded with `kCGImageSourceDecodeToHDR`
    // renders black in `Image(decorative:)` there (seen on iOS 27 simulator).
    typealias PreviewImage = UIImage
    #else
    typealias PreviewImage = CGImage
    #endif
    @State private var hdrImage: PreviewImage?
    @State private var sdrImage: PreviewImage?
    @State private var comparingSDR = false

    var body: some View {
        ZStack {
            // In the two-column layout the column is far taller than the
            // photo, so the grey plate would frame mostly empty space.
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary)
                .opacity(fillsHeight && hdrImage != nil ? 0 : 1)
            if let hdrImage {
                let showSDR = comparingSDR && sdrImage != nil
                previewImage(showSDR ? sdrImage! : hdrImage)
                    .resizable()
                    .scaledToFit()
                    .allowedDynamicRange(showSDR ? .standard : .high)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) {
                        badge(showSDR ? "SDR 效果" : (isPreview ? "HDR 预览" : "HDR 输出"))
                    }
                    // Top corner, opposite the badge: the bottom edge is
                    // where OPPO's watermark strip sits.
                    .overlay(alignment: .topTrailing) { sdrCompareButton }
            } else if let thumb = item.thumbnail {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) { badge("原图预览") }
                    .overlay(alignment: .bottomTrailing) {
                        if item.previewState == .rendering {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("正在生成 HDR 预览…")
                            }
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220, maxHeight: fillsHeight ? .infinity : 420)
        .task(id: hdrURL) {
            hdrImage = nil
            sdrImage = nil
            comparingSDR = false
            guard let url = hdrURL else { return }
            hdrImage = await Self.decode(url, hdr: true)
            // Decoded up front so the hold shows SDR without a visible delay.
            sdrImage = await Self.decode(url, hdr: false)
        }
    }

    private func previewImage(_ image: PreviewImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #else
        Image(decorative: image, scale: 1)
        #endif
    }

    /// Hold to see the SDR base image, release to return to HDR. A button
    /// (not a toggle) so the comparison reads as a glance, like the
    /// HarmonyOS app; `minimumDuration: 0` fires on touch-down. Labelled
    /// "HDR" for what the photo is; the badge says "SDR 效果" while held.
    private var sdrCompareButton: some View {
        Label("HDR", systemImage: "circle.lefthalf.filled")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(comparingSDR ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .foregroundStyle(comparingSDR ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(10)
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40) {
                // Fires on release when the hold ended inside the button.
            } onPressingChanged: { pressing in
                comparingSDR = pressing
            }
            .disabled(sdrImage == nil)
            .opacity(sdrImage == nil ? 0.5 : 1)
            .accessibilityLabel("按住显示 SDR 效果，松开恢复 HDR")
            .accessibilityAddTraits(.isButton)
            .help("按住查看没有 HDR 时这张照片的样子")
    }

    private static func decode(_ url: URL, hdr: Bool) async -> PreviewImage? {
        #if os(iOS)
        // A screen without EDR headroom (the simulator, older panels)
        // draws a high-dynamic-range UIImage black, so only ask for HDR
        // where it can be shown; the SDR decode still applies the base
        // image's tone mapping.
        let hasHeadroom = await MainActor.run { UIScreen.main.potentialEDRHeadroom > 1.0 }
        let wantsHDR = hdr && hasHeadroom
        var configuration = UIImageReader.Configuration()
        configuration.prefersHighDynamicRange = wantsHDR
        return await UIImageReader(configuration: configuration).image(contentsOf: url)
        #else
        return await Task.detached(priority: .userInitiated) {
            hdr ? ImageLoading.hdrImage(at: url) : ImageLoading.sdrImage(at: url)
        }.value
        #endif
    }

    private func badge(_ text: LocalizedStringKey) -> some View {
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
                    InfoRow("输出模式", product.config.outputMode == .oppo ? L("OPPO 兼容") : L("Apple 标准"))
                    InfoRow("文件", product.outputURL.lastPathComponent, singleLine: true)
                    if let mov = product.pairedVideoURL { InfoRow("Live Photo 视频", mov.lastPathComponent, singleLine: true) }
                    if !product.extraVideoURLs.isEmpty {
                        InfoRow("视频", product.extraVideoURLs.map(\.lastPathComponent).joined(separator: ", "), singleLine: true)
                    }
                    // The X6 / X7 family stays in the model for the core; like
                    // the Flutter app, it is not shown (it duplicates the HDR kind).
                    InfoRow("来源", product.outcome.mode?.uppercased())
                    InfoRow("校验", L("通过（可解码 + 结构检查）"))
                }
                ExportButtons(model: model, item: item, product: product)
                // Another mode for the same photo, without re-importing it.
                Button {
                    model.reconvert(item.id)
                } label: {
                    Label("重新转换", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }
}

/// Set on the narrow controls column: `InfoRow` stacks the label above the
/// value instead of using two grid columns.
private struct InfoRowsStackedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var infoRowsStacked: Bool {
        get { self[InfoRowsStackedKey.self] }
        set { self[InfoRowsStackedKey.self] = newValue }
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
    let label: LocalizedStringKey
    let value: String?
    /// File names: one line, truncated in the middle, rather than broken
    /// mid-word across lines.
    var singleLine = false
    @Environment(\.infoRowsStacked) private var stacked

    init(_ label: LocalizedStringKey, _ value: String?, singleLine: Bool = false) {
        self.label = label
        self.value = value
        self.singleLine = singleLine
    }

    var body: some View {
        if let value, !value.isEmpty {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    valueText(value)
                }
                .padding(.bottom, 4)
            } else {
                GridRow {
                    Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    valueText(value)
                }
                .font(.callout)
            }
        }
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .textSelection(.enabled)
            .lineLimit(singleLine ? 1 : nil)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
