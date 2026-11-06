import SwiftUI
import XDRemuxKit
import XDRemuxModel

/// Global defaults. Changes apply to conversions started afterwards; a running
/// conversion keeps the snapshot it started with (ConversionJob copies config).
struct SettingsView: View {
    private let hardwareEncodeAvailable = VideoToolboxTileEncoder.isAvailable
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("语言", selection: $model.config.language) {
                        Text("跟随系统").tag(AppLanguage.system)
                        Text(verbatim: "简体中文").tag(AppLanguage.chinese)
                        Text(verbatim: "English").tag(AppLanguage.english)
                    }
                }
                Section("输出") {
                    Picker("输出模式", selection: $model.config.outputMode) {
                        Text("OPPO 兼容").tag(OutputMode.oppo)
                        Text("Apple 标准").tag(OutputMode.apple)
                    }
                    #if os(macOS)
                    LabeledContent("输出目录") {
                        HStack {
                            Text(model.outputRoot.path).lineLimit(1).truncationMode(.middle)
                                .font(.caption).foregroundStyle(.secondary)
                            Button("选择…") { model.chooseOutputDirectory() }
                            if model.usesCustomOutputDirectory {
                                Button("恢复默认") { model.resetOutputDirectory() }
                            }
                        }
                    }
                    #endif
                    Stepper("同时转换 \(model.config.maxConcurrentJobs) 张", value: $model.config.maxConcurrentJobs, in: 1...8)
                    TextField("文件名后缀", text: $model.config.fileNameSuffix)
                    Toggle("覆盖同名输出", isOn: $model.config.skipExisting)
                    Toggle("按输出模式分目录", isOn: $model.config.categorizeOutputByMode)
                }

                if model.config.outputMode == .oppo {
                    Section("OPPO 兼容") {
                        Picker("兼容策略", selection: $model.config.oppoCompatibility) {
                            ForEach(OppoCompatMode.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                        }
                        Picker("相机尾部数据", selection: $model.config.oppoCameraTail) {
                            ForEach(OppoCameraTailMode.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                        }
                    }
                } else {
                    Section {
                        Toggle(isOn: $model.config.applePhotographicStyles) {
                            Text("摄影风格 2")
                            Text(model.config.applePhotographicStyles3
                                 ? "摄影风格 3 已包含摄影风格 2；如需单独调整，请先关闭摄影风格 3。"
                                 : "写入摄影风格数据，可在 Apple“照片”中调整色调、颜色和强度。")
                        }
                        .disabled(model.config.applePhotographicStyles3)
                        Toggle(isOn: $model.config.applePhotographicStyles3) {
                            Text("摄影风格 3")
                            Text("在摄影风格 2 的基础上，还可在 Apple“照片”中调整质感（如柔肤、光晕、胶片）和颗粒，需要 iOS 27 或更高版本。")
                        }
                        Toggle(isOn: $model.config.applePortrait) {
                            Text("Apple 人像数据")
                            Text("写入人像深度与蒙版，Apple“照片”可继续调整景深与焦点。")
                        }
                    } header: {
                        Text("Apple 标准")
                    } footer: {
                        Text("Apple 标准输出不写入 OPPO 私有信息，文件可在 Apple“照片”里继续编辑。")
                    }
                }

                Section {
                    Toggle("硬件编码（VideoToolbox）", isOn: $model.config.hardwareEncode)
                        .disabled(!hardwareEncodeAvailable)
                } header: {
                    Text("编码")
                } footer: {
                    if !hardwareEncodeAvailable {
                        Text("这台设备没有可用的硬件 HEVC 编码器。")
                    } else {
                        Text("用系统硬件编码增益图，比内置的 x265 快得多；摄影风格、人像仍走内置编码。不能分块的照片自动回退。")
                    }
                }

                #if os(iOS)
                Section {
                    Toggle("转换完成后自动存入照片", isOn: $model.config.autoSaveToGallery)
                } header: {
                    Text("照片")
                } footer: {
                    Text("批量转换结束后把成功的照片存入照片库，Live Photo 成对保存；已存入的不会重复保存。")
                }
                #endif

                Section("高级") {
                    Toggle("严格 ISO 21496-1 tmap", isOn: $model.config.strictTmap)
                    Picker("机型家族", selection: $model.config.family) {
                        Text("自动").tag(Family.auto)
                        Text("X6").tag(Family.x6)
                        Text("X7").tag(Family.x7)
                    }
                }

                Section("关于") {
                    LabeledContent("Rust 内核", value: model.coreVersion)
                    LabeledContent("输出目录", value: model.outputRoot.path)
                        .font(.caption)
                    Button("恢复默认设置", role: .destructive) {
                        model.config = ConversionConfig()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    static func title(_ mode: OppoCompatMode) -> String {
        switch mode {
        case .auto: return L("自动")
        case .on: return L("开启")
        case .tail: return L("仅尾部")
        case .iso: return L("ISO")
        case .isoNoLocal: return L("ISO（无本地）")
        case .isoGraph: return L("ISO 图")
        case .off: return L("关闭")
        }
    }

    static func title(_ mode: OppoCameraTailMode) -> String {
        switch mode {
        case .automatic: return L("自动")
        case .off: return L("不保留")
        case .watermark: return L("仅水印")
        case .compact: return L("精简")
        case .preserve: return L("完整保留")
        case .preserveWithoutPortrait: return L("保留（去人像）")
        case .preserveWithoutPortraitOrPrivateHdr: return L("保留（去人像与私有 HDR）")
        case .preserveWithoutPrivateUhdr: return L("保留（去私有 UHDR）")
        case .preserveWithoutPrivateHdr: return L("保留（去私有 HDR）")
        case .preserveNoUhdr: return L("保留（无 UHDR）")
        case .preserveNoHdr: return L("保留（无 HDR）")
        }
    }
}
