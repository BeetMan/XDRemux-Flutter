#if canImport(UIKit)
import Foundation
import ImageIO

// AppleFeatures-module copy of the XDremuxCore iOS ImageIO shims; see
// Sources/XDremuxCore/Platform/IOSImageIOShims.swift for the rationale
// (iOS 17/18-gated symbols, iOS 15 deployment target, values verified
// against the OS runtime). Module-internal declarations shadow the
// imported ImageIO symbols, so each module needs its own copy.

let kCGImageAuxiliaryDataTypeISOGainMap = "kCGImageAuxiliaryDataTypeISOGainMap" as CFString

let kCGImageSourceDecodeRequest = "kCGImageSourceDecodeRequest" as CFString

let kCGImageSourceDecodeToSDR = "kCGImageSourceDecodeToSDR" as CFString

let kCGImageDestinationEncodeBaseIsSDR = "kCGImageDestinationEncodeBaseIsSDR" as CFString

let kCGImageDestinationEncodeRequest = "kCGImageDestinationEncodeRequest" as CFString

let kCGImageDestinationEncodeToISOGainmap = "kCGImageDestinationEncodeToISOGainmap" as CFString

let kCGImageDestinationEncodeRequestOptions =
  "kCGImageDestinationEncodeRequestOptions" as CFString

#endif
