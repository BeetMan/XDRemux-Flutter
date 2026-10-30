import Foundation

// Mirrors apps/flutter/lib/models/app_models.dart. Enum raw values and JSON
// keys are kept identical to the Dart `name`s so settings and checkpoints can
// be read by either front-end (docs/plans/apple-native.md §3 P2).

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case chinese, english
}

public enum Family: String, Codable, CaseIterable, Sendable {
    case auto, x6, x7
}

public enum OutputMode: String, Codable, CaseIterable, Sendable {
    /// "OPPO 兼容 / OPPO Compatible"
    case oppo
    /// "Apple 标准 / Apple Standard"
    case apple
}

/// Maps to Rust `ConvertConfig.oppo_compat`.
public enum OppoCompatMode: String, Codable, CaseIterable, Sendable {
    case auto, on, tail, iso, isoNoLocal, isoGraph, off

    public var rustValue: UInt8 {
        switch self {
        case .off: return 0
        case .auto: return 1
        case .on: return 2
        case .tail: return 3
        case .iso: return 4
        case .isoNoLocal: return 5
        case .isoGraph: return 6
        }
    }
}

/// Maps to Rust `ConvertConfig.oppo_camera_tail`; 255 lets Rust choose.
public enum OppoCameraTailMode: String, Codable, CaseIterable, Sendable {
    case automatic, off, watermark, compact, preserve
    case preserveWithoutPortrait
    case preserveWithoutPortraitOrPrivateHdr
    case preserveWithoutPrivateUhdr
    case preserveWithoutPrivateHdr
    case preserveNoUhdr
    case preserveNoHdr

    public var rustValue: UInt8 {
        switch self {
        case .automatic: return 255
        case .off: return 0
        case .watermark: return 1
        case .compact: return 2
        case .preserve: return 3
        case .preserveWithoutPortrait: return 4
        case .preserveWithoutPortraitOrPrivateHdr: return 5
        case .preserveWithoutPrivateUhdr: return 6
        case .preserveWithoutPrivateHdr: return 7
        case .preserveNoUhdr: return 8
        case .preserveNoHdr: return 9
        }
    }
}

public enum MotionPhotoMode: String, Codable, CaseIterable, Sendable {
    case livePhotoPair, still, stillAndVideo
}

/// The five bytes Rust reads. Everything else in `ConversionConfig` is
/// front-end policy (output location, concurrency, naming, …).
public struct RustConvertConfig: Equatable, Sendable {
    public var oppoCompat: UInt8
    public var oppoCameraTail: UInt8
    public var strictTmap: UInt8
    public var applePhotographicStyles: UInt8
    public var applePortrait: UInt8

    public init(oppoCompat: UInt8, oppoCameraTail: UInt8, strictTmap: UInt8,
                applePhotographicStyles: UInt8, applePortrait: UInt8) {
        self.oppoCompat = oppoCompat
        self.oppoCameraTail = oppoCameraTail
        self.strictTmap = strictTmap
        self.applePhotographicStyles = applePhotographicStyles
        self.applePortrait = applePortrait
    }
}

/// Persistent conversion settings. Defaults match the Dart constructor.
public struct ConversionConfig: Codable, Equatable, Sendable {
    public var language: AppLanguage = .chinese
    public var family: Family = .auto
    public var outputMode: OutputMode = .oppo
    public var outputDirectory: String? = nil
    public var oppoCompatibility: OppoCompatMode = .on
    public var oppoCameraTail: OppoCameraTailMode = .automatic
    public var strictTmap: Bool = false
    public var applePhotographicStyles: Bool = false
    public var applePortrait: Bool = false
    public var applePhotographicStyles3: Bool = false
    public var skipExisting: Bool = true
    public var maxConcurrentJobs: Int = 4
    public var fileNameSuffix: String = "_iso"
    public var categorizeOutputByMode: Bool = false
    public var autoSaveToGallery: Bool = false
    public var hardwareEncode: Bool = false
    public var motionPhotoDefaultMode: MotionPhotoMode = .livePhotoPair

    public init() {}

    /// Dart writes `backend` too; it is always "rust" for product builds and
    /// is not modelled here. Unknown keys are ignored on decode.
    enum CodingKeys: String, CodingKey {
        case language, family, outputMode, outputDirectory, oppoCompatibility, oppoCameraTail
        case strictTmap, applePhotographicStyles, applePortrait, applePhotographicStyles3
        case skipExisting, maxConcurrentJobs, fileNameSuffix, categorizeOutputByMode
        case autoSaveToGallery, hardwareEncode, motionPhotoDefaultMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConversionConfig()
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
        family = try c.decodeIfPresent(Family.self, forKey: .family) ?? d.family
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? d.outputMode
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory)
        oppoCompatibility = try c.decodeIfPresent(OppoCompatMode.self, forKey: .oppoCompatibility) ?? d.oppoCompatibility
        oppoCameraTail = try c.decodeIfPresent(OppoCameraTailMode.self, forKey: .oppoCameraTail) ?? d.oppoCameraTail
        strictTmap = try c.decodeIfPresent(Bool.self, forKey: .strictTmap) ?? d.strictTmap
        applePhotographicStyles = try c.decodeIfPresent(Bool.self, forKey: .applePhotographicStyles) ?? d.applePhotographicStyles
        applePortrait = try c.decodeIfPresent(Bool.self, forKey: .applePortrait) ?? d.applePortrait
        applePhotographicStyles3 = try c.decodeIfPresent(Bool.self, forKey: .applePhotographicStyles3) ?? d.applePhotographicStyles3
        skipExisting = try c.decodeIfPresent(Bool.self, forKey: .skipExisting) ?? d.skipExisting
        maxConcurrentJobs = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentJobs) ?? d.maxConcurrentJobs
        fileNameSuffix = try c.decodeIfPresent(String.self, forKey: .fileNameSuffix) ?? d.fileNameSuffix
        categorizeOutputByMode = try c.decodeIfPresent(Bool.self, forKey: .categorizeOutputByMode) ?? d.categorizeOutputByMode
        autoSaveToGallery = try c.decodeIfPresent(Bool.self, forKey: .autoSaveToGallery) ?? d.autoSaveToGallery
        hardwareEncode = try c.decodeIfPresent(Bool.self, forKey: .hardwareEncode) ?? d.hardwareEncode
        motionPhotoDefaultMode = try c.decodeIfPresent(MotionPhotoMode.self, forKey: .motionPhotoDefaultMode) ?? d.motionPhotoDefaultMode
    }

    /// The bytes handed to Rust. Apple output never carries OPPO private data
    /// (compat 0, tail 0), matching the Dart and HarmonyOS front-ends.
    public var rustConfig: RustConvertConfig {
        switch outputMode {
        case .oppo:
            return RustConvertConfig(
                oppoCompat: oppoCompatibility.rustValue,
                oppoCameraTail: oppoCameraTail.rustValue,
                strictTmap: strictTmap ? 1 : 0,
                applePhotographicStyles: 0,
                applePortrait: 0)
        case .apple:
            return RustConvertConfig(
                oppoCompat: 0,
                oppoCameraTail: 0,
                strictTmap: strictTmap ? 1 : 0,
                applePhotographicStyles: (applePhotographicStyles || applePhotographicStyles3) ? 1 : 0,
                applePortrait: applePortrait ? 1 : 0)
        }
    }
}
