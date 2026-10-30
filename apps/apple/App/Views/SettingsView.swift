import SwiftUI
import XDRemuxModel

/// Global defaults. Changes apply to conversions started afterwards; a running
/// conversion keeps the snapshot it started with (ConversionJob copies config).
struct SettingsView: View {
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("输出") {
                    Picker("输出模式", selection: $model.config.outputMode) {
                        Text("OPPO 兼容").tag(OutputMode.oppo)
                        Text("Apple 标准").tag(OutputMode.apple)
                    }
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
                    Section("Apple 标准") {
                        Toggle("Apple 摄影风格", isOn: $model.config.applePhotographicStyles)
                        Toggle("摄影风格 3（纹理与颗粒）", isOn: $model.config.applePhotographicStyles3)
                        Toggle("Apple 人像数据", isOn: $model.config.applePortrait)
                    }
                }

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
                    LabeledContent("输出目录", value: model.directories.outputs.path)
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
        case .auto: return "自动"
        case .on: return "开启"
        case .tail: return "仅尾部"
        case .iso: return "ISO"
        case .isoNoLocal: return "ISO（无本地）"
        case .isoGraph: return "ISO 图"
        case .off: return "关闭"
        }
    }

    static func title(_ mode: OppoCameraTailMode) -> String {
        switch mode {
        case .automatic: return "自动"
        case .off: return "不保留"
        case .watermark: return "仅水印"
        case .compact: return "精简"
        case .preserve: return "完整保留"
        case .preserveWithoutPortrait: return "保留（去人像）"
        case .preserveWithoutPortraitOrPrivateHdr: return "保留（去人像与私有 HDR）"
        case .preserveWithoutPrivateUhdr: return "保留（去私有 UHDR）"
        case .preserveWithoutPrivateHdr: return "保留（去私有 HDR）"
        case .preserveNoUhdr: return "保留（无 UHDR）"
        case .preserveNoHdr: return "保留（无 HDR）"
        }
    }
}
