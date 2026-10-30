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
    var state: State = .inspecting
    var savedToPhotos = false

    var isMotionPhoto: Bool { motionPhoto != nil }

    var product: ConversionProduct? {
        if case .done(let p) = state { return p }
        return nil
    }

    /// True when the core recognised a ProXDR / Ultra HDR source it can convert.
    var isConvertible: Bool {
        inspection?.success == true
    }

    var statusText: String {
        switch state {
        case .inspecting: return String(localized: "正在读取…")
        case .ready: return isConvertible ? String(localized: "可转换") : (inspection?.errorMessage ?? String(localized: "不支持"))
        case .converting(let p): return String(localized: "转换中 \(Int(p * 100))%")
        case .done: return String(localized: "已完成")
        case .failed(let m): return String(localized: "失败：\(m)")
        }
    }

    /// Short line for the list row: "x7 · lhdr · 4096 × 3072".
    var summaryText: String {
        var parts: [String] = []
        if let f = classification?.family { parts.append(f.uppercased()) }
        if let k = classification?.hdrKind { parts.append(k.uppercased()) }
        if let d = details?.dimensionsText { parts.append(d) }
        if isMotionPhoto { parts.append(String(localized: "动态照片")) }
        return parts.joined(separator: " · ")
    }
}
