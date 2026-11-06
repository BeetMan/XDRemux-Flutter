import Foundation

/// What the core's Huawei inspection says about an input, reduced to the
/// bits the admission policy and the UI need.
public struct HuaweiPhotoInfo: Codable, Equatable, Sendable {
    /// Huawei HDR HEIC (tmap graph + HDR Vivid / CUVA markers); already
    /// displays as HDR in Apple Photos without conversion.
    public var isHdr: Bool
    /// Carries a Huawei `xtstyle` payload.
    public var hasXtstyle: Bool
    /// Huawei portrait whose depth payload the core can transform into an
    /// Apple Portrait (`huaweiPortrait.safeToTransform`).
    public var portraitReady: Bool

    public init(isHdr: Bool, hasXtstyle: Bool = false, portraitReady: Bool = false) {
        self.isHdr = isHdr
        self.hasXtstyle = hasXtstyle
        self.portraitReady = portraitReady
    }
}

/// Shared admission policy for Huawei inputs, the same on every platform
/// (`apps/flutter/lib/services/huawei_photo_policy.dart`): an ordinary Huawei
/// HDR photo is skipped because Photos shows it natively; it is admitted
/// when Photographic Styles is requested (that path re-encodes any HEIC),
/// when its portrait depth can be transformed, or when it is a Motion Photo.
public enum HuaweiPhotoPolicy {
    public enum Admission: Equatable, Sendable {
        case admitted
        case skipped(reason: String)
    }

    public static let skipReason = "华为 HDR 原生兼容 Apple 照片，无需转换"

    public static func admission(huaweiHdr: Bool, portraitReady: Bool,
                                 stylesRequested: Bool, motionPhoto: Bool = false) -> Admission {
        if !huaweiHdr || portraitReady || stylesRequested || motionPhoto {
            return .admitted
        }
        return .skipped(reason: skipReason)
    }

    /// Convenience over the inspection result and the current config.
    public static func admission(_ info: HuaweiPhotoInfo?, config: ConversionConfig, motionPhoto: Bool = false) -> Admission {
        admission(huaweiHdr: info?.isHdr ?? false, portraitReady: info?.portraitReady ?? false,
                  stylesRequested: config.applePhotographicStyles || config.applePhotographicStyles3,
                  motionPhoto: motionPhoto)
    }
}
