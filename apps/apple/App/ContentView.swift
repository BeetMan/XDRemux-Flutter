import SwiftUI
import UniformTypeIdentifiers
import XDRemuxKit

/// P0 scaffold: proves the SwiftUI shell reaches the Rust core on both
/// platforms. The product UI (detail-first flow, queue, settings) is P1–P2
/// in docs/plans/apple-native.md §8 and replaces this view.
struct ContentView: View {
    @State private var model = ProbeModel()
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Rust 内核") {
                    LabeledContent("版本", value: model.coreVersion)
                    LabeledContent("编码能力", value: model.codecSummary)
                }
                Section("检查一个文件") {
                    Button("选择 HEIC / JPEG…") { showImporter = true }
                    if let name = model.fileName {
                        LabeledContent("文件", value: name)
                    }
                    if model.isWorking {
                        ProgressView()
                    }
                    if let c = model.classification {
                        LabeledContent("状态", value: c.status ?? "–")
                        LabeledContent("模式", value: c.modeKey ?? "–")
                        LabeledContent("HDR", value: c.hdrKind ?? "–")
                        LabeledContent("机型家族", value: c.family ?? "–")
                    }
                    if let r = model.inspection {
                        LabeledContent("结构检查", value: r.success ? "通过" : (r.errorMessage ?? "失败"))
                        if r.success {
                            LabeledContent("EDR scale", value: String(format: "%.3f", r.edrScale))
                            LabeledContent("Gain map max", value: String(format: "%.3f", r.gainMapMax))
                        }
                    }
                    if let error = model.errorText {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("XDRemux")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.heic, .heif, .jpeg],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await model.probe(url) }
                }
            }
            .task { await model.load() }
        }
    }
}

@MainActor
@Observable
final class ProbeModel {
    var coreVersion = "…"
    var codecSummary = "…"
    var fileName: String?
    var classification: Classification?
    var inspection: ConversionReport?
    var errorText: String?
    var isWorking = false

    private let engine = XDRemuxEngine.shared

    func load() async {
        coreVersion = XDRemuxEngine.coreVersion()
        do {
            let report = try await engine.codecCapabilities()
            codecSummary = Self.summarize(report.raw)
        } catch {
            codecSummary = "不可用：\(error)"
        }
    }

    /// Copies the picked file into the app sandbox before Rust reads it, the
    /// same rule the HarmonyOS front-end follows (plan §3 P1).
    func probe(_ url: URL) async {
        errorText = nil
        classification = nil
        inspection = nil
        fileName = url.lastPathComponent
        isWorking = true
        defer { isWorking = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let inputs = FileManager.default.temporaryDirectory.appendingPathComponent("inputs", isDirectory: true)
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            let copy = inputs.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: copy)

            classification = try await engine.classify(path: copy.path)
            inspection = try await engine.inspect(path: copy.path)
        } catch {
            errorText = String(describing: error)
        }
    }

    private static func summarize(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json
        }
        return object.keys.sorted().map { key in
            let value = object[key]
            if let b = value as? Bool { return "\(key)=\(b ? "✓" : "✗")" }
            return "\(key)=\(value.map { String(describing: $0) } ?? "")"
        }.joined(separator: "  ")
    }
}
