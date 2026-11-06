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
    /// Not a ProXDR source. With Apple 标准 + 摄影风格 the core decodes it
    /// and rebuilds a standard container (`sdr_source`), so it converts;
    /// otherwise there is nothing to convert.
    var plainSource = false
    /// `plainSource` and the config allows the Styles path (set by the model
    /// whenever the config changes).
    var stylesRescue = false
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
        (inspection?.success == true || stylesRescue) && policyReason == nil
    }

    var statusText: String {
        switch state {
        case .inspecting: return L("正在读取…")
        case .ready:
            if let policyReason { return L(String.LocalizationValue(policyReason)) }
            if isConvertible { return stylesRescue ? L("可转换（摄影风格）") : L("可转换") }
            let message = inspection?.errorMessage ?? L("不支持")
            return plainSource ? L("\(message)选 Apple 标准并开启摄影风格后可以转换。") : message
        case .converting(let p):
            // The fraction is banded by stage in the kit, so the label can
            // name the stage the way the Flutter app does.
            switch ConversionProgress.Phase(fraction: p) {
            case .extract: return L("解析元数据…")
            case .decode: return L("解码增益图…")
            case .encode: return L("编码 HEVC \(Int(p * 100))%")
            case .assemble: return L("组装输出…")
            }
        case .done: return L("已完成")
        case .failed(let m): return L("失败：\(m)")
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
        if isMotionPhoto { parts.append(L("动态照片")) }
        if let huawei {
            parts.append(huawei.portraitReady ? L("华为人像 → Apple 人像") : L("华为 HDR"))
        }
        return parts.joined(separator: " · ")
    }
}
