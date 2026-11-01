import CoreGraphics
import Foundation
import XDRemuxKit
import XDRemuxModel

/// One imported photo and everything the app learned or produced for it.
/// Inputs are sandbox copies; the user's original is never touched.
struct PhotoItem: Identifiable {
    enum State: Equatable {
        case inspecting
        case ready
        case converting(Double)
        case done(ConversionProduct)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .inspecting, .converting: return true
            default: return false
            }
        }
    }

    let id: UUID
    let sourceName: String
    let inputURL: URL

    init(id: UUID = UUID(), sourceName: String, inputURL: URL) {
        self.id = id
        self.sourceName = sourceName
        self.inputURL = inputURL
    }
    var classification: Classification?
    var inspection: ConversionReport?
    var details: PhotoDetails?
    var thumbnail: CGImage?
    var motionPhoto: MotionPhotoInfo?
    /// Per-photo override of `ConversionConfig.motionPhotoDefaultMode`.
    var motionMode: MotionPhotoMode?
    /// Huawei HDR / portrait inspection; `nil` for everything else.
    var huawei: HuaweiPhotoInfo?
    /// Set when `HuaweiPhotoPolicy` keeps the photo out of the queue
    /// (recomputed whenever the config changes).
    var policyReason: String?
    var state: State = .inspecting
    var savedToPhotos = false

    enum PreviewState: Equatable { case none, rendering, ready, failed }
    /// Pre-conversion HDR preview: the core's Apple-mode output in the
    /// cache, shown until the real conversion replaces it.
    var previewURL: URL?
    var previewState: PreviewState = .none

    var isMotionPhoto: Bool { motionPhoto != nil }

    var product: ConversionProduct? {
        if case .done(let p) = state { return p }
        return nil
    }

    /// True when the core recognised a source it can convert and no policy
    /// keeps it out of the queue.
    var isConvertible: Bool {
        inspection?.success == true && policyReason == nil
    }

    var statusText: String {
        switch state {
        case .inspecting: return String(localized: "正在读取…")
        case .ready:
            if let policyReason { return String(localized: String.LocalizationValue(policyReason)) }
            return isConvertible ? String(localized: "可转换") : (inspection?.errorMessage ?? String(localized: "不支持"))
        case .converting(let p):
            // The fraction is banded by stage in the kit, so the label can
            // name the stage the way the Flutter app does.
            switch ConversionProgress.Phase(fraction: p) {
            case .extract: return String(localized: "解析元数据…")
            case .decode: return String(localized: "解码增益图…")
            case .encode: return String(localized: "编码 HEVC \(Int(p * 100))%")
            case .assemble: return String(localized: "组装输出…")
            }
        case .done: return String(localized: "已完成")
        case .failed(let m): return String(localized: "失败：\(m)")
        }
    }

    /// Short line for the list row: "x7 · lhdr · 4096 × 3072".
    /// One line under the file name in the list. The device family (X6 /
    /// X7) stays in the detail page's photo info; it says nothing a user
    /// picking a photo to convert needs here.
    var summaryText: String {
        var parts: [String] = []
        if let k = classification?.hdrKind { parts.append(k.uppercased()) }
        if let mp = details?.megapixelsText { parts.append(mp) }
        if isMotionPhoto { parts.append(String(localized: "动态照片")) }
        if let huawei {
            parts.append(huawei.portraitReady ? String(localized: "华为人像 → Apple 人像") : String(localized: "华为 HDR"))
        }
        return parts.joined(separator: " · ")
    }
}
