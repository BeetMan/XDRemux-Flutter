import Foundation
import CoreGraphics
import CoreVideo
import XDRemuxCore

package typealias CLIError = XDRemuxError
package typealias AppleFeatureFlags = AppleFeatureOptions

package enum AppleEvidenceClass: String, Codable, Sendable {
    case verified
    case profileExact = "profile_exact"
    case sourceDerivedApproximation = "source_derived_approximation"
    case privateFrameworkIdentity = "private_framework_same_scene_identity"
    case privateFrameworkNearIdentityFallback = "private_framework_same_scene_near_identity"
    case privateFrameworkLearned = "private_framework_learned_scene_match"
    case completeNeutrinoConstrainedSolver = "complete_neutrino_constrained_scene_match"
    case protocolConstant = "protocol_constant"
    case unavailable
}

package struct AppleResourceProvenance: Codable, Sendable {
    let producer: String
    let inputSHA256: String
    let evidence: AppleEvidenceClass
    let detail: String
}

package struct SemanticStatistics: Codable, Sendable {
    let minimum: UInt8
    let maximum: UInt8
    let mean: Double
    let coverage: Double
}

package struct SemanticProvenance: Codable, Sendable {
    let requestClass: String
    let attributeName: String
    let revision: Int
    let inputSHA256: String
    let width: Int
    let height: Int
    let pixelFormat: String
    let orientation: UInt32
    let orientationTransform: String
    let fallback: Bool
}

package struct AppleSemanticMatte: Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let statistics: SemanticStatistics
    let provenance: SemanticProvenance

    func thresholdPixelCount(_ threshold: UInt8 = 128) -> Int {
        pixels.reduce(into: 0) { count, value in
            if value >= threshold { count += 1 }
        }
    }

    var hasCredibleForeground: Bool {
        guard statistics.maximum >= 128 else { return false }
        // A fixed percentage would incorrectly discard distant people, teeth,
        // glasses, and hair. A tiny absolute floor only rejects isolated model
        // noise while preserving genuinely sparse semantic results.
        return thresholdPixelCount() >= 16
    }
}

package enum AppleSemanticRole: String, CaseIterable, Codable, Sendable {
    case person
    case skin
    case hair
    case teeth
    case glasses
    case sky
}

package struct AppleSemanticWriteProfile: Sendable {
    enum Kind: String, Codable, Sendable {
        case styleSkyOnly = "style_sky_only"
        case styleHuman = "style_human"
        case portrait = "portrait"
        case portraitAndStyles = "portrait_and_styles"
    }

    let kind: Kind
    let roles: Set<AppleSemanticRole>

    static let styleSkyOnly = AppleSemanticWriteProfile(
        kind: .styleSkyOnly,
        roles: [.sky]
    )
    static let styleHuman = AppleSemanticWriteProfile(
        kind: .styleHuman,
        roles: [.person, .skin, .sky]
    )
    static let portrait = AppleSemanticWriteProfile(
        kind: .portrait,
        roles: [.person, .skin, .hair, .teeth, .glasses]
    )
    static let portraitAndStyles = AppleSemanticWriteProfile(
        kind: .portraitAndStyles,
        roles: Set(AppleSemanticRole.allCases)
    )

    var orderedRoles: [AppleSemanticRole] {
        AppleSemanticRole.allCases.filter(roles.contains)
    }
}

package struct AppleSemanticSceneAnalysis: Sendable {
    let person: AppleSemanticMatte?
    let skin: AppleSemanticMatte?
    let hair: AppleSemanticMatte?
    let teeth: AppleSemanticMatte?
    let glasses: AppleSemanticMatte?
    let sky: AppleSemanticMatte?

    var hasCrediblePerson: Bool {
        person?.hasCredibleForeground == true
    }

    var nativeStyleWriteProfile: AppleSemanticWriteProfile {
        hasCrediblePerson ? .styleHuman : .styleSkyOnly
    }
}

package struct OPPOScenePackage: Sendable {
    enum BundleSource: String, Codable, Sendable {
        case srcImage = "src.image"
        case outerPrimary = "outer_primary"
    }

    let inputURL: URL
    let inputSHA256: String
    let bundleSource: BundleSource
    let baseImageURL: URL
    let gainMapJPEG: Data
    let gainMapInfo: [Double]
    let orientation: UInt32
    let semanticAnalysis: AppleSemanticSceneAnalysis
    let hdrTransformDataSHA256: String?
}

package struct ApplePhotographicStylePayload: Sendable {
    let styleData: Data
    let stylePropertyList: Data
    let linearThumbnailHEVC: Data
    let linearThumbnailHVCC: Data
    let linearThumbnailWidth: Int
    let linearThumbnailHeight: Int
    let styleDeltaHEVC: Data
    let styleDeltaHVCC: Data
    let styleDeltaTileWidth: Int
    let styleDeltaTileHeight: Int
    let styleDeltaGridWidth: Int
    let styleDeltaGridHeight: Int
    let styleDeltaRows: Int
    let styleDeltaColumns: Int
    let photoIdentifier: String
    let manifestJSON: Data
    let resourceProvenance: [String: AppleResourceProvenance]
}

package struct ApplePortraitPayload {
    let isAvailable: Bool
    let unavailableReason: String?
    let disparity: CFDictionary?
    let portraitEffectsMatte: CFDictionary?
    let skinMatte: CFDictionary?
    let hairMatte: CFDictionary?
    let teethMatte: CFDictionary?
    let glassesMatte: CFDictionary?
}

package struct AppleHEIFWritePlan {
    let standardHDRURL: URL
    let styles: ApplePhotographicStylePayload
    let portrait: ApplePortraitPayload?
    let primaryEncodedOnce: Bool
    let gainMapEncodedOnce: Bool
}
