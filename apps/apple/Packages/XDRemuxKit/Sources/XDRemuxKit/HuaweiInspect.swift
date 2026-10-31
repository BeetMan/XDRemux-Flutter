import Foundation
import XDRemuxCoreC
import XDRemuxModel

/// Decoded `xdremux_huawei_inspect` report (keys from
/// `xdremux/rust/src/huawei_heic.rs`); only what the policy and UI use.
public struct HuaweiReport: Decodable, Equatable, Sendable {
    public struct Portrait: Decodable, Equatable, Sendable {
        public var safeToTransform: Bool?
        public var recommendedAction: String?
    }

    public var status: String?
    public var isHuaweiHdr: Bool?
    public var hasXtstyle: Bool?
    public var hasHuaweiPortrait: Bool?
    public var recommendedAction: String?
    public var huaweiPortrait: Portrait?
    public var error: String?

    /// `nil` when the file is neither Huawei HDR nor a Huawei portrait.
    public var info: HuaweiPhotoInfo? {
        let hdr = isHuaweiHdr ?? false
        let portraitReady = huaweiPortrait?.safeToTransform ?? false
        guard hdr || portraitReady else { return nil }
        return HuaweiPhotoInfo(isHdr: hdr, hasXtstyle: hasXtstyle ?? false, portraitReady: portraitReady)
    }
}

extension XDRemuxEngine {
    /// `xdremux_huawei_inspect`: read-only; never rewrites the input.
    public func huaweiReport(path: String) async throws -> HuaweiReport {
        try await runOnQueue {
            try withCPath(path) { try JSONReport(consuming: RustString(taking: xdremux_huawei_inspect($0))) }
        }.decode()
    }

    /// Policy input for HEIC/HEIF files; other formats are never Huawei HDR.
    public func huaweiPhotoInfo(path: String) async -> HuaweiPhotoInfo? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "heic" || ext == "heif" else { return nil }
        return (try? await huaweiReport(path: path))?.info
    }
}
