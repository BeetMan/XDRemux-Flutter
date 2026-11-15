import Foundation
import XDRemuxCoreC
import XDRemuxModel

/// The HEVC encoders compiled into the linked core, as reported by
/// `xdremux_codec_capabilities` (`hevcEncoders`, preferred first, and
/// `defaultHevcEncoder`).
///
/// Store builds carry one encoder, so there is nothing to choose and no
/// setting is shown. Builds that carry a second one let the user pick; the
/// names come from the core at run time and are never spelled out here.
public struct HEVCEncoders: Equatable, Sendable {
    public let available: [String]
    public let defaultName: String?

    public init(available: [String], defaultName: String?) {
        self.available = available
        self.defaultName = defaultName ?? available.first
    }

    /// Parses the capability report; an unreadable report means "no choice".
    public init(capabilitiesJSON: String) {
        struct Report: Decodable {
            var hevcEncoders: [String]?
            var defaultHevcEncoder: String?
        }
        let report = try? JSONDecoder().decode(Report.self, from: Data(capabilitiesJSON.utf8))
        self.init(available: report?.hevcEncoders ?? [], defaultName: report?.defaultHevcEncoder)
    }

    /// True when the core has more than one encoder, i.e. when the encoder
    /// setting means something.
    public var offersChoice: Bool { available.count > 1 }

    /// The encoder that is not the default, when there is one.
    public var alternativeName: String? { available.first { $0 != defaultName } }

    /// The name to hand to the core for `ConversionConfig.hardwareEncode`:
    /// `nil` (the core's default, the system encoder) when it is true or when
    /// there is no alternative, the alternative encoder otherwise.
    public func name(systemEncoder: Bool) -> String? {
        systemEncoder ? nil : alternativeName
    }

    /// Whether `name` can be selected in this build.
    public func contains(_ name: String) -> Bool { available.contains(name) }
}

extension XDRemuxEngine {
    /// Read once: the set of compiled encoders cannot change at run time.
    public static let hevcEncoders: HEVCEncoders = {
        guard let raw = RustString(taking: xdremux_codec_capabilities()).consume() else {
            return HEVCEncoders(available: [], defaultName: nil)
        }
        return HEVCEncoders(capabilitiesJSON: raw)
    }()

    /// `xdremux_set_hevc_encoder`: the process-wide encoder for calls that
    /// carry no per-conversion config (Live Photo, writeback). `nil` restores
    /// the core's default. Returns false when the core does not have `name`.
    @discardableResult
    public static func selectHEVCEncoder(named name: String?) -> Bool {
        guard let name else { return xdremux_set_hevc_encoder(nil) }
        return name.withCString { xdremux_set_hevc_encoder($0) }
    }

    /// Applies the encoder setting process-wide. Call at launch and whenever
    /// the setting changes; conversions also carry it in their own config.
    public static func applyEncoderChoice(_ config: ConversionConfig) {
        selectHEVCEncoder(named: hevcEncoders.name(systemEncoder: config.hardwareEncode))
    }
}
